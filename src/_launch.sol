// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*═══════════════════════════════════════════════════════════════════════*\
│                              ReentrancyGuard                           │
\*═══════════════════════════════════════════════════════════════════════*/
/**
 * @dev Minimal, in-file copy of OpenZeppelin’s {ReentrancyGuard}.  Adds the
 *      `nonReentrant` modifier to block re-entrant calls on all state-changing
 *      external functions that touch funds or mutate storage.
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/*═══════════════════════════════════════════════════════════════════════*\
│                         RocketLauncher (multi-rocket)                  │
\*═══════════════════════════════════════════════════════════════════════*/
/**
 * @title  RocketLauncher — multi-rocket liquidity bootstrapper (non-reentrant)
 * @author Elliott G. Dehnbostel
 * @notice See inline NatSpec for full behaviour description.
 * @dev    All external, state-mutating functions are `nonReentrant`.
 */
interface IZRC20 {
    event Transfer(address indexed from, address indexed to, uint64 value);
    event Approval(address indexed owner, address indexed spender, uint64 value);

    /* view */ function totalSupply() external view returns (uint64);
    function balanceOf(address) external view returns (uint64);
    function allowance(address, address) external view returns (uint64);
    /* actions */ function approve(address, uint64) external returns (bool);
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
    ) external returns (uint256);
    function withdrawLiquidity(
        address,
        address,
        uint128,
        address
    ) external returns (uint64, uint64);
}

/*──── shared structs ────*/
struct UtilityTokenParams {
    string name;
    string symbol;
    uint64 supply64;
    uint8 decimals;
    uint32 lockTime;
    address root;
    string theme;
}
struct RocketConfig {
    address offeringCreator;
    IZRC20 invitingToken;
    UtilityTokenParams utilityTokenParams;
    uint32 percentOfLiquidityBurned;
    uint32 percentOfLiquidityCreator;
    uint64 liquidityLockedUpTime;
    uint64 liquidityDeployTime;
}
struct RocketState {
    uint64 totalInviteContributed;
    uint128 totalLiquidityDeployed;
    uint128 totalLiquidityClaimed;
}

/*──── errors ────*/
error ZeroAddress(address);
error PercentOutOfRange(uint32);
error CreatorShareTooHigh(uint32);
error UnknownRocket(uint256);
error AlreadyLaunched(uint256);
error LaunchTooEarly(uint256, uint64, uint64);
error ClaimTooEarly(uint256, uint64, uint64);
error NothingToClaim(uint256);
error NotLaunched(uint256);

/*════════════════════════════ RocketLauncher ══════════════════════════*/
contract RocketLauncher is ReentrancyGuard {
    IDEX public immutable dex;
    IUTD public immutable deployer;
    string private _theme;

    uint256 public rocketCount;
    mapping(uint256 => RocketConfig) public rocketCfg;
    mapping(uint256 => RocketState) public rocketState;
    mapping(uint256 => IZRC20) public offeringToken;
    mapping(uint256 => mapping(address => uint64)) private _contrib;
    mapping(uint256 => mapping(address => uint128)) private _claimedLP;

    event RocketCreated(uint256 indexed rid, address creator, address token);
    event Deposited(uint256 indexed rid, address from, uint64 amount);
    event LiquidityDeployed(uint256 indexed rid, uint128 lpMinted);
    event LiquidityClaimed(uint256 indexed rid, address who, uint128 lpAmt);

    constructor(IDEX _dex, IUTD _deployer, string memory themeURI) {
        if (address(_dex) == address(0)) revert ZeroAddress(address(0));
        if (address(_deployer) == address(0)) revert ZeroAddress(address(0));
        dex = _dex;
        deployer = _deployer;
        _theme = themeURI;
    }

    /*────────────────── internal helpers ─────────────────*/
    function _cfg(uint256 rid) internal view returns (RocketConfig storage c) {
        c = rocketCfg[rid];
        if (address(c.invitingToken) == address(0)) revert UnknownRocket(rid);
    }
    function _percentOf(uint128 t, uint32 p) private pure returns (uint128) {
        return uint128((uint256(t) * p) >> 32);
    }

    /*════════════ 0. createRocket ═══════════*/
    function createRocket(
        RocketConfig calldata cfg_
    ) external nonReentrant returns (uint256 rid) {
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

        rid = ++rocketCount;
        rocketCfg[rid] = cfg_;
        offeringToken[rid] = IZRC20(tok);
        emit RocketCreated(rid, msg.sender, tok);
    }

    /*════════════ 1. deposit ═══════════*/
    function deposit(uint256 rid, uint64 amt) external nonReentrant {
        RocketConfig storage c = _cfg(rid);
        RocketState storage s = rocketState[rid];
        if (s.totalLiquidityDeployed != 0) revert AlreadyLaunched(rid);

        c.invitingToken.transferFrom(msg.sender, address(this), amt);
        _contrib[rid][msg.sender] += amt;
        s.totalInviteContributed += amt;
        emit Deposited(rid, msg.sender, amt);
    }

    /*════════════ 2. deployLiquidity ═══════════*/
    function deployLiquidity(uint256 rid) external nonReentrant {
        RocketConfig storage c = _cfg(rid);
        RocketState storage s = rocketState[rid];

        if (block.timestamp < c.liquidityDeployTime)
            revert LaunchTooEarly(
                rid,
                uint64(block.timestamp),
                c.liquidityDeployTime
            );
        if (s.totalLiquidityDeployed != 0) revert AlreadyLaunched(rid);

        UtilityTokenParams memory p = c.utilityTokenParams;
        IZRC20 tok = offeringToken[rid];

        tok.approve(address(dex), p.supply64);
        c.invitingToken.approve(address(dex), s.totalInviteContributed);

        uint256 lp = dex.initializeLiquidity(
            address(tok),
            address(c.invitingToken),
            p.supply64,
            s.totalInviteContributed,
            address(this)
        );
        s.totalLiquidityDeployed = uint128(lp);
        emit LiquidityDeployed(rid, uint128(lp));
    }

    /*════════════ 3. claimLiquidity ═══════════*/
    function claimLiquidity(uint256 rid) external nonReentrant {
        RocketConfig storage c = _cfg(rid);
        RocketState storage s = rocketState[rid];
        uint128 totalLP = s.totalLiquidityDeployed;
        if (totalLP == 0) revert NotLaunched(rid);
        if (block.timestamp < c.liquidityLockedUpTime)
            revert ClaimTooEarly(
                rid,
                uint64(block.timestamp),
                c.liquidityLockedUpTime
            );

        uint128 share;
        if (msg.sender == c.offeringCreator) {
            share = _percentOf(totalLP, c.percentOfLiquidityCreator);
        } else {
            uint64 inv = _contrib[rid][msg.sender];
            if (inv == 0) revert NothingToClaim(rid);
            uint128 base = totalLP -
                _percentOf(totalLP, c.percentOfLiquidityCreator) -
                _percentOf(totalLP, c.percentOfLiquidityBurned);
            share = uint128((uint256(inv) * base) / s.totalInviteContributed);
        }
        uint128 owed = share - _claimedLP[rid][msg.sender];
        if (owed == 0) revert NothingToClaim(rid);

        _claimedLP[rid][msg.sender] += owed;
        s.totalLiquidityClaimed += owed;

        dex.withdrawLiquidity(
            address(offeringToken[rid]),
            address(c.invitingToken),
            owed,
            msg.sender
        );
        emit LiquidityClaimed(rid, msg.sender, owed);
    }

    /*──────── view helpers ────────*/
    function burnedShare(uint256 rid) external view returns (uint128) {
        return
            _percentOf(
                rocketState[rid].totalLiquidityDeployed,
                rocketCfg[rid].percentOfLiquidityBurned
            );
    }
    function creatorShare(uint256 rid) external view returns (uint128) {
        return
            _percentOf(
                rocketState[rid].totalLiquidityDeployed,
                rocketCfg[rid].percentOfLiquidityCreator
            );
    }
    function theme() external view returns (string memory) {
        return _theme;
    }
}

/*═══════════════════════════════════════════════════════════════════════*\
│                       RocketLauncherDeployer (factory)                 │
\*═══════════════════════════════════════════════════════════════════════*/
contract RocketLauncherDeployer is ReentrancyGuard {
    mapping(address => bool) private _isDeployed;
    event Deployed(
        address indexed launcher,
        address dex,
        address utd,
        string theme
    );

    /**
     * @notice Deploy a new RocketLauncher with a caller-chosen theme URI.
     * @param dex   DEX router / pair initializer.
     * @param utd   Utility-token factory passed to the launcher.
     * @param theme_ Contract-level theme URI for the launcher.
     */
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
        _isDeployed[addr] = true;
        emit Deployed(addr, address(dex), address(utd), theme_);
    }

    /** Simple provenance check for UIs / indexers. */
    function verify(address launcher) external view returns (bool) {
        return _isDeployed[launcher];
    }

    /** Factory’s own soundtrack. */
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=uGcsIdGOuZY";
    }
}
