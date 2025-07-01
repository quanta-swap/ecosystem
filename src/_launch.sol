// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*============================================================================*\
│ ░ R O C K E T ░  L A U N C H E R                                             │
│                                                                              │
│ A one-shot “liquidity rocket” that pairs a creator-supplied *output* token   │
│ with participant-supplied *input* tokens, then adds the pair to an external  │
│ AMM (`IDEX`).  After an optional lock-up (`flightTime`) the position is      │
│ unwound and proceeds are paid back to each participant pro-rata.             │
│                                                                              │
│ — No cancellation once created (prevents grief-style blue-balling).          │
│ — Per-rocket entry isolation blocks cross-claim theft.                       │
│ — Re-entrancy guard + CEI pattern on all state-mutating paths.               │
│ — 256-bit intermediate math avoids overflow during share calculation.        │
\*============================================================================*/

import "./IDEX.sol";
import "./IZRC20.sol";

/*─────────────────────────────  Re-entrancy guard  ──────────────────────────*/
abstract contract ReentrancyGuard {
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;
    uint8 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "re-enter");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/*───────────────────────────────  Main contract  ────────────────────────────*/
contract RocketLauncher is ReentrancyGuard {
    /*═══════════════════════  E V E N T   L O G S  ═════════════════════════*/
    /** Emitted once a new rocket has been created and funded with `output`. */
    event RocketCreated(
        uint64 indexed rocketId,
        address indexed creator,
        IZRC20 indexed input,
        IZRC20 output,
        uint64 outputAmount,
        uint64 launchTime,
        uint64 flightTime
    );

    /** Emitted when a participant embarks by depositing `input` tokens. */
    event RocketEmbarked(
        uint64 indexed rocketId,
        uint64 indexed entryId,
        address indexed participant,
        uint64 inputAmount
    );

    /** Emitted when participant claims and receives their liquidity share. */
    event RocketClaimed(
        uint64 indexed rocketId,
        uint64 indexed entryId,
        address indexed participant,
        uint128 shares,
        uint64 amountA,
        uint64 amountB
    );

    /*═════════════════════  D A T A   S T R U C T U R E S  ═════════════════*/
    struct Rocket {
        address controller; // address allowed to invoke `launchRocket`
        IZRC20 input; // token participants deposit
        IZRC20 output; // token creator pre-funds
        IDEX exchange; // external AMM for liquidity
        uint64 outputAmount; // creator-supplied output
        uint64 inputAmount; // cumulative participant input
        uint64 launchTime; // unix timestamp when launch becomes valid
        uint64 flightTime; // seconds liquidity stays locked post-launch
        bool launched; // true once LP minted
        uint128 remainingShares; // LP tokens still held by contract
        uint128 maximumShares; // total LP minted at launch
        uint64 leftARemaining;
        uint64 leftBRemaining;
    }

    struct RocketEntry {
        address participant; // owner of this entry
        uint64 amount; // `input` deposited
        bool claimed; // true once payout completed
    }

    /*═══════════════════════  P E R S I S T E N C E  ══════════════════════*/
    Rocket[] private rockets; // all rockets
    mapping(uint64 => RocketEntry[]) private rocketEntries; // rocketId ⇒ entries

    /*═════════════════════  C O N S T R U C T I O N  ═════════════════════*/
    /**
     * @notice Create a new rocket and lock the creator’s `outputAmount`.
     * @dev    No cancellation pathway is provided—launch is inevitable or
     *         funds remain forever.  This prevents griefing via last-second
     *         aborts once participants commit capital.
     */
    function createRocket(
        address controller,
        IZRC20 input,
        IZRC20 output,
        IDEX exchange,
        uint64 outputAmount, // requested, not yet trusted
        uint64 launchTime,
        uint64 flightTime
    ) external nonReentrant returns (uint64 rocketId) {
        // ────── basic sanity checks ──────
        require(address(input) != address(0), "input=0");
        require(address(output) != address(0), "output=0");
        require(outputAmount > 0, "output=0");
        require(launchTime > block.timestamp, "launch<now");

        // ────── pull creator funds & measure actual receipt ──────
        uint256 balBefore = output.balanceOf(address(this));
        require(
            output.transferFrom(msg.sender, address(this), outputAmount),
            "output xfer fail"
        );
        uint256 balAfter = output.balanceOf(address(this));
        uint64 received = _toUint64(balAfter - balBefore);
        require(received > 0, "deflationary burn");

        // ────── persist rocket (uses *received* not requested) ──────
        rocketId = uint64(rockets.length);
        rockets.push(
            Rocket({
                controller: controller,
                input: input,
                output: output,
                exchange: exchange,
                outputAmount: received,
                inputAmount: 0,
                launchTime: launchTime,
                flightTime: flightTime,
                launched: false,
                remainingShares: 0,
                maximumShares: 0,
                leftARemaining: 0,
                leftBRemaining: 0
            })
        );

        emit RocketCreated(
            rocketId,
            msg.sender,
            input,
            output,
            received,
            launchTime,
            flightTime
        );
    }

    /*═══════════════════  P A R T I C I P A N T   D E P O S I T  ══════════*/
    /**
     * @notice Deposit `inputAmount` of the rocket’s input token.
     * @return entryId  index within this rocket’s entry list.
     */
    function embarkRocket(
        uint64 rocketId,
        uint64 inputAmount // requested, not yet trusted
    ) external nonReentrant returns (uint64 entryId) {
        // ────── basic guards ──────
        require(inputAmount > 0, "amount=0");
        require(rocketId < rockets.length, "rocket OOB");
        Rocket storage R = rockets[rocketId];
        require(block.timestamp < R.launchTime, "launched");

        // ────── pull participant funds & measure actual receipt ──────
        uint256 balBefore = R.input.balanceOf(address(this));
        require(
            R.input.transferFrom(msg.sender, address(this), inputAmount),
            "input xfer fail"
        );
        uint256 balAfter = R.input.balanceOf(address(this));
        uint64 received = _toUint64(balAfter - balBefore); // handles burns
        require(received > 0, "deflationary burn");

        // ────── update cumulative input with overflow protection ──────
        uint64 newTotal = R.inputAmount + received;
        require(newTotal >= R.inputAmount, "u64 overflow");
        R.inputAmount = newTotal;

        // ────── persist entry ──────
        entryId = uint64(rocketEntries[rocketId].length);
        rocketEntries[rocketId].push(
            RocketEntry({
                participant: msg.sender,
                amount: received,
                claimed: false
            })
        );

        emit RocketEmbarked(rocketId, entryId, msg.sender, received);
    }

    /*═════════════════════  L A U N C H   P H A S E  ═════════════════════*/
    /**
     * @notice Add the pooled tokens to the external AMM once `launchTime` passes.
     *
     * Intent
     * ──────
     * 1. Approve exact spend, mint LP, and zero-out allowances in a single call
     *    (CEI pattern) to minimise external attack surface.
     * 2. Handle USDT-style “must-clear-to-zero” tokens via `_safeApprove`.
     * 3. If a non-zero `controller` was set, give it a 24 h exclusive window.
     *    After that anyone can trigger the launch so funds can’t be bricked.
     *
     * Assumptions
     * ───────────
     * • All tokens in this universe fit into 64-bit denominations, but approvals
     *   and the IDEX interface accept full `uint256`.
     * • `IDEX.addLiquidity` returns *exactly* the amounts consumed or reverts.
     */
    function launchRocket(uint64 rocketId) external nonReentrant {
        require(rocketId < rockets.length, "rocket OOB");
        Rocket storage R = rockets[rocketId];

        /*── timing & one-time guards ─*/
        require(block.timestamp >= R.launchTime, "too early");
        require(!R.launched, "launched already");
        require(R.inputAmount > 0, "no deposits");

        /*── controller grace window ─*/
        if (R.controller != address(0) && msg.sender != R.controller) {
            require(
                block.timestamp >= R.launchTime + 1 days,
                "controller grace"
            );
        }

        /*── single reset-then-set allowances ─*/
        _safeApprove(R.input, address(R.exchange), R.inputAmount);
        _safeApprove(R.output, address(R.exchange), R.outputAmount);

        /*── mint LP (AMM returns *actual* consumed amounts) ─*/
        (uint64 aIn, uint64 bIn, uint128 shares) = R.exchange.addLiquidity(
            R.input,
            R.output,
            R.inputAmount,
            R.outputAmount
        );

        // Expect the exchange liquidity to be empty before our addition.
        require(aIn <= R.inputAmount && bIn <= R.outputAmount, "slip");

        /*── immediately zero allowances (one SSTORE each) ─*/
        // Direct approve is cheaper than calling _safeApprove again.
        require(R.input.approve(address(R.exchange), 0), "clr A");
        require(R.output.approve(address(R.exchange), 0), "clr B");

        uint64 leftA = R.inputAmount - aIn;
        uint64 leftB = R.outputAmount - bIn;

        /*── finalise state ─*/
        R.launched = true;
        R.maximumShares = shares;
        R.remainingShares = shares;
        R.leftARemaining = leftA;
        R.leftBRemaining = leftB;
    }

    /*════════════════════   P O S T-F L I G H T   C L A I M   ═════════════*/

    /**
     * @notice Claim this entry’s share of the LP position **plus** its slice of
     *         any tokens that failed to enter the pool at launch (“left-overs”).
     *
     * ───────────────────────────── Intent ─────────────────────────────
     * • Guarantee **order-independent** payouts: the math must not care who
     *   claims first or last.
     * • Mop up every last wei:
     *     – The *last* claimer receives any residual LP rounding dust.
     *     – The *last* claimer receives any residual left-over tokens.
     * • Follow strict CEI + re-entrancy guard discipline.
     *
     * ──────────────────────────── Assumptions ─────────────────────────
     * • All IZRC20 balances fit in 64 bits (token-universe invariant).
     * • `IDEX.removeLiquidity()` returns the amount of A and B backing exactly
     *   `shares` LP tokens or reverts.
     * • Function executes under `nonReentrant`.
     */
    function claimLiquidity(
        uint64 rocketId,
        uint64 entryId
    ) external nonReentrant {
        /*──────────── 0. Basic guards ──────────────────────────────────*/
        require(rocketId < rockets.length, "rocket OOB");
        Rocket storage R = rockets[rocketId];
        require(R.launched, "not launched");
        require(block.timestamp >= R.launchTime + R.flightTime, "locked");
        require(entryId < rocketEntries[rocketId].length, "entry OOB");
        RocketEntry storage E = rocketEntries[rocketId][entryId];
        require(E.participant == msg.sender, "not owner");
        require(!E.claimed, "claimed");

        /*──────────── 1. Detect “last-claimer” upfront ─────────────────*/
        // If the caller’s deposit equals the current divisor, every other
        // entry must already be claimed, so this caller is last.
        bool isLast = (R.inputAmount == E.amount);

        /*──────────── 2. Compute LP share (256-bit intermediate) ───────*/
        uint256 shares256 = (uint256(E.amount) * uint256(R.maximumShares)) /
                            uint256(R.inputAmount);
        uint128 shares = uint128(shares256);               // safe down-cast

        // Rounding guard: cap overshoot (should only matter for first claimer
        // when everyone deposited the same tiny amount).
        if (shares > R.remainingShares) shares = R.remainingShares;

        /*──────────── 3. Starved deposit (0 shares) branch ─────────────*/
        if (shares == 0) {
            E.claimed = true;
            R.inputAmount -= E.amount;                     // shrink divisor
            require(R.input.transfer(msg.sender, E.amount), "refund");
            emit RocketClaimed(rocketId, entryId, msg.sender, 0, E.amount, 0);
            return;
        }

        /*──────────── 4. Left-over slice calculation ───────────────────*/
        uint64 owedA;
        uint64 owedB;

        if (isLast) {
            // Sweep whatever dust is left — guarantees no stranded tokens.
            owedA = R.leftARemaining;
            owedB = R.leftBRemaining;
            R.leftARemaining = 0;
            R.leftBRemaining = 0;
            shares = R.remainingShares;                    // grab all LP dust
        } else {
            // Standard proportional slice.
            if (R.leftARemaining > 0) {
                owedA = _toUint64(
                    (uint256(R.leftARemaining) * uint256(E.amount)) /
                    uint256(R.inputAmount)
                );
                R.leftARemaining -= owedA;
            }
            if (R.leftBRemaining > 0) {
                owedB = _toUint64(
                    (uint256(R.leftBRemaining) * uint256(E.amount)) /
                    uint256(R.inputAmount)
                );
                R.leftBRemaining -= owedB;
            }
        }

        /*──────────── 5. State updates (all before externals) ──────────*/
        E.claimed        = true;
        R.remainingShares -= shares;
        R.inputAmount    -= E.amount;                      // divisor shrinks

        /*──────────── 6. Unwind LP and pay caller ──────────────────────*/
        (uint64 amtA, uint64 amtB) = R.exchange.removeLiquidity(
            R.input, R.output, shares
        );

        uint64 payA = amtA + owedA;
        uint64 payB = amtB + owedB;

        require(R.input.transfer(msg.sender, payA), "xfer A");
        require(R.output.transfer(msg.sender, payB), "xfer B");

        emit RocketClaimed(rocketId, entryId, msg.sender, shares, payA, payB);
    }

    /*═══════════════════════  R E A D - O N L Y  ═════════════════════════*/
    /// Return total number of rockets ever created (gaps stay zero-initialised).
    function getRocketCount() external view returns (uint64) {
        return uint64(rockets.length);
    }

    /// Return full `Rocket` struct (deleted slots are zero-filled).
    function getRocket(uint64 rocketId) external view returns (Rocket memory) {
        require(rocketId < rockets.length, "rocket OOB");
        return rockets[rocketId];
    }

    /// Return number of participant entries for `rocketId`.
    function getEntryCount(uint64 rocketId) external view returns (uint64) {
        require(rocketId < rockets.length, "rocket OOB");
        return uint64(rocketEntries[rocketId].length);
    }

    /// Return a given entry (rocket + entryId pair).
    function getEntry(
        uint64 rocketId,
        uint64 entryId
    ) external view returns (RocketEntry memory) {
        require(rocketId < rockets.length, "rocket OOB");
        require(entryId < rocketEntries[rocketId].length, "entry OOB");
        return rocketEntries[rocketId][entryId];
    }

    // Helpers

    /**
     * @dev Approve `spender` for `amount`, honouring tokens that demand a
     *      zero-allowance reset (e.g. USDT).
     *
     * Intent
     * ──────
     * • Works uniformly for both permissive and strict ERC-20s.
     * • Saves gas by skipping the reset step when allowance is already zero.
     *
     * Assumptions
     * ───────────
     * • `token.allowance()` exists in the IZRC20 interface and follows ERC-20
     *   semantics.
     * • Caller executes inside a `nonReentrant` context.
     */
    function _safeApprove(
        IZRC20 token,
        address spender,
        uint64 amount
    ) private {
        uint256 current = token.allowance(address(this), spender);
        if (current == amount) return; // already perfect

        if (current != 0) {
            // reset if required
            require(token.approve(spender, 0), "approve-reset");
        }
        if (amount != 0) {
            // set target
            require(token.approve(spender, amount), "approve-set");
        }
    }

    /**
     * @dev Safely cast a `uint256` down to `uint64`, reverting on overflow.
     *
     * Intent
     * ──────
     * • Centralises the overflow check used throughout the contract.
     * • Keeps the main functions readable while guaranteeing 64-bit discipline.
     *
     * Assumptions
     * ───────────
     * • All IZRC20 tokens fit into 64-bit balances (token-universe invariant).
     */
    function _toUint64(uint256 value) private pure returns (uint64) {
        require(value <= type(uint64).max, "u64 overflow");
        return uint64(value);
    }
}
