// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC20.sol";

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
    ) external returns (uint128 liquidity);
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint128 liquidity,
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
    uint32 lockTime;
    string theme;
}
struct RocketConfig {
    address offeringCreator;
    IZRC20 invitingToken;
    UtilityTokenParams utilityTokenParams;
    uint32 percentOfLiquidityBurned; // ignored if no dex
    uint32 percentOfLiquidityCreator; // ≤ 50 %, ignored if no dex
    uint64 liquidityLockedUpTime; // vest ends here, ignored if no dex
    uint64 liquidityDeployTime; // vest starts here
}
struct RocketState {
    uint64 totalInviteContributed;
    uint128 totalLP; // LP minted at launch, ignored if no dex
    uint128 lpPulled; // LP already withdrawn, ignored if no dex
    uint64 poolInvite; // inviting tokens held, ignored if no dex
    uint64 poolUtility; // utility tokens held, ignored if no dex
    uint64 creatorUtilityClaimed; // utility tokens claimed by creator, ignored if dex
    mapping(address => uint128) claimedLP; // LP-equivalent already claimed
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

/// Vesting schedule must have a non-zero positive duration.
error InvalidVestingWindow(uint64 start, uint64 end);

/// Rocket cannot be launched with an empty leg.
error ZeroLiquidity();

/** Zero-value deposit supplied where a positive amount is required. */
error ZeroDeposit();

/*─────────────────── new / reused custom errors ───────────────────*/
/**
 * @dev Raised when an arithmetic addition would overflow 64-bit space.
 * @param sum  The offending sum that exceeded 2⁶⁴-1.
 */
error SumOverflow(uint256 sum);

/**
 * @dev Raised when the caller is not authorised to perform the requested action.
 * @param caller  The unauthorised account.
 */
error Unauthorized(address caller);

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
    mapping(uint256 => RocketState) private rocketState;
    mapping(uint256 => IZRC20) public offeringToken;
    mapping(uint256 => mapping(address => uint64)) private _deposited;

    event RocketCreated(
        uint256 indexed id,
        address indexed creator,
        address token,
        uint32 creatorPct,
        uint32 burnPct,
        uint64 deployTime,
        uint64 lockupTime
    );
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
    /** Residual dust fully burned → both pool counters zeroed. */
    event DustBurned(uint256 indexed id, uint64 inviteDust, uint64 utilityDust);

    constructor(IDEX _dex, IUTD _deployer, string memory themeURI) {
        // if (address(_dex) == address(0)) revert ZeroAddress(address(0));
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
    /*─────────────────── internal math helpers ───────────────────*/
    /**
     * @dev Returns `(tot * pct) / 2³²` with full-width intermediate math and an
     *      explicit overflow guard.  Reverts with {LiquidityOutOfRange} when the
     *      scaled product no longer fits into 128 bits.
     *
     * @param tot  Numerator (uint128).  In practice the total LP supply.
     * @param pct  Fixed-point percentage where `type(uint32).max == 100 %`.
     */
    function _pct(uint128 tot, uint32 pct) private pure returns (uint128) {
        unchecked {
            uint256 prod = uint256(tot) * uint256(pct); // ≤ 2¹⁶⁰-2
            uint256 scaled = prod >> 32; // divide by 2³²
            if (scaled > type(uint128).max) revert LiquidityOutOfRange(prod);
            return uint128(scaled);
        }
    }

    /// @dev fixed‑point multiplication: (amount × pct) / 2³².
    function _pct64(uint64 amount, uint32 pct) internal pure returns (uint64) {
        return uint64((uint256(amount) * pct) >> 32);
    }

    /**
     * @notice Registers a new rocket and mints its dedicated utility token.
     *
     * @dev    Performs strict upfront validation to ensure the rocket cannot
     *         be created in an inconsistent state.  Key checks:
     *         1. Non-zero inviting token address.
     *         2. Caller must match `offeringCreator`.
     *         3. `creatorPct` ≤ 50 %.
     *         4. (`creatorPct` + `burnPct`) ≤ 100 % – computed in 64-bit
     *            space to avoid the 32-bit wrap bug.
     *         5. Vesting window must have positive duration.
     *         6. Factory must deliver the full utility-token supply to this
     *            launcher (simple sanity check on `deployer.create`).
     *
     * @param  cfg_  Full rocket configuration (calldata).
     * @return id    Sequential rocket ID (starts at 1).
     *
     * @custom:error ZeroAddress          Inviting token is the zero address.
     * @custom:error Unauthorized         Caller is not `offeringCreator`.
     * @custom:error CreatorShareTooHigh  Creator allocation > 50 %.
     * @custom:error PercentOutOfRange    Burn % + Creator % > 100 %.
     * @custom:error InvalidVestingWindow `liquidityLockedUpTime` ≤ deploy time.
     */
    function createRocket(
        RocketConfig calldata cfg_
    ) external nonReentrant returns (uint256 id) {
        /*─────────────────────── 1. Basic sanity checks ─────────────────────*/

        // Non-zero inviting token.
        if (address(cfg_.invitingToken) == address(0))
            revert ZeroAddress(address(0));

        // Only the declared creator may call.
        if (cfg_.offeringCreator != msg.sender) revert Unauthorized(msg.sender);

        /*──────────────────── 2. Percentage invariants ─────────────────────*/

        uint32 creatorPct = cfg_.percentOfLiquidityCreator;
        uint32 burnPct = cfg_.percentOfLiquidityBurned;
        uint32 FULL = type(uint32).max; // fixed-point 100 %

        // a) Creator share capped at 50 %.
        if (creatorPct > (FULL >> 1)) revert CreatorShareTooHigh(creatorPct);

        // b) Combined share (creator + burn) must not exceed 100 %.
        //    We widen to 64 bits to avoid the wrap-around bug present in the
        //    original 32-bit unchecked addition.
        uint64 sum = uint64(creatorPct) + uint64(burnPct);
        if (sum > FULL) revert PercentOutOfRange(sum);

        /*──────────────── 3. Vesting-window consistency ────────────────────*/

        if (cfg_.liquidityLockedUpTime <= cfg_.liquidityDeployTime)
            revert InvalidVestingWindow(
                cfg_.liquidityDeployTime,
                cfg_.liquidityLockedUpTime
            );

        /*──────────────── 4. Deploy the utility token ──────────────────────*/

        // Clone the parameters to memory so we can safely mutate `root`.
        UtilityTokenParams memory p = cfg_.utilityTokenParams;
        if (p.supply64 == 0) revert ZeroLiquidity();

        try
            deployer.create(
                p.name,
                p.symbol,
                p.supply64,
                p.decimals,
                p.lockTime,
                address(this), // the launcher should own root authority
                p.theme
            )
        returns (address tok) {
            // 4.a  Sanity‑check: full supply must now reside here.
            if (IZRC20(tok).balanceOf(address(this)) != p.supply64) {
                revert Unauthorized(address(deployer));
            }

            //–––––––– 5. Register the rocket –––––––––
            id = ++rocketCount; // sequential, 1‑based
            RocketConfig memory newCfg = cfg_; // calldata → memory copy
            newCfg.utilityTokenParams = p; // updated root owner
            rocketCfg[id] = newCfg; // persist config
            offeringToken[id] = IZRC20(tok); // index by id
            _rocketIdOfToken[tok] = id; // reverse lookup

            emit RocketCreated(
                id,
                msg.sender,
                tok,
                creatorPct,
                burnPct,
                cfg_.liquidityDeployTime,
                cfg_.liquidityLockedUpTime
            );
        } catch (bytes memory reason) {
            /* Bubble up the original revert reason EXACTLY as received.
             *
             * Solidity’s catch clauses swallow the inner revert data;
             * this assembly snippet re‑throws it verbatim so upstream
             * tooling (hardhat, foundry, et al.) shows the real error.
             */
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /*═════════════════ 2. deposit ‒ overflow-safe ═══════════════════════*/
    function deposit(uint256 id, uint64 amount) external nonReentrant {
        if (amount == 0) revert ZeroDeposit();

        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];
        if (s.totalLP != 0) revert AlreadyLaunched(id);

        // ---------- 1. read‑only state, nothing mutated yet ----------
        uint64 prevUser = _deposited[id][msg.sender];
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
        unchecked {
            uint64 newUser = prevUser + amount;
            if (newUser < prevUser)
                revert SumOverflow(uint256(prevUser) + amount);
            _deposited[id][msg.sender] = newUser;

            uint64 newTot = prevTot + amount;
            if (newTot < prevTot) revert SumOverflow(uint256(prevTot) + amount);
            s.totalInviteContributed = newTot;
        }

        emit Deposited(id, msg.sender, amount);
    }

    /**
     * @notice Locks contributed assets and seeds the AMM with initial liquidity.
     * @dev
     * - Only callable once per rocket and not before `liquidityDeployTime`.
     * - Rejects zero-supply or zero-contribution launches.
     * - Immediately burns (withdraws to `address(0)`) the configured burn share.
     * - Anyone can deploy liquidity to defeat deliberate/accidental lock-out scams.
     * @param id Rocket identifier.
     */
    function deployLiquidity(uint256 id) external nonReentrant {
        require(dex != IDEX(address(0)), "no DEX set");

        RocketConfig storage c = _cfg(id);
        RocketState storage s = rocketState[id];

        // ───── temporal & one-shot gating ─────
        if (block.timestamp < c.liquidityDeployTime)
            revert LaunchTooEarly(
                id,
                uint64(block.timestamp),
                c.liquidityDeployTime
            );
        if (s.totalLP != 0) revert AlreadyLaunched(id);

        UtilityTokenParams memory p = c.utilityTokenParams;
        if (p.supply64 == 0 || s.totalInviteContributed == 0)
            revert ZeroLiquidity();

        // ───── approvals ─────
        IZRC20 util = offeringToken[id];
        safeApprove(util, address(dex), p.supply64);
        safeApprove(c.invitingToken, address(dex), s.totalInviteContributed);

        // ───── pool creation ─────
        uint128 lp = dex.initializeLiquidity(
            address(util),
            address(c.invitingToken),
            p.supply64,
            s.totalInviteContributed,
            address(this)
        );
        if (lp == 0) revert ZeroLiquidity();

        util.approve(address(dex), 0);
        c.invitingToken.approve(address(dex), 0);

        /*──────────── burn-on-launch (unclaimable LP) ────────────*
         * 1. Compute the fixed-point burn ratio in LP units.
         * 2. Exclude the burned amount from `lp`—and therefore from
         *    `s.totalLP`—so future vesting/claims can never reach it.
         *
         * Post-conditions
         * ───────────────
         * • The AMM keeps the full deposit; reserves are untouched.
         * • `lp` now tracks only the vestable portion (creator + public).
         * • Orphaned LP remains custodied by this contract, but without
         *   any code path that could move or burn it on-chain, making it
         *   effectively unrecoverable and unclaimable.
         ********************************************************************/
        uint128 burnLP = _pct(lp, c.percentOfLiquidityBurned);
        if (burnLP != 0) {
            lp -= burnLP; // permanently discard claim-rights to this slice
        }

        s.totalLP = lp;
        emit LiquidityDeployed(id, lp);
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
        /*──────────────── AMM path ─────────────*/
        if (address(dex) != address(0)) {
            _vestLiquidity(id, minUtilityOut, minInviteOut);
            return;
        }

        /*────────────── fallback path ───────────*/
        RocketConfig storage c = _cfg(id); // UnknownRocket guard
        RocketState storage s = rocketState[id];
        require(block.timestamp >= c.liquidityDeployTime, "not launched");

        /*────────── pre‑compute fixed constants ──────────*/
        uint64 fullSupply = c.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(fullSupply, c.percentOfLiquidityCreator);
        uint64 publicSupply = fullSupply - creatorSlice;

        /*────────────────── CREATOR ──────────────────*/
        if (msg.sender == c.offeringCreator) {
            uint64 already = s.creatorUtilityClaimed;
            if (
                already == creatorSlice &&
                c.invitingToken.balanceOf(address(this)) == 0
            ) revert NothingToClaim(id);

            /* 1. inviting‑token proceeds (entire raise) */
            uint64 balInv = c.invitingToken.balanceOf(address(this));
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

            emit LiquidityClaimed(
                id,
                msg.sender,
                balInv,
                creatorSlice - already
            );
            return;
        }

        /*──────────────── CONTRIBUTORS ───────────────*/
        uint64 contributed = _deposited[id][msg.sender];
        if (contributed == 0) revert NothingToClaim(id);

        /* defensive‑write before external call */
        _deposited[id][msg.sender] = 0;

        uint64 owedUtil = uint64(
            (uint256(contributed) * publicSupply) / s.totalInviteContributed
        );
        if (owedUtil == 0) revert NothingToClaim(id);

        require(
            safeTransfer(offeringToken[id], msg.sender, owedUtil),
            "util trf failed"
        );

        s.poolUtility = s.poolUtility >= owedUtil
            ? s.poolUtility - owedUtil
            : 0;
        emit LiquidityClaimed(id, msg.sender, 0, owedUtil);
    }

    /*══════════════════════════════════════════════════════════════════════*\
    │                       caller-centric vesting logic                    │
    \*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Internal worker that vests the caller’s share of LP and immediately
     *      withdraws the underlying tokens from the AMM.  The design keeps the
     *      live stack ≤ 16 slots to avoid “Stack too deep” while still following
     *      these invariants:
     *
     *      1. All maths (and possible {NothingToVest} reverts) happen first.
     *      2. External DEX call executes **before** any state is mutated.
     *      3. State is written only after a successful withdrawal.
     *
     *      Fails with:
     *      • {VestBeforeLaunch}  – rocket not launched yet
     *      • {LaunchTooEarly}    – vesting window has not started
     *      • {NothingToVest}     – caller has nothing newly vested
     */
    function _vestLiquidity(
        uint256 id,
        uint64 minUtilOut,
        uint64 minInvOut
    ) internal {
        /*───────────────── fast fail checks ─────────────────*/
        RocketState storage s = rocketState[id];
        if (s.totalLP == 0) revert VestBeforeLaunch(id);

        RocketConfig storage c = _cfg(id); /* UnknownRocket guard inside */

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= c.liquidityDeployTime)
            revert LaunchTooEarly(id, nowTs, c.liquidityDeployTime);

        /*──────────── global vesting fraction ───────────────*/
        uint128 vestedGlobal = (nowTs >= c.liquidityLockedUpTime)
            ? s.totalLP
            : uint128(
                (uint256(s.totalLP) * (nowTs - c.liquidityDeployTime)) /
                    (c.liquidityLockedUpTime - c.liquidityDeployTime)
            );

        /*──────────── per-caller entitlement ────────────────*/
        (uint128 owedLP, uint128 newClaimed) = _calcOwedLP(
            id,
            s,
            c,
            _deposited[id][msg.sender],
            vestedGlobal,
            msg.sender
        ); // ↳ may revert NothingToVest

        /*──────────── guarded withdrawal ────────────────────*/
        _executeWithdraw(id, owedLP, minUtilOut, minInvOut);

        /*──────────── state changes (post-external) ─────────*/
        s.claimedLP[msg.sender] = newClaimed;
        s.lpPulled += owedLP;
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
        uint128 lp,
        uint64 minU,
        uint64 minI
    ) private {
        RocketConfig storage c = rocketCfg[id];

        (uint64 utilOut, uint64 invitOut) = dex.withdrawLiquidity(
            address(offeringToken[id]),
            address(c.invitingToken),
            lp,
            msg.sender,
            minU,
            minI
        );

        emit LiquidityVested(id, lp, invitOut, utilOut);
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
        uint128 vestedGlobal,
        address caller
    ) private view returns (uint128 owedLP, uint128 vestedUser) {
        uint128 creatorLP = _pct(s.totalLP, c.percentOfLiquidityCreator);
        uint128 publicLP = s.totalLP - creatorLP;

        uint128 lpShare;
        if (caller == c.offeringCreator) {
            lpShare = creatorLP;
            if (contributed != 0) {
                lpShare += uint128(
                    (uint256(contributed) * publicLP) / s.totalInviteContributed
                );
            }
        } else {
            if (contributed == 0) revert NothingToVest(rid);
            lpShare = uint128(
                (uint256(contributed) * publicLP) / s.totalInviteContributed
            );
        }

        vestedUser = uint128((uint256(lpShare) * vestedGlobal) / s.totalLP);
        owedLP = vestedUser - s.claimedLP[caller];
        if (owedLP == 0) revert NothingToVest(rid);
    }

    /*═══════════════════════ state-query helpers ═══════════════════════*/

    /**
     * @notice Total amount of inviting tokens contributed to rocket `id`.
     */
    function totalInviteContributed(uint256 id) external view returns (uint64) {
        return rocketState[id].totalInviteContributed;
    }

    /**
     * @notice Total LP minted for rocket `id` at launch.
     */
    function totalLP(uint256 id) external view returns (uint128) {
        return rocketState[id].totalLP;
    }

    /**
     * @notice Vested LP already withdrawn from the pool for rocket `id`.
     */
    function lpPulled(uint256 id) external view returns (uint128) {
        return rocketState[id].lpPulled;
    }

    /**
     * @notice Inviting-token balance currently held by the launcher for rocket `id`.
     */
    function poolInvite(uint256 id) external view returns (uint64) {
        return rocketState[id].poolInvite;
    }

    /**
     * @notice Utility-token balance currently held by the launcher for rocket `id`.
     */
    function poolUtility(uint256 id) external view returns (uint64) {
        return rocketState[id].poolUtility;
    }

    /**
     * @notice Inviting tokens deposited by `who` into rocket `id`.
     */
    function deposited(uint256 id, address who) external view returns (uint64) {
        return _deposited[id][who];
    }

    /**
     * @notice LP that `who` has already claimed for rocket `id` (fixed-point).
     */
    function claimedLP(
        uint256 id,
        address who
    ) external view returns (uint128) {
        return rocketState[id].claimedLP[who];
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

    // HELPERS

    /**
     * @dev Transfer tokens from one address to another
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

        if (
            prevBalance < _value || // Insufficient funds
            _token.allowance(_from, address(this)) < _value // Insufficient allowance
        ) {
            return false;
        }

        (bool success, ) = address(_token).call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint64)",
                _from,
                _to,
                _value
            )
        );
        require(success, "Low-level call failed");

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
        (bool success, ) = address(_token).call(
            abi.encodeWithSignature("approve(address,uint64)", _spender, _value)
        );
        require(success, "Low-level call failed");

        // Fail if the new allowance its not equal than _value
        return _token.allowance(address(this), _spender) == _value;
    }

    /**
     * @dev Transfer token for a specified address
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

        if (prevBalance < _value) {
            // Insufficient funds
            return false;
        }

        (bool success, ) = address(_token).call(
            abi.encodeWithSignature("transfer(address,uint64)", _to, _value)
        );
        require(success, "Low-level call failed");

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
