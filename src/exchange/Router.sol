// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────── external deps ────────*/
import "../IZRC20.sol";
import "./Pool.sol"; // IPoolMinimal
import "../_utility.sol"; // StandardUtilityToken (8-dec coupon)

/*──────── custom errors ────────*/
error UnauthorizedTrader(address provider, address caller);
error InvalidReferralBasis(uint32 bps);
error CouponTooLarge(uint64 locked);
error MasterZeroAddress();
error ERC20TransferFailed(address token);
error RefundFailed();

/*──────── pool io spec ────────*/
interface IPoolMinimal {
    function getPair() external view returns (IZRC20 base, IZRC20 quote);

    function swap(
        bool baseForQuote,
        bool exactInput,
        uint64 amount,
        uint64 limit,
        uint64[] calldata orders
    )
        external
        returns (
            uint64 inBase,
            uint64 inQuote,
            uint64 outBase,
            uint64 outQuote
        );
}

/*──────── public router api ─────*/
interface IRouter {
    struct ExecutableAtom {
        bool baseForQuote;
        bool exactInput;
        uint64 amount;
        uint64 limit;
        address provider;
        address recipient;
        uint64[] orders;
    }
    struct Executable {
        IPoolMinimal pool;
        ExecutableAtom[] atoms;
    }

    function execute(
        uint64 couponLocked, // ≤ 1 e8 (8-dec)
        uint32 avoidableBps, // 0-10 000
        address referral,
        Executable[] calldata swaps,
        bool atomic // all-or-nothing
    ) external returns (uint64 totalOut);

    function approveTrader(address trader, bool ok) external;
}

/*════════ scalar-fee router (fault-tolerant) ════════*/
contract ScalarFeeRouter is IRouter {
    /*──── constants ───*/
    uint32 public constant PROTOCOL_FEE_BPS = 30; // 0.30 %
    uint64 public constant COUPON_UNIT = 1e8; // 1 coupon token
    uint32 public constant MASTER_SHARE_BPS = 2_500; // 25 %

    StandardUtilityToken public immutable coupon;
    address public immutable master;

    /*──── delegation ──*/
    mapping(address => mapping(address => bool)) public isTraderApproved;
    function approveTrader(address t, bool ok) external override {
        isTraderApproved[msg.sender][t] = ok;
    }

    constructor(StandardUtilityToken coupon_, address master_) {
        if (master_ == address(0)) revert MasterZeroAddress();
        coupon = coupon_;
        master = master_;
    }

    /*════════ batch entrypoint ════════*/
    function execute(
        uint64 couponLocked,
        uint32 avoidableBps,
        address referral,
        Executable[] calldata swaps,
        bool atomic
    ) external override returns (uint64 totalOut) {
        if (avoidableBps > 10_000) revert InvalidReferralBasis(avoidableBps);
        if (couponLocked > COUPON_UNIT) revert CouponTooLarge(couponLocked);

        if (couponLocked != 0) coupon.lock(msg.sender, couponLocked);
        uint128 scalar = COUPON_UNIT - couponLocked; // fee discount factor

        /* loop pools / atoms */
        for (uint256 p; p < swaps.length; ++p) {
            (IZRC20 base, IZRC20 quote) = swaps[p].pool.getPair();

            for (uint256 a; a < swaps[p].atoms.length; ++a) {
                bytes memory callData = abi.encodeWithSelector(
                    this._atom.selector,
                    swaps[p].atoms[a],
                    swaps[p].pool,
                    base,
                    quote,
                    scalar,
                    avoidableBps,
                    referral
                );

                (bool ok, bytes memory ret) = address(this).call(callData);

                if (ok) {
                    totalOut += abi.decode(ret, (uint64));
                } else if (atomic) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    } // bubble
                }
                /* else: non-atomic → skip bad atom */
            }
        }
    }

    /*══════════════ helpers ══════════════*/

    /**
     * @notice Compute the protocol fee owed after applying any coupon discount.
     * @dev The fee is   amount ⋅ PROTOCOL_FEE_BPS ⋅ scalar / 10 000 / 1e8.
     *      `scalar` is `COUPON_UNIT − couponLocked`, so 1 e8 means “no discount”.
     * @param amount   Gross amount the fee is based on (see `_atom` for context).
     * @param scalar   Discount scalar in the range 0 … 1e8.
     * @return feeDue  Discount-adjusted protocol fee (64-bit universe).
     */
    function _fee(
        uint64 amount,
        uint128 scalar
    ) private pure returns (uint64 feeDue) {
        unchecked {
            feeDue = uint64(
                (uint256(amount) * PROTOCOL_FEE_BPS * scalar) / 10_000 / 1e8
            );
        }
    }

    /*════════ per-atom execution (self-call) ════════*/
    /**
     * @notice Perform one swap atomically, charging protocol fees and tips.
     * @param at           Swap parameters provided by the user.
     * @param pool         Pool to execute against.
     * @param base/quote   Pool’s token pair (cached from `getPair()`).
     * @param scalar       Coupon discount scalar (0 … 1e8).
     * @param avoidableBps Referral tip in bp that the trader *may* avoid.
     * @param referral     Address that receives any tip.
     * @return outAmt      Amount of output tokens the recipient actually receives.
     *
     * INTENT & ASSUMPTIONS
     * --------------------
     * • `msg.sender` MUST be the router itself (guarded explicitly).
     * • **Exact-IN:** the provider’s `at.amount` already *includes* fee + tip.
     *   The router “shaves” those charges off internally, and the *net* amount
     *   is forwarded to the pool.
     * • **Exact-OUT:** fee (and optional tip) are *tacked on* **after** we know
     *   how much the pool needs.  The user-supplied `limit` binds the *total*
     *   out-of-pocket cost: *(spent + fee + tip) ≤ limit*.
     * • Every transfer uses `transferFrom`, so providers must approve the *pool*
     *   beforehand (router never needs allowance).
     */
    function _atom(
        ExecutableAtom calldata at,
        IPoolMinimal pool,
        IZRC20 base,
        IZRC20 quote,
        uint128 scalar,
        uint32 avoidableBps,
        address referral
    ) external returns (uint64 outAmt) {
        /*────────── access control ──────────*/
        require(msg.sender == address(this), "only self");
        if (
            tx.origin != at.provider &&
            !isTraderApproved[at.provider][tx.origin]
        ) revert UnauthorizedTrader(at.provider, tx.origin);

        IZRC20 inTok = at.baseForQuote ? base : quote;
        IZRC20 outTok = at.baseForQuote ? quote : base;

        /*────────── fee & tip pre-calculation ──────────*/
        uint64 tip; // avoidable referral payout
        uint64 feeDue; // protocol fee after coupon discount
        uint64 masterCut; // 25 % of `feeDue`
        uint64 poolCut; // remaining 75 % of `feeDue`
        uint64 spent; // net tokens the pool expects
        uint64 grossInput; // total tokens the provider parts with

        if (at.exactInput) {
            /* 1️⃣  exact-IN  – fee/tip shaved *inside* `at.amount` */
            feeDue = _fee(at.amount, scalar);
            tip = avoidableBps == 0 || referral == address(0)
                ? 0
                : uint64((uint256(at.amount) * avoidableBps) / 10_000);

            grossInput = at.amount; // what provider will pay
            spent = grossInput - feeDue - tip; // what the pool will receive

            /* call pool with the *net* input */
            (uint64 inB, uint64 inQ, uint64 outB, uint64 outQ) = pool.swap(
                at.baseForQuote,
                /* exactInput = */ true,
                spent,
                at.limit, // pool enforces min-out internally
                at.orders
            );

            // sanity: pool must echo the net tokens we told it
            require((at.baseForQuote ? inB : inQ) == spent, "pool mismatch");
            outAmt = at.baseForQuote ? outQ : outB;
        } else {
            /* 2️⃣  exact-OUT – fee/tip tacked *on top* of pool cost */
            (uint64 inB, uint64 inQ, uint64 outB, uint64 outQ) = pool.swap(
                at.baseForQuote,
                /* exactInput = */ false,
                at.amount, // desired output
                at.limit, // pool enforces max-in internally
                at.orders
            );

            spent = at.baseForQuote ? inB : inQ; // pool input requirement
            feeDue = _fee(spent, scalar);
            tip = avoidableBps == 0 || referral == address(0)
                ? 0
                : uint64((uint256(spent) * avoidableBps) / 10_000);

            grossInput = spent + feeDue + tip; // provider all-in cost

            // user-supplied limit binds the *total* out-of-pocket tokens
            require(grossInput <= at.limit, "slippage");

            outAmt = at.baseForQuote ? outQ : outB; // equals `at.amount`
        }

        /*────────── fee splitting ──────────*/
        masterCut = uint64((uint256(feeDue) * MASTER_SHARE_BPS) / 10_000);
        poolCut = feeDue - masterCut;

        /*────────── token settlements ───────*/
        _xfer(inTok, at.provider, master, masterCut); // 25 % fee
        _xfer(inTok, at.provider, address(pool), spent + poolCut); // swap + 75 % fee
        if (tip != 0) {
            _xfer(inTok, at.provider, referral, tip); // optional tip
        }

        /*────────── deliver proceeds ────────*/
        _xfer(outTok, address(pool), at.recipient, outAmt);
    }

    /* helper that reverts with ERC20TransferFailed on failure */
    function _xfer(
        IZRC20 tok,
        address from,
        address to,
        uint64 amount
    ) private {
        if (amount == 0) return;
        if (!tok.transferFrom(from, to, amount))
            revert ERC20TransferFailed(address(tok));
    }
}
