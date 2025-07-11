// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*─────────────────── minimal ReentrancyGuard ───────────────────*/
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;
    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/*─────────────────── external mini-ABIs ───────────────────*/
interface IZRC20 {
    event Transfer(address indexed from, address indexed to, uint64 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint64 value
    );
    function balanceOf(address) external view returns (uint64);
    function approve(address, uint64) external returns (bool);
    function transfer(address, uint64) external returns (bool);
    function transferFrom(address, address, uint64) external returns (bool);
}
interface IUTD {
    function create(
        string calldata,
        string calldata,
        uint64,
        uint8,
        uint32,
        address,
        string calldata
    ) external returns (address);
}
interface IDEX {
    function initializeLiquidity(
        address,
        address,
        uint256,
        uint256,
        address
    ) external returns (uint256 liquidity);
    function withdrawLiquidity(
        address,
        address,
        uint128 liquidity,
        address to
    ) external returns (uint64 amountA, uint64 amountB);
}

/*─────────────────── data structs ───────────────────*/
struct UtilityTokenParams {
    string name;
    string symbol;
    uint64 supply64;
    uint8 decimals;
    uint32 lockTime;
    address root; // overridden to launcher
    string theme;
}
struct RocketConfig {
    address offeringCreator;
    IZRC20 invitingToken;
    UtilityTokenParams utilityTokenParams;
    uint32 percentOfLiquidityBurned;
    uint32 percentOfLiquidityCreator; // ≤ 50 %
    uint64 liquidityLockedUpTime; // vest ends here
    uint64 liquidityDeployTime; // vest starts here
}
struct RocketState {
    uint64 totalInviteContributed;
    uint128 totalLP; // LP minted at launch
    uint128 lpPulled; // LP already withdrawn
    uint64 poolInvite; // inviting tokens held
    uint64 poolUtility; // utility tokens held
    mapping(address => uint128) claimedLP; // LP-equivalent already claimed
}

/*─────────────────── errors ───────────────────*/
error ZeroAddress(address);
error PercentOutOfRange(uint32);
error CreatorShareTooHigh(uint32);
error UnknownRocket(uint256);
error AlreadyLaunched(uint256);
error LaunchTooEarly(uint256, uint64, uint64);
error VestBeforeLaunch(uint256);
error NothingToVest(uint256);
error NotLaunched(uint256);
error NothingToClaim(uint256);

/*════════════════════════ RocketLauncher ═══════════════════════*/
contract RocketLauncher is ReentrancyGuard {
    IDEX public immutable dex;
    IUTD public immutable deployer;
    string private _theme;

    uint256 public rocketCount;
    mapping(uint256 => RocketConfig) public rocketCfg;
    mapping(uint256 => RocketState) private rocketState;
    mapping(uint256 => IZRC20) public offeringToken;
    mapping(uint256 => mapping(address => uint64)) private _deposited;

    event RocketCreated(uint256 indexed id, address creator, address token);
    event Deposited(uint256 indexed id, address from, uint64 amount);
    event LiquidityDeployed(uint256 indexed id, uint128 lpMinted);
    event LiquidityVested(
        uint256 indexed id,
        uint128 lpPulled,
        uint64 invite,
        uint64 utility
    );
    event LiquidityClaimed(
        uint256 indexed id,
        address who,
        uint64 invite,
        uint64 utility
    );

    constructor(IDEX _dex, IUTD _deployer, string memory themeURI) {
        if (address(_dex) == address(0)) revert ZeroAddress(address(0));
        if (address(_deployer) == address(0)) revert ZeroAddress(address(0));
        dex = _dex;
        deployer = _deployer;
        _theme = themeURI;
    }

    /*───────────────── helpers ─────────────────*/
    function _cfg(uint256 id) internal view returns (RocketConfig storage c) {
        c = rocketCfg[id];
        if (address(c.invitingToken) == address(0)) revert UnknownRocket(id);
    }
    function _pct(uint128 tot, uint32 pct) private pure returns (uint128) {
        return uint128((uint256(tot) * pct) >> 32);
    }

    /*──────── 0. createRocket ────────*/
    function createRocket(
        RocketConfig calldata cfg_
    ) external nonReentrant returns (uint256 id) {
        if (address(cfg_.invitingToken) == address(0))
            revert ZeroAddress(address(0));
        if (cfg_.percentOfLiquidityBurned > type(uint32).max)
            revert PercentOutOfRange(cfg_.percentOfLiquidityBurned);
        if (cfg_.percentOfLiquidityCreator > type(uint32).max)
            revert PercentOutOfRange(cfg_.percentOfLiquidityCreator);
        if (cfg_.percentOfLiquidityCreator > (type(uint32).max >> 1))
            revert CreatorShareTooHigh(cfg_.percentOfLiquidityCreator);

        UtilityTokenParams memory p = cfg_.utilityTokenParams;
        address tok = deployer.create(
            p.name,
            p.symbol,
            p.supply64,
            p.decimals,
            p.lockTime,
            address(this),
            p.theme
        );

        id = ++rocketCount;
        rocketCfg[id] = cfg_;
        offeringToken[id] = IZRC20(tok);
        _rocketIdOfToken[tok] = id;

        emit RocketCreated(id, msg.sender, tok);
    }

    /*──────── 1. deposit ────────*/
    function deposit(uint256 id, uint64 amount) external nonReentrant {
        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];
        if (s.totalLP != 0) revert AlreadyLaunched(id);

        c.invitingToken.transferFrom(msg.sender, address(this), amount);
        _deposited[id][msg.sender] += amount;
        s.totalInviteContributed += amount;
        emit Deposited(id, msg.sender, amount);
    }

    /*──────── 2. launch ────────*/
    function deployLiquidity(uint256 id) external nonReentrant {
        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];

        if (block.timestamp < c.liquidityDeployTime)
            revert LaunchTooEarly(
                id,
                uint64(block.timestamp),
                c.liquidityDeployTime
            );
        if (s.totalLP != 0) revert AlreadyLaunched(id);

        UtilityTokenParams memory p = c.utilityTokenParams;
        IZRC20 util = offeringToken[id];

        util.approve(address(dex), p.supply64);
        c.invitingToken.approve(address(dex), s.totalInviteContributed);

        uint256 lp = dex.initializeLiquidity(
            address(util),
            address(c.invitingToken),
            p.supply64,
            s.totalInviteContributed,
            address(this)
        );
        s.totalLP = uint128(lp);
        emit LiquidityDeployed(id, uint128(lp));
    }

    /*──────── 3. vest vested-to-date LP ────────*/
    function vestLiquidity(uint256 id) public nonReentrant {
        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];

        if (s.totalLP == 0) revert VestBeforeLaunch(id);

        uint64 nowTs = uint64(block.timestamp);
        uint64 start = c.liquidityDeployTime;
        uint64 end = c.liquidityLockedUpTime;
        if (nowTs <= start) revert LaunchTooEarly(id, nowTs, start);

        uint128 vested = (nowTs >= end)
            ? s.totalLP
            : uint128((uint256(s.totalLP) * (nowTs - start)) / (end - start));

        uint128 toPull = vested - s.lpPulled;
        if (toPull == 0) revert NothingToVest(id);

        (uint64 utilOut, uint64 inviteOut) = dex.withdrawLiquidity(
            address(offeringToken[id]),
            address(c.invitingToken),
            toPull,
            address(this)
        );

        s.lpPulled += toPull;
        s.poolInvite += inviteOut;
        s.poolUtility += utilOut;

        emit LiquidityVested(id, toPull, inviteOut, utilOut);
    }

    /*──────── 4. claim vested tokens (available any time after first vest) ────────*/
    function claimLiquidity(uint256 id) external nonReentrant {
        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];
        if (s.totalLP == 0) revert NotLaunched(id);

        /* pull everything vested up to now so calculations are current */
        if (block.timestamp >= c.liquidityDeployTime) {
            // ignore failures (reverts) if nothing new is vesting
            try this.vestLiquidity(id) {} catch {}
        }

        if (s.lpPulled == 0) revert NothingToClaim(id); // nothing vested yet

        /* determine caller’s total LP share */
        uint128 lpShare;
        if (msg.sender == c.offeringCreator) {
            lpShare = _pct(s.totalLP, c.percentOfLiquidityCreator);
        } else {
            uint64 dep = _deposited[id][msg.sender];
            if (dep == 0) revert NothingToClaim(id);
            uint128 publicBase = s.totalLP -
                _pct(s.totalLP, c.percentOfLiquidityCreator) -
                _pct(s.totalLP, c.percentOfLiquidityBurned);
            lpShare = uint128(
                (uint256(dep) * publicBase) / s.totalInviteContributed
            );
        }

        /* limit to vested amount */
        uint128 vestedShare = uint128(
            (uint256(lpShare) * s.lpPulled) / s.totalLP
        );
        uint128 owedLP = vestedShare - s.claimedLP[msg.sender];
        if (owedLP == 0) revert NothingToClaim(id);
        s.claimedLP[msg.sender] = vestedShare;

        /* translate owedLP to token amounts using current pools */
        uint64 inviteOut = uint64(
            (uint256(owedLP) * s.poolInvite) / s.lpPulled
        );
        uint64 utilityOut = uint64(
            (uint256(owedLP) * s.poolUtility) / s.lpPulled
        );

        s.poolInvite -= inviteOut;
        s.poolUtility -= utilityOut;

        c.invitingToken.transfer(msg.sender, inviteOut);
        offeringToken[id].transfer(msg.sender, utilityOut);

        emit LiquidityClaimed(id, msg.sender, inviteOut, utilityOut);
    }

    /// Reverse-lookup: utility-token address ⇒ rocket ID (0 → unknown).
    mapping(address => uint256) private _rocketIdOfToken;

    /*────────────────────  public views  ───────────────────*/
    /// @notice Rocket ID that produced `token` (0 if none).
    /// @param  token  Utility-token address to check.
    /// @return id     Rocket ID (starts at 1) or 0 when unknown.
    function idOfUtilityToken(
        address token
    ) external view returns (uint256 id) {
        return _rocketIdOfToken[token];
    }

    /// @notice Quick boolean test that `token` belongs to this launcher.
    /// @param  token  Utility-token address to verify.
    /// @return ok     True iff `token` was minted by one of this launcher’s rockets.
    function verify(address token) external view returns (bool ok) {
        return _rocketIdOfToken[token] != 0;
    }

    /*──────── misc view helpers ────────*/
    function theme() external view returns (string memory) {
        return _theme;
    }
}

/*════════════════════ RocketLauncherDeployer ══════════════════════*/
contract RocketLauncherDeployer is ReentrancyGuard {
    mapping(address => bool) private _spawned;
    event Deployed(
        address indexed launcher,
        address dex,
        address utd,
        string theme
    );

    function create(
        IDEX dex,
        IUTD utd,
        string calldata theme_
    ) external nonReentrant returns (address addr) {
        if (address(dex) == address(0)) revert ZeroAddress(address(0));
        if (address(utd) == address(0)) revert ZeroAddress(address(0));
        bytes32 salt = keccak256(
            abi.encodePacked(msg.sender, block.number, theme_)
        );
        addr = address(new RocketLauncher{salt: salt}(dex, utd, theme_));
        _spawned[addr] = true;
        emit Deployed(addr, address(dex), address(utd), theme_);
    }
    function verify(address l) external view returns (bool) {
        return _spawned[l];
    }
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=uGcsIdGOuZY";
    }
}
