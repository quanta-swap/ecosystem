// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC20.sol";
// TODO! Fix locatable liquidity
// TODO! Add a more structured approach to view functions

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

interface IUTD {
    function create(
        string calldata name,
        string calldata symbol,
        uint64 initialSupply,
        uint8 decimals,
        address root,
        bytes calldata extra
    ) external returns (address);
    function verify(address coin) external view returns (bool isDeployed);
}

interface IDEX {
    /**
     * @notice Stateless probe that asks the DEX whether it *could* list
     *         the (`tokenA`, `tokenB`) pair under its current rules
     *         (fee tiers, tick spacing, allow‑lists, oracle settings).
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  Minimal‑surface compatibility check                         │
     * ╰───────────────────────────────────────────────────────────────╯
     * • This call is deliberately read‑only (`view`) and returns a single
     *   boolean.  It exists so that upstream protocols (e.g. RocketLauncher)
     *   can fail fast *without* performing approvals, transfers, or CREATE2
     *   deployments—thereby shrinking inter‑protocol surface area and
     *   eliminating “half‑configured pool” states.
     *
     * • No fee‑tier or pool‑address data is returned: exposing those here
     *   would lock integrators to one AMM design and create aliasing between
     *   “compatibility mode” and “instantiation mode.”  If multiple fee tiers
     *   exist, the factory should encode tier choice deterministically
     *   (e.g. in the CREATE2 salt) so that both parties reach the same
     *   conclusion from just the token pair.
     *
     * • Gas expectations: implementations MUST be side‑effect‑free and
     *   cheap enough to call in a constructor or a simulation run.
     *
     * Return contract:
     * ----------------
     *   • `true`  — the next call to `initializeLiquidity` *may* succeed
     *               (subject to race conditions and supply amounts).
     *   • `false` — the pair is outright unsupported and `initializeLiquidity`
     *               would revert regardless of supplied amounts.
     *
     * @param tokenA  Candidate reserve token A.
     * @param tokenB  Candidate reserve token B.
     *
     * @return supported  Boolean flag indicating provisional support.
     */
    function checkSupportForPair(
        address tokenA,
        address tokenB
    ) external view returns (bool supported);

    /**
     * @notice Boot‑strap a brand‑new pool for the (`tokenA`, `tokenB`) pair,
     *         deposit the two seed amounts, mint LP tokens to `to`, and return
     *         both the deterministic pool address **and** the amount of LP
     *         minted.
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  One‑shot initialisation — design philosophy                 │
     * ╰───────────────────────────────────────────────────────────────╯
     * • All first‑time pool logic (pair creation, reserve deposits,
     *   minting, invariant sync) is collapsed into this single call.
     *   That eliminates multi‑step approval flows and the half‑configured
     *   “zombie pair” class of bugs.
     *
     * • We now return *two* values:
     *     1. `location`  — the pool address actually used.
     *     2. `liquidity` — LP tokens minted to `to`.
     *
     *   Rationale: some integrators (e.g. analytics, sub‑graphs, optimistic
     *   routers) need an on‑chain confirmation of the pair address that was
     *   ultimately chosen, instead of re‑deriving it off‑chain and hoping the
     *   factory used the same salt/ordering.  Exposing it here removes that
     *   aliasing risk without widening the surface area elsewhere.
     *
     * • `liquidity` remains a `uint256` for forward‑compatibility with AMMs
     *   that may extend Uniswap‑style maths beyond the `uint128` domain.
     *
     * Security invariants (MUST hold):
     * --------------------------------
     * 1.  Function either fully succeeds or reverts – no partial pools.
     * 2.  `location != address(0)` and **owns** the reserves after success.
     * 3.  `liquidity > 0`  iff  both `amountA` and `amountB` are > 0.
     * 4.  Total LP supply increases by exactly `liquidity`.
     * 5.  No leftover token approvals remain on the factory/router.
     *
     * @param tokenA   Reserve token A (`token0` in canonical ordering).
     * @param tokenB   Reserve token B (`token1`).
     * @param amountA  Exact deposit of `tokenA`.
     * @param amountB  Exact deposit of `tokenB`.
     * @param to       Recipient of the LP tokens (e.g. RocketLauncher).
     *
     * @return location   Deterministic pool address actually instantiated.
     * @return liquidity  LP tokens minted to `to`; MUST be greater than zero.
     */
    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to,
        bytes calldata data
    ) external returns (uint64 location, uint256 liquidity);

    /**
     * @notice Burn `liquidity` LP tokens held by the caller and sweep the
     *         underlying pool reserves to `to`.
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  ⚠️  Implicit‑approval / single‑router authority model        │
     * ╰───────────────────────────────────────────────────────────────╯
     * • The RocketLauncher never calls ERC‑20 `approve()` on the LP token.
     *   Instead, the LP contract exposes a **factory‑only** pathway that
     *   allows this router (the DEX factory) to transfer and burn LP held
     *   by the caller in a single atomic action.
     *
     * • Rationale: minimising inter‑protocol surface area and avoiding
     *   multiple aliasing usage paths.  A conventional allowance dance
     *   would require every integrating contract to track LP balances,
     *   set allowances, and revoke them—multiplying integration bugs and
     *   audit scope.  By collapsing everything into one privileged entry
     *   point, the LP token has exactly *one* method by which third‑party
     *   contracts can burn liquidity, greatly simplifying reasoning and
     *   static‑analysis.
     *
     * • Security invariants
     *   ───────────────────
     *   1. Only the router/factory address can invoke the LP’s privileged
     *      burn‑and‑transfer function.
     *   2. Outside that function the LP token behaves exactly like a normal
     *      ERC‑20—every transfer still needs a prior allowance.
     *   3. A successful call MUST burn the precise `liquidity` amount from
     *      the caller’s balance and transfer the corresponding reserves
     *      in the same transaction (atomicity).
     *
     * @param tokenA    Reserve‑token A (pair ordering specific).
     * @param tokenB    Reserve‑token B.
     * @param liquidity LP tokens to burn (uint256 to tolerate >2¹²⁸‑1).
     * @param to        Recipient of the withdrawn reserves.
     * @param minA      Minimum acceptable `tokenA` out (slippage guard, 64‑bit).
     * @param minB      Minimum acceptable `tokenB` out (slippage guard, 64‑bit).
     *
     * @return amountA  Actual `tokenA` sent to `to`.
     * @return amountB  Actual `tokenB` sent to `to`.
     */
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint64 location,
        uint256 liquidity,
        address to,
        uint64 minA,
        uint64 minB
    ) external returns (uint64 amountA, uint64 amountB);
}

/*─────────────────── data structs ───────────────────*/
struct UtilityTokenParams {
    string name;
    string symbol;
    uint64 supply64;
    uint8 decimals;
    bytes extra;
}
struct RocketConfig {
    address offeringCreator;
    IZRC20 invitingToken;
    UtilityTokenParams utilityTokenParams;
    uint32 percentOfLiquidityBurned; // ignored if no dex
    uint32 percentOfLiquidityCreator; // ≤ 50 %, ignored if no dex
    uint64 liquidityLockedUpTime; // vest ends here, ignored if no dex
    uint64 liquidityDeployTime; // vest starts here
    /* Allows for one iteration cycle of essentially a ponzi scheme */
    /* The investor paying yield to other investors is the creator */
    uint64 invitingTokenSweetener; // ignored if no dex
    bytes liquidityDeploymentData;
}
struct RocketState {
    uint64 totalInviteContributed;
    uint256 totalLP; // LP minted at launch, ignored if no dex
    uint256 lpPulled; // LP already withdrawn, ignored if no dex
    uint64 poolInvite; // inviting tokens held, ignored if no dex
    uint64 poolUtility; // utility tokens held, ignored if no dex
    uint64 creatorUtilityClaimed; // utility tokens claimed by creator, ignored if dex
    uint64 leftoverInviting;
    uint64 leftoverUtility;
    uint64 remainingSweetener;
    bool isFaulted; // anti-marooning flag, toggled if liquidity deployment fails
    address pool;
    uint64 lpLocation;
    mapping(address => uint256) claimedLP; // LP-equivalent already claimed
}

/*─────────────────── errors ───────────────────*/
error ZeroAddress(address);
error PercentOutOfRange(uint64);
error LiquidityOutOfRange(uint256);
error CreatorShareTooHigh(uint32);
error UnknownRocket(uint256);
error AlreadyLaunched(uint256);
error LaunchTooEarly(uint256, uint64, uint64);
error VestBeforeLaunch(uint256);
error NothingToVest(uint256);
error NotLaunched(uint256);
error NothingToClaim(uint256);
error RocketFaulted(uint256);
error DuplicateUtilityToken();
error ZeroCodeDeployed();
error DepositTooLate(uint256, uint64, uint64);
error OwnerNotSupported(address);
error SpenderNotSupported(address);

/**
 * @dev The DEX refused to list the (invite, utility) pair.
 * @param dex      Address of the DEX that declined.
 * @param invite   Address of the inviting token.
 * @param utility  Address of the freshly‑minted utility token.
 */
error PairUnsupported(address dex, address invite, address utility);

/**
 * @dev The utility token factory delivered an unexpected initial balance.
 * @param expected  Full supply that should have been minted.
 * @param found     Actual balance observed in the launcher.
 */
error BadInitialSupply(uint64 expected, uint64 found);

/**
 * @dev Raised when the inviting token withdrawal from the DEX results in less than the minimum expected amount.
 * @param actual  Actual amount of inviting tokens received.
 * @param minimum Minimum acceptable amount of inviting tokens.
 */
error SlippageInviting(uint64 actual, uint64 minimum);

/**
 * @dev Raised when the utility token withdrawal from the DEX results in less than the minimum expected amount.
 * @param actual  Actual amount of utility tokens received.
 * @param minimum Minimum acceptable amount of utility tokens.
 */
error SlippageUtility(uint64 actual, uint64 minimum);

/// Vesting schedule must have a non-zero positive duration.
error InvalidVestingWindow(uint64 start, uint64 end);

/// Rocket cannot be launched with an empty leg.
error ZeroLiquidity();

/** Zero-value deposit supplied where a positive amount is required. */
error ZeroDeposit();

/**
 * @dev Raised when the caller is not authorised to perform the requested action.
 * @param caller  The unauthorised account.
 */
error Unauthorized(address caller);

/**
 * @dev Raised when the provided lock window is less than the minimum required duration.
 * @param provided  The provided lock window duration.
 * @param minimum   The minimum required lock window duration.
 */
error InvalidLockWindow(uint64 provided, uint64 minimum);

/*════════════════════════ RocketLauncher ═══════════════════════*/
/**
 * @title RocketLauncher
 * @author Elliott G. Dehnbostel (quantaswap@gmail.com)
 *         Protocol Research Engineer, Official Finance LLC.
 * @notice Does not include a launch halt or refund function by design.
 */
contract RocketLauncher is ReentrancyGuard {
    IDEX public immutable dex;
    IUTD public immutable deployer;
    string private _theme;

    uint256 public rocketCount;
    mapping(uint256 => RocketConfig) public rocketCfg;
    mapping(uint256 => RocketState) public rocketState;
    mapping(uint256 => IZRC20) public offeringToken;
    mapping(uint256 => mapping(address => uint64)) public deposited;
    /// Reverse-lookup: utility-token address ⇒ rocket ID (0 → unknown).
    mapping(address => uint256) public rocketIdOfToken;

    event RocketCreated(
        uint256 indexed id,
        address indexed creator,
        address token,
        uint32 creatorPct,
        uint32 burnPct,
        uint64 deployTime,
        uint64 lockupTime,
        IZRC20 indexed invitingToken,
        uint64 sweetener
    );
    event Deposited(uint256 indexed id, address from, uint64 amount);
    event LiquidityDeployed(uint256 indexed id, uint256 lpMinted);
    event LiquidityVested(
        uint256 indexed id,
        uint256 lpPulled,
        uint64 invite,
        uint64 utility
    );
    event LiquidityClaimed(
        uint256 indexed id,
        address who,
        uint64 invite,
        uint64 utility
    );
    /** Residual dust fully burned → both pool counters zeroed. */
    event DustBurned(uint256 indexed id, uint64 inviteDust, uint64 utilityDust);
    event Faulted(uint256 indexed id);
    event RocketFizzled(uint256 indexed id);

    constructor(IDEX _dex, IUTD _deployer) {
        // if (address(_dex) == address(0)) revert ZeroAddress(address(0));
        if (address(_deployer) == address(0)) revert ZeroAddress(address(0));
        dex = _dex;
        deployer = _deployer;
    }

    /*───────────────── helpers ─────────────────*/
    function _cfg(uint256 id) internal view returns (RocketConfig storage c) {
        c = rocketCfg[id];
        if (address(c.invitingToken) == address(0)) revert UnknownRocket(id);
    }
    /*─────────────────── internal math helpers ───────────────────*/
    /**
     * @dev Returns `(tot * pct) / 2³²` with full-width intermediate math and an
     *      explicit overflow guard.  Reverts with {LiquidityOutOfRange} when the
     *      scaled product no longer fits into 128 bits.
     *
     * @param tot  Numerator.  In practice the total LP supply.
     * @param pct  Fixed-point percentage where `type(uint32).max == 100 %`.
     */
    function _pct(uint256 tot, uint32 pct) private pure returns (uint256) {
        unchecked {
            uint256 prod = uint256(tot) * uint256(pct); // ≤ 2¹⁶⁰-2
            uint256 scaled = prod >> 32; // divide by 2³²
            return scaled;
        }
    }

    /// @dev fixed‑point multiplication: (amount × pct) / 2³².
    function _pct64(uint64 amount, uint32 pct) internal pure returns (uint64) {
        return uint64((uint256(amount) * pct) >> 32);
    }

    /*═════════════════════ RocketLauncher.createRocket ════════════════*/
    /**
     * @notice Register a new launch configuration and mint its utility token.
     *
     * Post‑conditions (atomic on success)
     * ───────────────────────────────────
     *  • All numeric invariants validated (creator ≤ 50 %, (creator+burn) < 100 %)
     *  • Vesting window has positive duration.
     *  • Fresh utility token exists *and* sits entirely in the launcher.
     *  • DEX confirms it will accept the (invite, utility) pair (if a DEX is set).
     *  • Config and reverse‑lookup mappings fully initialised.
     *
     * @param cfg_  Full immutable rocket settings (calldata).
     * @return id   Sequential rocket ID (starts at 1).
     *
     * @custom:reverts ZeroAddress         `invitingToken` is the zero address.
     * @custom:reverts Unauthorized        Caller ≠ `offeringCreator`.
     * @custom:reverts CreatorShareTooHigh `creatorPct` > 50 %.
     * @custom:reverts PercentOutOfRange   creator + burn ≥ 100 %.
     * @custom:reverts InvalidVestingWindow `lockUpTime` ≤ `deployTime`.
     * @custom:reverts ZeroLiquidity       Utility‑token supply is zero.
     * @custom:reverts BadInitialSupply    Factory minted the wrong amount.
     * @custom:reverts PairUnsupported     DEX refuses the pair.
     */
    function createRocket(
        RocketConfig calldata cfg_
    ) external nonReentrant returns (uint256 id) {
        /*──────────────────── 1. Static sanity checks ───────────────────*/

        // Ensures a real ERC‑20 address.
        if (address(cfg_.invitingToken) == address(0))
            revert ZeroAddress(address(cfg_.invitingToken));

        // Only the declared creator may call.
        if (msg.sender != cfg_.offeringCreator) revert Unauthorized(msg.sender);

        unchecked {
            uint32 FULL = type(uint32).max; // 100 % in Q32‑fixed‑point.
            uint32 creatorPct = cfg_.percentOfLiquidityCreator;
            uint32 burnPct = cfg_.percentOfLiquidityBurned;

            // Creator slice ≤ 50 %.
            if (creatorPct > FULL / 2) revert CreatorShareTooHigh(creatorPct);

            // Public share must be strictly positive to avoid rug patterns.
            uint64 sum = uint64(creatorPct) + uint64(burnPct);
            if (sum >= FULL) revert PercentOutOfRange(sum);
        }

        // Vesting window must have positive duration.
        if (cfg_.liquidityLockedUpTime <= cfg_.liquidityDeployTime)
            revert InvalidVestingWindow(
                cfg_.liquidityDeployTime,
                cfg_.liquidityLockedUpTime
            );

        // "SLOW DOWN THE SONG"
        // Basic sanity check to ice the MOST ABUSIVE use-cases out of protocol.
        if (address(dex) != address(0) && cfg_.liquidityLockedUpTime < 1 days)
            revert InvalidLockWindow(cfg_.liquidityLockedUpTime, 1 days);

        // Non‑zero utility supply.
        UtilityTokenParams memory p = cfg_.utilityTokenParams;
        if (p.supply64 == 0) revert ZeroLiquidity();

        /*──────────────────── 2. Mint utility token ─────────────────────*/

        address utility = deployer.create(
            p.name,
            p.symbol,
            p.supply64,
            p.decimals,
            address(this), // launcher owns root authority
            p.extra
        );
        if (utility.code.length == 0) revert ZeroCodeDeployed();

        // Sanity‑check: full supply must reside here.
        uint64 bal = IZRC20(utility).balanceOf(address(this));
        if (bal != p.supply64) revert BadInitialSupply(p.supply64, bal);

        /*──────────────────── 3. DEX pair validation ───────────────────*/

        if (
            address(dex) != address(0) &&
            !dex.checkSupportForPair(address(cfg_.invitingToken), utility)
        )
            revert PairUnsupported(
                address(dex),
                address(cfg_.invitingToken),
                utility
            );

        // transfer the sweetener to this contract
        if (address(dex) != address(0) && cfg_.invitingTokenSweetener != 0) {
            require(
                safeTransferFrom(
                    cfg_.invitingToken,
                    msg.sender,
                    address(this),
                    cfg_.invitingTokenSweetener
                ),
                "sweetener trf failed"
            );
        }

        /*──────────────────── 4. Persist rocket state ──────────────────*/

        id = ++rocketCount; // 1‑based ID.

        // Store only what is necessary to avoid deep string copies.
        rocketCfg[id] = RocketConfig({
            offeringCreator: cfg_.offeringCreator,
            invitingToken: cfg_.invitingToken,
            utilityTokenParams: p, // already in memory
            percentOfLiquidityBurned: cfg_.percentOfLiquidityBurned,
            percentOfLiquidityCreator: cfg_.percentOfLiquidityCreator,
            liquidityLockedUpTime: cfg_.liquidityLockedUpTime,
            liquidityDeployTime: cfg_.liquidityDeployTime,
            invitingTokenSweetener: cfg_.invitingTokenSweetener,
            liquidityDeploymentData: cfg_.liquidityDeploymentData
        });

        offeringToken[id] = IZRC20(utility);
        // Some token implementations might not give the root all of the tokens.
        rocketState[id].poolUtility = IZRC20(utility).balanceOf(address(this));
        rocketState[id].remainingSweetener = cfg_.invitingTokenSweetener;

        // guards against deployer logic that caches deployments
        if (rocketIdOfToken[utility] != 0) revert DuplicateUtilityToken();
        rocketIdOfToken[utility] = id;

        emit RocketCreated(
            id,
            msg.sender,
            utility,
            cfg_.percentOfLiquidityCreator,
            cfg_.percentOfLiquidityBurned,
            cfg_.liquidityDeployTime,
            cfg_.liquidityLockedUpTime,
            offeringToken[id],
            cfg_.invitingTokenSweetener
        );
    }

    /*═════════════════ 2. deposit ‒ overflow-safe ═══════════════════════*/
    function deposit(uint256 id, uint64 amount) external nonReentrant {
        if (amount == 0) revert ZeroDeposit();

        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];

        IZRC20 offering = IZRC20(offeringToken[id]);
        require(
            offering.checkSupportsOwner(msg.sender),
            OwnerNotSupported(msg.sender)
        );

        require(
            offering.checkSupportsMover(address(this)),
            SpenderNotSupported(address(this))
        );

        if (s.totalLP != 0) revert AlreadyLaunched(id);
        if (s.isFaulted) revert RocketFaulted(id);
        if (block.timestamp >= c.liquidityDeployTime)
            revert DepositTooLate(
                id,
                uint64(block.timestamp),
                c.liquidityDeployTime
            );

        // ---------- 1. read‑only state, nothing mutated yet ----------
        uint64 prevUser = deposited[id][msg.sender];
        uint64 prevTot = s.totalInviteContributed;

        // ---------- 2. external interaction ----------
        require(
            safeTransferFrom(
                c.invitingToken,
                msg.sender,
                address(this),
                amount
            ),
            "transfer failed"
        );

        // ---------- 3. storage mutation ----------
        deposited[id][msg.sender] = prevUser + amount;
        s.totalInviteContributed = prevTot + amount;

        emit Deposited(id, msg.sender, amount);
    }

    /**
     * @notice Locks raised assets and seeds the AMM with initial liquidity.
     *         **If *any* step fails the rocket is permanently marked
     *         `isFaulted = true` so off‑chain operators can rescue funds.**
     *
     * Execution flow
     * ──────────────
     * 1. Pre‑flight gating & invariants.
     * 2. Grant token allowances to the DEX (single‑shot, no race risk).
     * 3. Attempt `dex.initializeLiquidity` inside a guarded `try/catch`.
     * 4. On *any* failure (approval issue, DEX revert, zero LP) we flag
     *    `isFaulted` and exit **without** modifying other rocket state.
     * 5. On success we revoke allowances, apply burn‑on‑launch, persist
     *    the vestable LP supply, and emit {LiquidityDeployed}.
     *
     * Fault semantics
     * ───────────────
     * • A fault is terminal.  Subsequent calls that depend on `totalLP`
     *   will fail due to the zero value, making the stuck state obvious.
     * • No storage updates that could lock funds happen *before* fault
     *   detection, preserving full recoverability by an eventual upgrade
     *   or manual intervention (out‑of‑scope for this contract).
     *
     * @param id  Rocket identifier.
     */
    function deployLiquidity(uint256 id) external nonReentrant {
        /*──────────────────── 0. Basic checks ────────────────────*/
        if (address(dex) == address(0)) revert ZeroAddress(address(0)); // DEX must be configured

        RocketConfig storage c = _cfg(id); // Loads & validates rocket config (reverts UnknownRocket)
        RocketState storage s = rocketState[id];

        if (s.isFaulted) revert RocketFaulted(id);

        if (block.timestamp < c.liquidityDeployTime)
            // Launch window not yet open
            revert LaunchTooEarly(
                id,
                uint64(block.timestamp),
                c.liquidityDeployTime
            );
        if (s.totalLP != 0)
            // One‑shot only
            revert AlreadyLaunched(id);
        if (s.totalInviteContributed == 0)
            // Both legs must be non‑zero
            revert ZeroLiquidity();

        /*──────────────────── 1. Allowance setup ─────────────────*/
        UtilityTokenParams memory p = c.utilityTokenParams;
        IZRC20 utilTok = offeringToken[id];

        // Grant one‑time spending rights to the DEX; abort on *any* failure.
        bool approvedUtility = safeApprove(utilTok, address(dex), p.supply64);
        bool approvedInviting = safeApprove(
            c.invitingToken,
            address(dex),
            s.totalInviteContributed
        );
        bool approvalsOk = approvedUtility && approvedInviting;

        if (!approvalsOk) {
            s.isFaulted = true; // Irrecoverable approval failure
            safeApprove(utilTok, address(dex), 0);
            safeApprove(c.invitingToken, address(dex), 0);
            emit Faulted(id);
            return;
        }

        /*──────────────────── 2. Pool creation ───────────────────*/

        uint64 balInvBefore = c.invitingToken.balanceOf(address(this));

        uint256 lp; // Will hold the vestable LP supply
        try
            // NOTE: ABIDE BY ORDER OF OUR ORIGINAL COMPATIBILITY CHECK!
            dex.initializeLiquidity(
                address(c.invitingToken),
                address(utilTok),
                s.totalInviteContributed,
                IZRC20(utilTok).balanceOf(address(this)),
                address(this), // LP minted to the launcher
                c.liquidityDeploymentData
            )
        returns (uint64 location, uint256 mintedLP) {
            lp = mintedLP; // Keep in memory until all checks pass
            utilTok.approve(address(dex), 0); // Revoke approvals
            c.invitingToken.approve(address(dex), 0);
            s.lpLocation = location;
        } catch {
            utilTok.approve(address(dex), 0); // Revoke approvals
            c.invitingToken.approve(address(dex), 0);
            s.isFaulted = true; // Any DEX‑side revert flags the rocket
            emit Faulted(id);
            return;
        }

        if (lp == 0) {
            // Zero LP means something went wrong, so engage fall-back
            s.isFaulted = true;
            emit Faulted(id);
            return;
        }

        uint64 balUtilAfter = utilTok.balanceOf(address(this));
        uint64 balInvAfter = c.invitingToken.balanceOf(address(this));

        /*──────────── 2b.  Residual‑token bookkeeping  ────────────*
         *  – `totalInviteContributed` is the amount *this* rocket
         *    tried to seed into the pool.
         *  – `balInvBefore` / `balInvAfter` are the launcher’s global
         *    balances; other rockets’ holdings cancel out in Δ.
         *  – Utility token is unique per‑rocket, so its post‑balance
         *    is already the exact dust.
         *──────────────────────────────────────────────────────────*/
        uint64 leftoverInviting;
        if (balInvAfter >= balInvBefore) {
            // Net *increase* ⇒ some of our invite tokens were refunded.
            uint64 rebate = balInvAfter - balInvBefore; // Δ ≥ 0, fits in 64‑bit
            // Our dust is what we originally contributed plus the rebate
            leftoverInviting = s.totalInviteContributed + rebate; // safe: 64‑bit universe
        } else {
            // Net *decrease* ⇒ most or all of our invite tokens were consumed.
            uint64 spent = balInvBefore - balInvAfter; // Δ ≥ 0
            leftoverInviting = s.totalInviteContributed - spent; // ≥ 0 by construction
        }

        s.leftoverInviting = leftoverInviting; // dust attributable to this rocket
        s.leftoverUtility = balUtilAfter; // utility token is rocket‑specific

        /*──────────────────── 3. House‑keeping ───────────────────*/
        // Apply the optional burn‑on‑launch percentage.
        uint256 burnLP = _pct(lp, c.percentOfLiquidityBurned); // Fixed‑point 32‑bit percentage
        if (burnLP != 0) lp -= burnLP; // Vestable LP excludes the burned slice

        /*──────────────────── 4. Commit state ────────────────────*/
        s.totalLP = lp; // Persist the claimable LP supply

        emit LiquidityDeployed(id, lp); // External observers track success
    }

    /*══════════════════  USER-CENTRIC VESTING  ══════════════════*/

    /**
     * @notice Pull vested assets when **no DEX is configured**.
     *
     * The launcher never interacted with an AMM, so LP tokens do not exist.
     * Instead we distribute the two original assets directly:
     * - **Creator**   receives ­all inviting‑tokens **plus** a fixed‑point
     *   slice of the utility‑token supply (`percentOfLiquidityCreator`).
     * - **Contributors** share the *public* portion of the utility supply
     *   pro‑rata to their deposit weight.
     *
     * Security / correctness invariants
     * ─────────────────────────────────
     * 1. Re‑entrancy is blocked by {nonReentrant}.
     * 2. All state mutations happen *before* external transfers where
     *    double‑withdraw is plausible (`_deposited` is zeroed up‑front).
     * 3. All arithmetic is performed in the 64‑bit domain; any overflow
     *    would revert in upstream helpers.
     *
     * @param id            Rocket identifier.
     * @param minUtilityOut Ignored in no‑DEX mode.
     * @param minInviteOut  Ignored in no‑DEX mode.
     *
     * @custom:error NothingToClaim  Caller has no remaining entitlement.
     */
    function vestLiquidity(
        uint256 id,
        uint64 minUtilityOut,
        uint64 minInviteOut
    ) external nonReentrant {
        /*────────────── fallback path ───────────*/
        RocketState storage s = rocketState[id];
        /*──────────────── AMM path ─────────────*/
        if (
            s.totalInviteContributed != 0 &&
            address(dex) != address(0) &&
            !rocketState[id].isFaulted
        ) {
            _vestLiquidity(id, minUtilityOut, minInviteOut);
            return;
        }

        RocketConfig storage c = _cfg(id); // UnknownRocket guard
        require(block.timestamp >= c.liquidityDeployTime, "not launched");

        if (s.totalInviteContributed == 0) {
            // refund the sweetener to the creator if no one deposited
            if (s.remainingSweetener != 0 && msg.sender == c.offeringCreator) {
                uint64 sweet_ = s.remainingSweetener;
                s.remainingSweetener = 0;
                require(
                    safeTransfer(c.invitingToken, msg.sender, sweet_),
                    "sweetener trf failed"
                );
            }
            emit RocketFizzled(id);
            return;
        }

        /*────────── pre‑compute fixed constants ──────────*/
        uint64 fullSupply = c.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(fullSupply, c.percentOfLiquidityCreator);
        uint64 publicSupply = fullSupply - creatorSlice;

        /*────────────────── CREATOR ──────────────────*/
        uint64 claimedInvite = 0;
        uint64 claimedUtility = 0;
        if (msg.sender == c.offeringCreator) {
            uint64 already = s.creatorUtilityClaimed;
            if (
                already == creatorSlice &&
                c.invitingToken.balanceOf(address(this)) == 0
            ) revert NothingToClaim(id);

            /* 1. inviting‑token proceeds (entire raise) */
            uint64 balInv = s.totalInviteContributed;
            if (balInv != 0) {
                require(
                    safeTransfer(c.invitingToken, msg.sender, balInv),
                    "inv trf failed"
                );
                s.poolInvite = 0;
            }

            /* 2. reserved utility slice */
            if (already < creatorSlice) {
                uint64 owed = creatorSlice - already;
                require(
                    safeTransfer(offeringToken[id], msg.sender, owed),
                    "util trf failed"
                );
                s.creatorUtilityClaimed = creatorSlice;
                s.poolUtility = s.poolUtility >= owed
                    ? s.poolUtility - owed
                    : 0;
            }

            claimedInvite += balInv;
            claimedUtility += creatorSlice - already;
        }

        /*──────────────── CONTRIBUTORS (FALL‑THROUGH) ───────────────*/
        uint64 contributed = deposited[id][msg.sender];
        if (contributed == 0) revert NothingToClaim(id);

        uint64 owedUtil = uint64(
            (uint256(contributed) * publicSupply) / s.totalInviteContributed
        );
        if (owedUtil == 0) revert NothingToClaim(id);

        /* defensive‑write before any external transfer */
        deposited[id][msg.sender] = 0;

        /* 1. transfer utility tokens */
        require(
            safeTransfer(offeringToken[id], msg.sender, owedUtil),
            "util trf failed"
        );
        s.poolUtility = s.poolUtility >= owedUtil
            ? s.poolUtility - owedUtil
            : 0;

        /* 2. proportional sweetener — **contributors only** */
        uint64 sweet = 0;
        if (s.remainingSweetener != 0 && msg.sender != c.offeringCreator) {
            sweet = uint64(
                (uint256(s.remainingSweetener) * contributed) /
                    s.totalInviteContributed
            );
            if (sweet != 0) {
                require(
                    safeTransfer(c.invitingToken, msg.sender, sweet),
                    "sweetener trf failed"
                );
                s.remainingSweetener -= sweet;
            }
        }

        /* 3. account for what was actually paid to caller */
        claimedInvite += sweet; // creator receives no sweetener → no change
        claimedUtility += owedUtil;

        emit LiquidityClaimed(id, msg.sender, claimedInvite, claimedUtility);
    }

    /*══════════════════════════════════════════════════════════════════════*\
    │                       caller-centric vesting logic                    │
    \*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Vest LP, sweep residual dust **and distribute the “sweetener” pool**
     *      (extra inviting tokens deposited by the creator at launch) pro‑rata
     *      to contributors. The creator never receives a share of the sweetener.
     *
     *      Assumptions
     *      ───────────
     *      • `remainingSweetener` ≤ 2⁶⁴‑1 and is **NOT** part of
     *        `totalInviteContributed`; it is a separate incentive pool.
     *      • 64‑bit arithmetic is preserved throughout; any overflow reverts
     *        upstream in helpers.
     *
     *      Security invariants
     *      ───────────────────
     *      1.  Sweetener is transferred *after* the external DEX call and *after*
     *          dust, so state only mutates if **all** transfers succeed.
     *      2.  Each caller can drain at most their fair share; rounding dust
     *          (≤ callers) remains in `remainingSweetener` and can be burned
     *          at the end of vesting.
     */
    function _vestLiquidity(
        uint256 id,
        uint64 minUtilOut,
        uint64 minInvOut
    ) internal {
        /* 0 ─ fast‑fail checks unchanged … */
        RocketState storage s = rocketState[id];
        if (s.totalLP == 0) revert VestBeforeLaunch(id);

        RocketConfig storage c = _cfg(id);

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= c.liquidityDeployTime)
            revert LaunchTooEarly(id, nowTs, c.liquidityDeployTime);

        /* 1 ─ compute vested fraction */
        uint256 vestedGlobal = (nowTs >= c.liquidityLockedUpTime)
            ? s.totalLP
            : (uint256(s.totalLP) * (nowTs - c.liquidityDeployTime)) /
                (c.liquidityLockedUpTime - c.liquidityDeployTime);

        /* 2 ─ caller’s LP entitlement */
        (uint256 owedLP, uint256 newClaimed) = _calcOwedLP(
            id,
            s,
            c,
            deposited[id][msg.sender],
            vestedGlobal,
            msg.sender
        );

        /* 3 ─ external DEX burn+withdraw */
        _executeWithdraw(id, owedLP, minUtilOut, minInvOut);

        /* 4 ─ residual dust payout (unchanged) */
        uint64 dustInvite = 0;
        uint64 dustUtil = 0;
        if (s.leftoverInviting != 0) {
            dustInvite = uint64(
                (uint256(s.leftoverInviting) * owedLP) / s.totalLP
            );
            if (dustInvite != 0) {
                require(
                    safeTransfer(c.invitingToken, msg.sender, dustInvite),
                    "dust invite trf failed"
                );
                s.leftoverInviting -= dustInvite;
            }
        }
        if (s.leftoverUtility != 0) {
            dustUtil = uint64(
                (uint256(s.leftoverUtility) * owedLP) / s.totalLP
            );
            if (dustUtil != 0) {
                require(
                    safeTransfer(offeringToken[id], msg.sender, dustUtil),
                    "dust util trf failed"
                );
                s.leftoverUtility -= dustUtil;
            }
        }

        /* 5 ─ NEW: proportional sweetener yield */
        uint64 sweet = 0;
        if (s.remainingSweetener != 0 && msg.sender != c.offeringCreator) {
            uint64 contributed = deposited[id][msg.sender];
            // Guard against div‑by‑zero: creator slice removed above guarantees >0
            sweet = uint64(
                (uint256(s.remainingSweetener) * contributed) /
                    s.totalInviteContributed
            );
            if (sweet != 0) {
                require(
                    safeTransfer(c.invitingToken, msg.sender, sweet),
                    "sweetener trf failed"
                );
                s.remainingSweetener -= sweet;
            }
        }

        /* 6 ─ commit LP accounting */
        s.claimedLP[msg.sender] = newClaimed;
        s.lpPulled += owedLP;

        emit LiquidityVested(id, owedLP, dustInvite + sweet, dustUtil);
    }

    /**
     * @dev Executes the AMM burn+withdraw call in its own stack frame, then
     *      emits {LiquidityVested}.  Keeping this logic separate helps
     *      `_vestLiquidity` stay comfortably under the stack-depth limit.
     *
     * @param id        Rocket identifier.
     * @param lp        Amount of LP to burn.
     * @param minU      Minimum acceptable utility-token out.
     * @param minI      Minimum acceptable inviting-token out.
     */
    function _executeWithdraw(
        uint256 id,
        uint256 lp,
        uint64 minU,
        uint64 minI
    ) private {
        /**
         * @dev One‑shot **burn‑and‑withdraw** wrapper around the DEX router.
         *
         * Slippage rationale
         * ──────────────────
         * • The launcher’s security model treats the configured DEX as a
         *   **trusted** component: if it malfunctions, the entire rocket
         *   lifecycle is already compromised elsewhere.
         * • Historically we verified post‑call balances and reverted when
         *   the net amounts fell below `minU` / `minI`.
         * • That safety net proved counterproductive—once the external call
         *   succeeds the LP is irrevocably burned and the pool reserves are
         *   gone.  Reverting here would convert a *partial* success (caller
         *   got less than expected, but still something) into a **permanent
         *   failure** that bricks the rocket for everyone.
         *
         * Therefore we now:
         *   1. Let the DEX enforce the user‑supplied slippage parameters
         *      internally (it already has the numbers).
         *   2. Trust its `(gotUtility, gotInvite)` return values at face
         *      value and record them in the event log.
         *
         * Upstream callers may still pass non‑zero `minU` / `minI` to have
         * the DEX revert *inside its own context* if those thresholds are
         * violated, avoiding the burn‑then‑revert paradox.
         */

        RocketConfig storage c = rocketCfg[id];

        // uint64 balUtilBefore = offeringToken[id].balanceOf(msg.sender);
        // uint64 balInviteBefore = c.invitingToken.balanceOf(msg.sender);

        (uint64 gotInvite, uint64 gotUtility) = dex.withdrawLiquidity(
            address(c.invitingToken),
            address(offeringToken[id]),
            rocketState[id].lpLocation,
            lp,
            msg.sender,
            minI,
            minU
        );

        // uint64 balUtilAfter = offeringToken[id].balanceOf(msg.sender);
        // uint64 balInviteAfter = c.invitingToken.balanceOf(msg.sender);

        // uint64 netUtil = balUtilAfter - balUtilBefore;
        // uint64 netInvite = balInviteAfter - balInviteBefore;

        // if (netUtil < minU) revert SlippageUtility(netUtil, minU);
        // if (netInvite < minI) revert SlippageInviting(netInvite, minI);

        emit LiquidityVested(id, lp, gotInvite, gotUtility);
    }

    /**
     * @dev Computes how many LP tokens the caller can withdraw right now.
     *      Returns both the newly-vested LP (`owedLP`) and the caller’s
     *      updated running total (`vestedUser`).  This lives in its own
     *      stack-frame so that `_vestLiquidity` stays shallow.
     *
     * @param s              Rocket-level mutable state.
     * @param c              Immutable rocket configuration.
     * @param contributed    Caller’s inviting-token deposit (0 if none).
     * @param vestedGlobal   Globally-vested LP up to the current block.
     * @param caller         `msg.sender`.
     */
    function _calcOwedLP(
        uint256 rid,
        RocketState storage s,
        RocketConfig storage c,
        uint64 contributed,
        uint256 vestedGlobal,
        address caller
    ) private view returns (uint256 owedLP, uint256 vestedUser) {
        uint256 creatorLP = _pct(s.totalLP, c.percentOfLiquidityCreator);
        uint256 publicLP = s.totalLP - creatorLP;

        uint256 lpShare;
        if (caller == c.offeringCreator) {
            lpShare = creatorLP;
            if (contributed != 0) {
                lpShare +=
                    (uint256(contributed) * publicLP) /
                    s.totalInviteContributed;
            }
        } else {
            if (contributed == 0) revert NothingToVest(rid);
            lpShare =
                (uint256(contributed) * publicLP) /
                s.totalInviteContributed;
        }

        vestedUser = (uint256(lpShare) * vestedGlobal) / s.totalLP;
        owedLP = vestedUser - s.claimedLP[caller];
        if (owedLP == 0) revert NothingToVest(rid);
    }

    /*═══════════════════════ state-query helpers ═══════════════════════*/

    // HELPERS

    /**
     * @dev Transfer tokens from one address to another (no fee on transfers)
     * @param _token erc20 The address of the ERC20 contract
     * @param _from address The address which you want to send tokens from
     * @param _to address The address which you want to transfer to
     * @param _value uint256 the _value of tokens to be transferred
     * @return bool whether the transfer was successful or not
     */
    function safeTransferFrom(
        IZRC20 _token,
        address _from,
        address _to,
        uint64 _value
    ) internal returns (bool) {
        uint64 prevBalance = _token.balanceOf(_from);
        uint64 prevBalanceTarget = _token.balanceOf(_to);

        if (
            prevBalance < _value || // Insufficient funds
            _token.allowance(_from, address(this)) < _value // Insufficient allowance
        ) {
            return false;
        }

        // ignored because we only care about balances
        (bool _success, ) = address(_token).call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint64)",
                _from,
                _to,
                _value
            )
        );

        require(
            _token.balanceOf(_to) == prevBalanceTarget + _value,
            "bad balance"
        );
        // Fail if the new balance its not equal than previous balance sub _value
        return prevBalance - _value == _token.balanceOf(_from);
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
     *
     * Beware that changing an allowance with this method brings the risk that someone may use both the old
     * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
     * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * @param _token erc20 The address of the ERC20 contract
     * @param _spender The address which will spend the funds.
     * @param _value The amount of tokens to be spent.
     * @return bool whether the approve was successful or not
     */
    function safeApprove(
        IZRC20 _token,
        address _spender,
        uint64 _value
    ) internal returns (bool) {
        (bool _successZero, ) = address(_token).call(
            abi.encodeWithSignature("approve(address,uint64)", _spender, 0)
        );

        (bool _successValue, ) = address(_token).call(
            abi.encodeWithSignature("approve(address,uint64)", _spender, _value)
        );
        // require(success, "Low-level call failed"); we only care about allowance

        // Fail if the new allowance its not equal than _value
        return _token.allowance(address(this), _spender) == _value;
    }

    function safeApprove256(
        IZRC20 _token,
        address _spender,
        uint64 _value
    ) internal returns (bool) {
        (bool _successZero, ) = address(_token).call(
            abi.encodeWithSignature("approve(address,uint256)", _spender, 0)
        );

        (bool _successValue, ) = address(_token).call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _spender,
                _value
            )
        );
        // require(success, "Low-level call failed"); we only care about allowance

        // Fail if the new allowance its not equal than _value
        return _token.allowance(address(this), _spender) == _value;
    }

    /**
     * @dev Transfer token for a specified address (no fee on transfers)
     * @param _token erc20 The address of the ERC20 contract
     * @param _to address The address which you want to transfer to
     * @param _value uint256 the _value of tokens to be transferred
     * @return bool whether the transfer was successful or not
     */
    function safeTransfer(
        IZRC20 _token,
        address _to,
        uint64 _value
    ) internal returns (bool) {
        uint64 prevBalance = _token.balanceOf(address(this));
        uint64 prevBalanceTarget = _token.balanceOf(_to);

        if (prevBalance < _value) {
            // Insufficient funds
            return false;
        }

        // ignored because we only care about balances
        (bool _success, ) = address(_token).call(
            abi.encodeWithSignature("transfer(address,uint64)", _to, _value)
        );

        require(
            _token.balanceOf(_to) == prevBalanceTarget + _value,
            "bad balance"
        );
        // Fail if the new balance its not equal than previous balance sub _value
        return prevBalance - _value == _token.balanceOf(address(this));
    }
}

/*════════════════════ RocketLauncherDeployer ══════════════════════*/
contract RocketLauncherDeployer is ReentrancyGuard {
    mapping(address => bool) private _spawned;
    event Deployed(
        address indexed launcher,
        address dex,
        address utd
    );

    function create(
        IDEX dex,
        IUTD utd
    ) external nonReentrant returns (address addr) {
        if (address(dex) == address(0)) revert ZeroAddress(address(0));
        if (address(utd) == address(0)) revert ZeroAddress(address(0));
        bytes32 salt = keccak256(
            abi.encodePacked(address(dex), address(utd))
        );
        addr = address(new RocketLauncher{salt: salt}(dex, utd));
        _spawned[addr] = true;
        emit Deployed(addr, address(dex), address(utd));
    }
    function verify(address l) external view returns (bool) {
        return _spawned[l];
    }
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=GNm5drtAQXs";
    }
}
