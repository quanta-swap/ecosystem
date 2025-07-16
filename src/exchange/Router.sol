// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────── External deps ─────────────────────*/
import "../IZRC20.sol";
import "./Pool.sol"; // IPoolMinimal interface
import "../_utility.sol"; // StandardUtilityToken (8-dec coupon)

/*════════════════════ Custom errors ══════════════════════*/
error UnauthorizedTrader(address provider, address caller);
error InvalidReferralBasis(uint32 bps);
error CouponTooLarge(uint64 locked);
error MasterZeroAddress();
error ERC20TransferFailed(address token);
error ERC20ApproveFailed(address token);
error RefundFailed();

/*════════════════════ Pool interface (uint64 IO) ═════════*/
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

/*════════════════════ Router interface ═══════════════════*/
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
        uint64 couponLocked, // ≤ 1e8 (8 dec)
        uint32 avoidableBps, // 0-10 000
        address referral,
        Executable[] calldata swaps,
        bool atomic // true => all-or-nothing
    ) external returns (uint64 totalOut);

    function approveTrader(address trader, bool ok) external;
}

/*════════════ Scalar-fee router (master split + AA) ══════*/
contract ScalarFeeRouter is IRouter {
    /*──── parameters ────*/
    uint32 public constant PROTOCOL_FEE_BPS = 30; // 0.30 %
    uint64 public constant COUPON_UNIT = 1e8; // 1 coupon token (8 dec)
    uint32 public constant MASTER_SHARE_BPS = 2_500; // 25 %

    StandardUtilityToken public immutable coupon;
    address public immutable master;

    /*──── delegation ────*/
    mapping(address => mapping(address => bool)) public isTraderApproved;
    function approveTrader(address t, bool ok) external override {
        isTraderApproved[msg.sender][t] = ok;
    }

    constructor(StandardUtilityToken coupon_, address master_) {
        if (master_ == address(0)) revert MasterZeroAddress();
        coupon = coupon_;
        master = master_;
    }

    /*══════════════ execute (batch) ══════════════*/
    function execute(
        uint64 couponLocked,
        uint32 avoidableBps,
        address referral,
        Executable[] calldata swaps,
        bool atomic
    ) external override returns (uint64 totalOut) {
        if (avoidableBps > 10_000) revert InvalidReferralBasis(avoidableBps);
        if (couponLocked > COUPON_UNIT) revert CouponTooLarge(couponLocked);

        /* lock coupon once */
        if (couponLocked != 0) coupon.lock(msg.sender, couponLocked);
        uint128 scalar = COUPON_UNIT - couponLocked; // 1e8-scaled discount

        for (uint256 p; p < swaps.length; ++p) {
            IPoolMinimal pool = swaps[p].pool;
            (IZRC20 base, IZRC20 quote) = pool.getPair();

            ExecutableAtom[] calldata atoms = swaps[p].atoms;
            for (uint256 a; a < atoms.length; ++a) {
                /* build calldata for sub-call */
                (bool ok, bytes memory ret) = address(this).call(
                    abi.encodeWithSelector(
                        this._atom.selector,
                        atoms[a],
                        pool,
                        base,
                        quote,
                        scalar,
                        avoidableBps,
                        referral
                    )
                );

                if (ok) {
                    totalOut += abi.decode(ret, (uint64));
                } else if (atomic) {
                    // bubble original revert reason
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                /* non-atomic: simply skip failed atom */
            }
        }
    }

    /*======== isolated atom logic (self-call) ========*/
    function _atom(
        ExecutableAtom calldata at,
        IPoolMinimal pool,
        IZRC20 base,
        IZRC20 quote,
        uint128 scalar, // 0…1e8
        uint32 avoidableBps,
        address referral
    ) external returns (uint64 outAmt) {
        require(msg.sender == address(this), "only-self");

        /* delegation auth */
        if (
            msg.sender != at.provider && // always true (only-self) but keep logic symmetric
            !isTraderApproved[at.provider][tx.origin]
        ) revert UnauthorizedTrader(at.provider, tx.origin);

        IZRC20 inTok = at.baseForQuote ? base : quote;
        IZRC20 outTok = at.baseForQuote ? quote : base;

        /* pull provisional input */
        uint64 pulled = at.exactInput ? at.amount : at.limit;
        if (!inTok.transferFrom(at.provider, address(this), pulled))
            revert ERC20TransferFailed(address(inTok));

        /* protocol fee */
        uint64 protoFee = uint64((uint256(pulled) * PROTOCOL_FEE_BPS) / 10_000);
        uint64 feeDue = uint64((uint256(protoFee) * scalar) / 1e8);
        if (feeDue != 0) {
            uint64 masterCut = uint64(
                (uint256(feeDue) * MASTER_SHARE_BPS) / 10_000
            );
            uint64 poolCut = feeDue - masterCut;

            if (masterCut != 0)
                if (!inTok.transferFrom(at.provider, master, masterCut))
                    revert ERC20TransferFailed(address(inTok));

            if (poolCut != 0)
                if (!inTok.transferFrom(at.provider, address(pool), poolCut))
                    revert ERC20TransferFailed(address(inTok));
        }

        /* avoidable rebate */
        if (avoidableBps != 0 && referral != address(0)) {
            uint64 rebate = uint64((uint256(pulled) * avoidableBps) / 10_000);
            if (rebate != 0)
                if (!inTok.transferFrom(at.provider, referral, rebate))
                    revert ERC20TransferFailed(address(inTok));
        }

        /* approve pool */
        if (!inTok.approve(address(pool), pulled))
            revert ERC20ApproveFailed(address(inTok));

        /* swap */
        (uint64 inB, uint64 inQ, uint64 outB, uint64 outQ) = pool.swap(
            at.baseForQuote,
            at.exactInput,
            at.amount,
            at.limit,
            at.orders
        );

        uint64 spent = at.baseForQuote ? inB : inQ;

        /* refund surplus for exact-out */
        if (!at.exactInput && spent < pulled) {
            uint64 refund = pulled - spent;
            if (!inTok.transfer(at.provider, refund)) revert RefundFailed();
        }

        /* payout */
        outAmt = at.baseForQuote ? outQ : outB;
        if (!outTok.transfer(at.recipient, outAmt))
            revert ERC20TransferFailed(address(outTok));
    }
}
