// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────
│  External interfaces & helpers   │
└──────────────────────────────────*/
import "../_launch.sol"; // pulls in IDEX, IZRC20, custom errors
import "../IZRC20.sol";

/*
interface IZRC20 {

    event Transfer(
        address indexed from,
        address indexed to,
        uint64  value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint64  value
    );


    function name()        external view returns (string memory);
    function symbol()      external view returns (string memory);
    function decimals()    external view returns (uint8); // SHOULD return 8-18

    function totalSupply() external view returns (uint64);
    function balanceOf(address account) external view returns (uint64);
    function allowance(address owner, address spender) external view returns (uint64);

    function transfer(address to, uint64 amount) external returns (bool);
    function transferBatch(
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success);

    function approve(address spender, uint64 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint64 amount
    ) external returns (bool);
    function transferFromBatch(
        address src,
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success);

    function checkSupportsOwner(address who) external view returns (bool);
    function checkSupportsMover(address who) external view returns (bool);
    
}
*/

library EssentialHelpers {
    /**
     * @notice Split a trade fee into three pieces:
     *         • `pro` – protocol’s share of the *discounted* fee
     *         • `liq` – liquidity‑provider share of the *discounted* fee
     *         • `tip` – referral reward, calculated as a *separate* fee with
     *                    the same inside/outside semantics **but no discount**
     *
     * Q.32 mathematics (100 % = 2³²‑1)
     * ───────────────────────────────
     *                 ┌ amount × rate / 2³²                         (outside)
     *   rawFee  =     │
     *                 └ amount × rate / (2³² + rate)                (inside)
     *
     *   discountedFee = rawFee × (1 − discount) / 2³²
     *   pro           = discountedFee × protocol / 2³²
     *   liq           = discountedFee − pro
     *
     *   rawTip  = same formula as rawFee but with `referral` rate (no discount)
     *
     * All intermediates use `uint256` to avoid overflow.  Returned values are
     * capped to the 64‑bit token‑balance domain.
     *
     * @param outside  true → fee added on top, false → fee included in `amount`
     * @param amount   Base amount in token units (Q.32 scaled)
     * @param charged  Gross fee rate
     * @param discount Discount applied to the gross fee
     * @param protocol Protocol share of the *discounted* fee
     * @param referral Referral rate (applied with the same inside/outside rule,
     *                 but **not** discounted)
     *
     * @return pro  Protocol slice (64‑bit)
     * @return liq  Liquidity‑provider slice (64‑bit)
     * @return tip  Referral reward (64‑bit)
     */
    function excise(
        bool outside,
        uint64 amount,
        uint32 charged,
        uint32 discount,
        uint32 protocol,
        uint32 referral
    ) internal pure returns (uint64 pro, uint64 liq, uint64 tip) {
        unchecked {
            /*───────────────────── 1. raw fee ─────────────────────*/
            uint256 raw = outside
                ? (uint256(amount) * charged) >> 32
                : (uint256(amount) * charged) / ((uint256(1) << 32) + charged);

            /*───────────────────── 2. discount ───────────────────*/
            uint256 disc = (raw * (type(uint32).max - discount)) >> 32;

            /*───────────────────── 3. protocol cut ───────────────*/
            pro = uint64((disc * protocol) >> 32);

            /*───────────────────── 4. liquidity share ────────────*/
            liq = uint64(disc - pro); // remainder to LPs

            /*───────────────────── 5. referral tip ───────────────*/
            uint256 rawTip = outside
                ? (uint256(amount) * referral) >> 32
                : (uint256(amount) * referral) /
                    ((uint256(1) << 32) + referral);
            tip = uint64(rawTip);
        }
    }

    /**
     * @notice Compute a Q.32 discount factor from a supplied balance of a
     *         governance / fee‑rebate token.
     *
     * Design
     * ──────
     * • The discount ramps **linearly** from 0 % to 100 % over the range
     *    `[0, unit]`, where `unit = 10^decimals`.
     * • Contributing *more* than one full unit is disallowed; callers should
     *   clamp their `amount` upstream or split the call.
     *
     * Mathematics
     * ───────────
     * ```
     *   discountQ32 = (amount / unit)  in Q.32  →  (amount << 32) / unit
     * ```
     * — `amount == 0`    → `discount == 0`
     * — `amount == unit` → `discount == 2^32 − 1` (full rebate)
     *
     * @param token   Fee‑rebate token (decimals define what “one unit” means).
     * @param amount  Caller‑supplied balance to qualify for a discount (≤ unit).
     *
     * @return d      Discount factor in Q.32 (0 = no discount, 2^32‑1 = full).
     */
    function discount32(
        IZRC20 token,
        uint64 amount
    ) internal view returns (uint32 d) {
        /* 1. Derive the scaling unit (10^decimals). */
        uint64 unit = uint64(10 ** token.decimals());

        /* 2. Reject over‑funded amounts — avoids unbounded scaling exploits. */
        require(amount <= unit, "too big for discount");

        /* 3. Linear interpolation into Q.32 space. */
        unchecked {
            // (amount << 32) / unit  — fits in 256‑bit throughout
            d = uint32((uint256(amount) << 32) / unit);
        }
    }

    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    uint24 internal constant MAX_TICK = 887272;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(MAX_TICK), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0)
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0)
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0)
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0)
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0)
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0)
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0)
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0)
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0)
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0)
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0)
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0)
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0)
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0)
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0)
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0)
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0)
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0)
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0)
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = uint160(
            (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
        );
    }

    // Custom revert for the extremely‐rare case that the full‑price
    // overflows the Q64.64 (128‑bit) domain.
    error PriceOverflow(uint256 rawPrice);

    /**
     * @notice Convert a √price in Q64.96 (as produced by Uniswap‑style
     *         pricing functions) into a *full* price in Q64.64.
     *
     *         fullPriceQ64_64 = (sqrtPriceX96)^2 / 2¹²⁸
     *
     *         • Works for the entire Uniswap v3 tick range (±887 272).
     *         • Uses a 512‑bit multiplication in assembly to avoid the
     *           intermediate overflow that would occur in 256‑bit math.
     *         • Reverts with {PriceOverflow} if the result does not fit
     *           into 128 bits (should never happen inside the valid tick
     *           range, but is checked defensively).
     *
     * @param sqrtPriceX96  √(token1/token0) scaled by 2⁹⁶ (Q64.96).
     * @return priceQ64_64  Full price (token1/token0) scaled by 2⁶⁴
     *                      (Q64.64, 64‑bit integer ‑ 64‑bit fraction).
     */
    function priceFromSqrt(
        uint160 sqrtPriceX96
    ) internal pure returns (uint128 priceQ64_64) {
        /*──────────────────────── step 0 ────────────────────────*
         * Promote to 256‑bit so the compiler lets us touch it in *
         * assembly without additional casts on every access.     */
        uint256 x = sqrtPriceX96; // ← local copy in 256‑bit domain

        /*──────────────────────── step 1 ────────────────────────*
         * 512‑bit multiplication (hi, lo) = x * x using the same *
         * trick as Uniswap’s FullMath:                           *
         *   mm  = mulmod(x, x, 2²⁵⁶‑1)  → (x * x) mod 2²⁵⁶       *
         *   lo  = mul(x, x)              → low 256 bits          *
         *   hi  = mm − lo − carry        → high 256 bits         */
        uint256 hi;
        uint256 lo;
        unchecked {
            assembly {
                let mm := mulmod(x, x, not(0)) // 512‑bit mod‑product
                lo := mul(x, x) // low half
                hi := sub(sub(mm, lo), lt(mm, lo)) // high half
            }
        }

        /*──────────────────────── step 2 ────────────────────────*
         * Divide the 512‑bit product by 2¹²⁸ (i.e. shift right   *
         * 128 bits) to obtain a 384‑bit intermediate.            *
         *                                                        *
         *   shifted = (hi << 128) | (lo >> 128)                  *
         */
        uint256 shifted = (hi << 128) | (lo >> 128);

        /*──────────────────────── step 3 ────────────────────────*
         * Bound check – price must fit in a uint128 to be valid  *
         * Q64.64.  A revert here would indicate either corrupt   *
         * input or an upstream tick outside the allowed range.   */
        if (shifted > type(uint128).max) revert PriceOverflow(shifted);

        /*──────────────────────── step 4 ────────────────────────*
         * Return the result – now safely cast down to 128 bits.  */
        priceQ64_64 = uint128(shifted);
    }

    function priceFromTick(int24 tick) internal pure returns (uint128) {
        return priceFromSqrt(getSqrtRatioAtTick(tick));
    }
}

/**
 * PQSE: The Post-Quantum Securities Exchange
 *
 * This is primarily a limit ordered securities exchange, with support for
 * conventional tokens and Uniswap V2-style liquidity pools. It has been
 * designed in light of the focus on limit orders, such as including the
 * FREE token, which discounts the trading fee up to 100% exclusive of a
 * referral fee specified by the transaction preparer. Liquidity yield is
 * not the focus of this exchange; it is here as a functional necessity.
 *
 * This exchange has a multiple-in-flight trading model, but can be used
 * by single traders. It is not a DEX aggregator. The fee is levied on
 * the reserve currency, since the protocol operator may not have the
 * right to own or custody the secured currency.
 *
 * There are a few arbitrary but essential rules/opinions enforced by PQSE:
 * - Limit orders are in-force for at least 10 minutes, to ensure stability.
 */

contract PQSE {
    using IZRC20Helper for address;

    address public immutable owner;

    function halt() external payable {
        revert("https://www.youtube.com/watch?v=fVIh1MFWDV");
    }

    struct Pair {
        IZRC20 reserve;
        IZRC20 secured;
    }

    struct Resource {
        address owner;
        uint64 amount;
    }

    struct Cross {
        Pair pair;
        Resource[] reserveInputs;
        uint64[] reserveOrders;
        Resource[] securedInputs;
        uint64[] securedOrders;
        uint24 minStrikePrice;
        uint24 maxStrikePrice;
    }

    struct Order {
        uint64 reserveAmount;
        uint64 securedAmount;
        int24 reserveToSecuredTick; // < securedToReserveTick
        int24 securedToReserveTick; // > reserveToSecuredTick
        uint64 expiryTime; // 0 = never expires
        bytes2 extraData; // for... communication? compliance?
    }

    struct Pool {
        uint64 reserve;
        uint64 secured;
        uint128 shares;
        mapping(uint64 => Order) orders;
        mapping(uint64 => address) owners;
    }

    // BASIC ORDERED OPERATIONS POINTER
    uint64 public boop = 0; // global nonce for everything

    IZRC20 public immutable FREE; // fee discount token

    uint32 public constant MAX_FEE = 6442450; // 0.30%
    uint32 public constant PRO_FEE = 536870911; // 25%
    uint32 public constant MIN_TIF = 10 minutes;
    uint32 public constant MIN_LIQ = 1_000;

    mapping(IZRC20 => mapping(IZRC20 => Pool)) public pools; // reserve => secured => Pool
    mapping(address => mapping(address => uint64)) public broke; // owner => broker => approved
    mapping(address => uint64) public profit; // reserved fees collected for protocol

    // "Two nukes."
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=ekM0VflXyok";
    }

    function approve(address broker, uint64 expires) external {
        require(broker != address(0), "zero broker");
        require(
            expires == 0 || expires >= block.timestamp + MIN_TIF,
            "invalid expiry"
        );
        broke[msg.sender][broker] = expires;
    }

    /**
     * @dev Best‑effort probe that a token meets **all** QuantaSwap requirements:
     *      1. 64‑bit supply (`isIZRC20()` totalSupply check).
     *      2. Token authorises this DEX as “mover”.
     *      3. Token authorises this DEX as “owner”.
     *
     *      Returns `true` on full success, `false` on *any* failure.
     *      Never reverts—call‑site stays pure/view‑only.
     *
     * @param token  Address to validate.
     */
    function _isSupported(address token) internal view returns (bool) {
        // Basic sanity: zero address = outright reject
        if (token == address(0)) return false;

        // 1. 64‑bit supply guarantee
        if (!token.isIZRC20()) return false;

        // 2 + 3. Permission checks
        IZRC20 t = IZRC20(token);
        if (!t.checkSupportsMover(address(this))) return false;
        if (!t.checkSupportsOwner(address(this))) return false;

        return true;
    }

    /*═══════════════════════════════════════════════════════════════════*/
    /**
     * @notice Return `true` iff **both** tokens pass {_isSupported}.
     *
     * @dev Pure view utility; never reverts.
     */
    function checkSupportsPair(
        address reserve,
        address secured
    ) external view returns (bool) {
        // Early reject: identical or zero addresses make no sense.
        if (
            reserve == address(0) || secured == address(0) || reserve == secured
        ) {
            return false;
        }

        // EXTREMELY IMPORTANT!
        if (!IZRC20(reserve).checkSupportsOwner(owner)) return false;

        return _isSupported(reserve) && _isSupported(secured);
    }

    struct CrucifyResult {
        uint64 reserveIn;
        Resource[] reserveRes;
        uint64 reserveLen;
        uint64 securedIn;
        Resource[] securedRes;
        uint64 securedLen;
    }

    /* does not revert */
    function crucify(
        Cross memory cross
    ) internal returns (CrucifyResult memory result) {
        result.reserveRes = new Resource[](cross.reserveInputs.length);
        // filter out reserve inputs where the broker is not approved, put them in new array
        // filter out reserve inputs that are zero amount, put them in new array
        for (uint i = 0; i < cross.reserveInputs.length; i++) {
            Resource memory r = cross.reserveInputs[i];
            if (r.amount == 0) continue;
            if (r.owner != msg.sender) {
                uint64 exp = broke[r.owner][msg.sender];
                if (exp == 0 || exp < block.timestamp) continue;
            }
            // transfer the funds into the contract here
            IZRC20 res = cross.pair.reserve;
            if (res.balanceOf(r.owner) < r.amount) continue;
            IZRC20 sec = cross.pair.secured;
            if (!sec.checkSupportsOwner(r.owner)) continue; // CRITICAL!
            try res.transferFrom(r.owner, address(this), r.amount) returns (
                bool ok
            ) {
                if (!ok) continue;
            } catch {
                continue;
            }
            result.reserveIn += r.amount;
            result.reserveRes[i] = r;
            result.reserveLen++;
        }

        result.securedRes = new Resource[](cross.securedInputs.length);
        // filter out secured inputs where the broker is not approved, put them in new array
        // filter out secured inputs that are zero amount, put them in new array
        for (uint i = 0; i < cross.securedInputs.length; i++) {
            Resource memory s = cross.securedInputs[i];
            if (s.amount == 0) continue;
            if (s.owner != msg.sender) {
                uint64 exp = broke[s.owner][msg.sender];
                if (exp == 0 || exp < block.timestamp) continue;
            }
            // do the same transfer here
            IZRC20 sec = cross.pair.secured;
            if (sec.balanceOf(s.owner) < s.amount) continue;
            IZRC20 res = cross.pair.reserve;
            if (!res.checkSupportsOwner(s.owner)) continue; // CRITICAL!
            try sec.transferFrom(s.owner, address(this), s.amount) returns (
                bool ok
            ) {
                if (!ok) continue;
            } catch {
                continue;
            }
            result.securedIn += s.amount;
            result.securedRes[i] = s;
            result.securedLen++;
        }
    }

    /* Distributes the outputs to the opposing resources pro-rata based on the amount of each */
    /* For example, 10 reserve distributed to 3 secured and 7 secured would give 3 to the first and 7 to the second */
    function justify(
        Pair memory pair,
        uint64 reserveOut,
        Resource[] memory reserveRes,
        uint64 reserveLen,
        uint64 securedOut,
        Resource[] memory securedRes,
        uint64 securedLen
    ) internal {
        // distribute reserveOut to securedRes pro-rata
        if (reserveOut > 0 && securedLen > 0) {
            uint64 totalSecured = 0;
            for (uint64 i = 0; i < securedLen; i++) {
                totalSecured += securedRes[i].amount;
            }
            for (uint64 i = 0; i < securedLen; i++) {
                uint64 share = (securedRes[i].amount * reserveOut) /
                    totalSecured;
                if (share > 0) {
                    pair.reserve.transfer(securedRes[i].owner, share);
                }
            }
        }
        // distribute securedOut to reserveRes pro-rata
        if (securedOut > 0 && reserveLen > 0) {
            uint64 totalReserve = 0;
            for (uint64 i = 0; i < reserveLen; i++) {
                totalReserve += reserveRes[i].amount;
            }
            for (uint64 i = 0; i < reserveLen; i++) {
                uint64 share = (reserveRes[i].amount * securedOut) /
                    totalReserve;
                if (share > 0) {
                    pair.secured.transfer(reserveRes[i].owner, share);
                }
            }
        }
    }

    /* get price of pool in Q64.64 = uint128 (secured / reserve) */
    /* scaled up by the MAX_FEE (price * MAX_FEE / (2^32 - 1)) */
    function poolPriceSecuredPerReserve(
        Pool storage pool
    ) internal view returns (uint128) {
        if (pool.reserve == 0) return type(uint128).max;
        return
            uint128(
                ((uint256(pool.secured) << 64) * MAX_FEE) /
                    (type(uint32).max * pool.reserve)
            );
    }

    /* get price of pool in Q64.64 = uint128 (secured / reserve) */
    /* scaled up by the MAX_FEE (price * MAX_FEE / (2^32 - 1)) */
    /* for the order in question (price is 0 if not activated) */
    /* if there is no liquidity in the order to buy on that side, 0 */
    function bookPriceBuySecuredForReserveFromOrder(
        Order memory order
    ) internal pure returns (uint128 price) {
        if (
            order.securedAmount == 0 ||
            order.reserveToSecuredTick >= order.securedToReserveTick
        ) {
            return 0;
        }
        price = EssentialHelpers.priceFromTick(order.reserveToSecuredTick);
        // scale up by MAX_FEE
        price = uint128((uint256(price) * MAX_FEE) / type(uint32).max);
    }

    function bookPriceBuyReservedForSecuredFromOrder(
        Order memory order
    ) internal pure returns (uint128 price) {
        if (
            order.reserveAmount == 0 ||
            order.reserveToSecuredTick >= order.securedToReserveTick
        ) {
            return 0;
        }
        price = EssentialHelpers.priceFromTick(order.securedToReserveTick);
        // scale up by MAX_FEE
        price = uint128((uint256(price) * MAX_FEE) / type(uint32).max);
    }

    /*══════════════════════════════════════════════════════════════════════*\
    │                    Internal helpers (PQSE‑local only)                 │
    \*══════════════════════════════════════════════════════════════════════*/

    /// @dev Gas‑cheaper branch‑free min for uint64.
    function _min(uint64 a, uint64 b) private pure returns (uint64) {
        return a < b ? a : b;
    }

    struct ExecuteResult {
        uint64 used;
        uint64 got;
        uint64 idx;
    }

    /*─────────────────────────── core execution ──────────────────────────*/

    /**
     * @dev Reserve‑side sweep of the order‑book until the effective price
     *      is no longer strictly **better** than the pool’s price.
     *
     *      See the original long‑form NatSpec above for behavioural details.
     *      This version writes its outcome into a compact `ExecuteResult`
     *      struct to keep the parent stack shallow.
     *
     * @param pool             Pool whose order‑book we traverse.
     * @param availableReserve Reserve remaining in the caller’s budget.
     * @param maxSecuredOut    Optional hard‑cap on secured the caller will take
     *                         (0 ⇒ no cap).
     *
     * @return result the result
     */
    function executeReserveForSecuredAgainstBookUntilPriceWorseThanPool(
        Pool storage pool,
        uint64 availableReserve,
        uint64 maxSecuredOut
    ) internal returns (ExecuteResult memory result) {
        /*──────────────── 0. reference pool price (Q64.64) ─────────────*/
        uint128 poolPx = poolPriceSecuredPerReserve(pool);

        /*──────────────── 1. linear walk over the book ─────────────────*/
        for (uint64 cursor; cursor < boop && availableReserve > 0; ++cursor) {
            Order storage o = pool.orders[cursor];

            /* Skip inactive or crossed orders. */
            if (
                o.securedAmount == 0 ||
                o.reserveToSecuredTick >= o.securedToReserveTick
            ) continue;

            /* Effective order price (fee‑adjusted). */
            uint128 px = bookPriceBuySecuredForReserveFromOrder(o);
            if (px == 0) continue; // sanity
            if (px >= poolPx) {
                // not better than pool
                result.idx = cursor; // first still‑viable order
                break; // stop sweep
            }

            /*──────── matching maths ────────*/

            /* Reserve needed to empty this order: secured / price. */
            uint64 needR = uint64((uint256(o.securedAmount) << 64) / px);
            if (needR > availableReserve) needR = availableReserve;

            /* Corresponding secured fill: reserve * price. */
            uint64 fillS = uint64((uint256(needR) * px) >> 64);

            /* Respect caller’s max output, if any. */
            if (maxSecuredOut != 0 && result.got + fillS > maxSecuredOut) {
                fillS = maxSecuredOut - result.got;
                needR = uint64((uint256(fillS) << 64) / px);
                availableReserve = 0; // budget fully consumed
            } else {
                availableReserve -= needR;
            }

            /* Mutate order in‑place. */
            o.securedAmount -= fillS;
            o.reserveAmount += needR;

            /* Accumulate outcome. */
            unchecked {
                result.used += needR;
                result.got += fillS;
            }
        }

        /*──────────────── 2. sentinel when sweep hit the end ───────────*/
        if (result.idx == 0 && (result.used != 0 || result.got != 0)) {
            result.idx = boop; // book exhausted / no attractive orders
        }
    }

    /**
     * @dev Mirror sweep: caller pays *secured* to buy *reserve* until the
     *      order‑book price ceases to beat the pool’s inverse price.
     *
     * @param pool             Pool whose book we traverse.
     * @param availableSecured Caller’s remaining secured budget.
     * @param maxReserveOut    Optional cap on reserve out (0 ⇒ no cap).
     *
     * @return result the result
     */
    function executeSecuredForReservedAgainstBookUntilPriceWorseThanPool(
        Pool storage pool,
        uint64 availableSecured,
        uint64 maxReserveOut
    ) internal returns (ExecuteResult memory result) {
        /*──────────────── 0. reference pool price (inverse) ─────────────*/
        uint128 poolPx = poolPriceSecuredPerReserve(pool);
        if (poolPx == 0) {
            // empty pool
            result.idx = boop;
            return result;
        }
        uint128 poolPxInv = uint128(
            ((uint256(1) << 128) + poolPx - 1) / poolPx
        );

        /*──────────────── 1. linear walk over the book ─────────────────*/
        for (uint64 cursor; cursor < boop && availableSecured > 0; ++cursor) {
            Order storage o = pool.orders[cursor];

            /* Skip inactive / crossed orders. */
            if (
                o.reserveAmount == 0 ||
                o.reserveToSecuredTick >= o.securedToReserveTick
            ) continue;

            /* Order’s reserve‑per‑secured price. */
            uint128 px = bookPriceBuyReservedForSecuredFromOrder(o);
            if (px == 0) continue; // sanity
            if (px >= poolPxInv) {
                // no longer better than pool
                result.idx = cursor;
                break;
            }

            /*──────── matching maths ────────*/

            /* Secured needed to empty order: reserve / price.  */
            uint64 needS = uint64((uint256(o.reserveAmount) << 64) / px);
            if (needS > availableSecured) needS = availableSecured;

            /* Corresponding reserve fill: secured * price.     */
            uint64 fillR = uint64((uint256(needS) * px) >> 64);

            /* Respect caller’s max output, if any. */
            if (maxReserveOut != 0 && result.got + fillR > maxReserveOut) {
                fillR = maxReserveOut - result.got;
                needS = uint64((uint256(fillR) << 64) / px);
                availableSecured = 0;
            } else {
                availableSecured -= needS;
            }

            /* Mutate order. */
            o.reserveAmount -= fillR;
            o.securedAmount += needS;

            /* Accumulate outcome. */
            unchecked {
                result.used += needS;
                result.got += fillR;
            }
        }

        /*──────────────── 2. sentinel when sweep hit the end ───────────*/
        if (result.idx == 0 && (result.used != 0 || result.got != 0)) {
            result.idx = boop;
        }
    }

    /**
     * @notice Match reserve‑side buyers with secured‑side buyers *directly*,
     *         using the caller‑supplied strike price.  No pool liquidity is
     *         touched—this is purely an internal netting step.
     *
     * Price convention
     * ────────────────
     * • `strikeQ64` = secured / reserve  (Q64.64 fixed‑point, fee‑adjusted).
     *
     * Execution logic
     * ───────────────
     * 1. Sanity checks: zero price or zero‑side submissions short‑circuit.
     * 2. Compute how much *secured* the reserve‑side *could* buy:
     *      `wantSecured = reserveIn × strike / 2⁶⁴`.
     * 3. Compare available `securedIn` against `wantSecured`:
     *    a) If supply ≥ demand ⇒ reserve side fully satisfied.
     *    b) Else              ⇒ secured side fully satisfied.
     * 4. Return the fills plus the still‑unmatched remainders.
     *
     * All math is performed in 256‑bit; results are clipped into uint64.
     *
     * @param strikeQ64     Price in Q64.64 (secured per reserve).
     * @param reserveIn     Reserve token supplied by *reserve‑side* traders.
     * @param securedIn     Secured token supplied by *secured‑side* traders.
     *
     * @return reserveOut        Reserve tokens paid to *secured* suppliers.
     * @return securedOut        Secured tokens paid to *reserve* suppliers.
     * @return reserveRemaining  Unmatched reserve still pending.
     * @return securedRemaining  Unmatched secured still pending.
     */
    function internalSwap(
        uint128 strikeQ64,
        uint64 reserveIn,
        uint64 securedIn
    )
        internal
        pure
        returns (
            uint64 reserveOut,
            uint64 securedOut,
            uint64 reserveRemaining,
            uint64 securedRemaining
        )
    {
        /*────────────────────── 0. edge cases ───────────────────────*/
        if (strikeQ64 == 0 || (reserveIn == 0 && securedIn == 0)) {
            // Nothing to do – return inputs as “remaining”.
            return (0, 0, reserveIn, securedIn);
        }

        /*────────────────────── 1. demand calc ──────────────────────*
         * wantSecured = reserveIn × strike / 2⁶⁴                     */
        uint256 wantSecured = (uint256(reserveIn) * strikeQ64) >> 64;

        /*────────────────────── 2. compare sides ────────────────────*/
        if (uint256(securedIn) >= wantSecured) {
            /* ‑ reserve side completely filled, secured side partial */
            securedOut = uint64(wantSecured); // paid out
            reserveOut = reserveIn; // all reserve sent
            securedRemaining = securedIn - securedOut; // leftover secured
            // reserveRemaining already 0
        } else {
            /* ‑ secured side completely filled, reserve side partial *
             * reserveNeeded = securedIn / strike                      *
             * => reserveNeeded = securedIn × 2⁶⁴ / strike            */
            reserveOut = uint64((uint256(securedIn) << 64) / strikeQ64);
            securedOut = securedIn; // all secured sent
            reserveRemaining = reserveIn - reserveOut; // leftover reserve
            // securedRemaining already 0
        }
    }

    /**
     * @notice Swap against the AMM pool **up to / down to** a caller‑supplied
     *         limit price.
     *
     * Price convention
     * ────────────────
     * • `limitPriceQ64_64` is *always* expressed as **secured / reserve**
     *   in Q64.64 fixed‑point (same as {priceFromTick} et al.).
     * • Direction is controlled by `reserveForSecured`:
     *     ‑ `true`   → caller gives **reserve**, receives **secured**.
     *     ‑ `false`  → caller gives **secured**, receives **reserve**.
     *
     * Execution logic (constant‑product k = R₀·S₀)
     * ─────────────────────────────────────────────
     * 1.  If the pool is empty (`R₀ == 0 || S₀ == 0`) short‑circuit.
     * 2a. (reserve→secured)  Solve the *maximum* ΔR such that the post‑swap
     *      price  (S' / R')  stays **≥** `limitPrice`.
     *     • P'Q64 = (k << 64) / R'²  ⇒  R'² ≤ (k << 64) / Pₗᵢₘᵢₜ
     * 2b. (secured→reserve)  Solve the *maximum* ΔS such that the post‑swap
     *      price  (S' / R')  stays **≤** `limitPrice`.
     *     • P'Q64 = (S'² << 64) / k  ⇒  S'² ≤ (k · Pₗᵢₘᵢₜ) >> 64
     * 3.  Use the **smaller** of caller input and the bound from step 2.
     * 4.  Apply the constant‑product update and write back pool balances.
     *
     * Gas & maths
     * ───────────
     * • All heavy maths is done in 256‑bit; results are clipped to 64‑bit
     *   token domains on write‑back (overflow would revert automatically).
     * • Babylonian √ is used—O(log n) iterations, branch‑free.
     *
     * @param pool              Storage reference to the pool.
     * @param reserveForSecured Swap direction selector (see above).
     * @param amountIn          Exact tokens the caller *offers*.
     * @param limitPriceQ64_64  Limit price (0 ⇒ no bound).
     *
     * @return amountInRemaining Caller tokens *not* used (hit price bound).
     * @return amountOutObtained Counter‑side tokens transferred **out**.
     */
    function executePool(
        Pool storage pool,
        bool reserveForSecured,
        uint64 amountIn,
        uint128 limitPriceQ64_64
    ) internal returns (uint64 amountInRemaining, uint64 amountOutObtained) {
        /*────────────────────── 0. degenerate pool ───────────────────────*/
        if (amountIn == 0 || pool.reserve == 0 || pool.secured == 0) {
            return (amountIn, 0);
        }

        /*────────────────────── 1. constants & cache ─────────────────────*/
        uint256 R0 = pool.reserve; // reserve before swap
        uint256 S0 = pool.secured; // secured before swap
        uint256 k = R0 * S0; // constant product (fits in 128‑bit × 128‑bit)

        /*────────────────────── 2. bound usable input ───────────────────*/
        uint256 maxIn = amountIn; // pessimistically assume full fill

        if (limitPriceQ64_64 != 0) {
            if (reserveForSecured) {
                /* Caller *adds reserve* ⇒ price falls.  Enforce P' ≥ limit. */
                // R'² ≤ (k << 64) / Pₗᵢₘᵢₜ
                uint256 boundSquared = (k << 64) / limitPriceQ64_64;
                uint256 Rbound = _sqrt(boundSquared);
                if (Rbound <= R0)
                    maxIn = 0; // already below limit
                else {
                    uint256 delta = Rbound - R0;
                    if (delta < maxIn) maxIn = delta;
                }
            } else {
                /* Caller *adds secured* ⇒ price rises.  Enforce P' ≤ limit. */
                // S'² ≤ (k · Pₗᵢₘᵢₜ) >> 64
                uint256 boundSquared = (k * limitPriceQ64_64) >> 64;
                uint256 Sbound = _sqrt(boundSquared);
                if (Sbound <= S0)
                    maxIn = 0; // already above limit
                else {
                    uint256 delta = Sbound - S0;
                    if (delta < maxIn) maxIn = delta;
                }
            }
        }

        /*────────────────────── 3. nothing usable? ──────────────────────*/
        if (maxIn == 0) {
            return (amountIn, 0); // price constraint too tight
        }

        /*────────────────────── 4. constant‑product swap ─────────────────*/
        if (reserveForSecured) {
            /* R → S : add ΔR, take ΔS                                *
             * New reserve R' = R0 + ΔR                               *
             * New secured S' = k / R'                                */
            uint256 newR = R0 + maxIn;
            uint256 newS = k / newR;
            uint256 out = S0 - newS; // secured out
            pool.reserve = uint64(newR);
            pool.secured = uint64(newS);
            amountOutObtained = uint64(out);
        } else {
            /* S → R : add ΔS, take ΔR                                *
             * New secured S' = S0 + ΔS                               *
             * New reserve R' = k / S'                                */
            uint256 newS = S0 + maxIn;
            uint256 newR = k / newS;
            uint256 out = R0 - newR; // reserve out
            pool.reserve = uint64(newR);
            pool.secured = uint64(newS);
            amountOutObtained = uint64(out);
        }

        /*────────────────────── 5. leftovers to caller ──────────────────*/
        amountInRemaining = amountIn - uint64(maxIn);
    }

    /**
     * @notice Fill *a single order* from the order‑book in either direction.
     *
     * Design notes
     * ────────────
     * • Price is derived from the order’s ticks via helper functions; a
     *   zero price or crossed‑tick order is treated as **inactive**.
     * • Function consumes up to `amountIn`; anything left returns to caller.
     * • No fee logic here—handled by outer layers later.
     *
     * @param order              Storage pointer to the order to hit.
     * @param reserveForSecured  `true`  → pay reserve, receive secured.
     *                           `false` → pay secured, receive reserve.
     * @param amountIn           Tokens the caller offers.
     *
     * @return amountInRemaining Unused caller tokens.
     * @return amountOutObtained Tokens received from the order.
     */
    function executeBook(
        Order storage order,
        bool reserveForSecured,
        uint64 amountIn
    ) internal returns (uint64 amountInRemaining, uint64 amountOutObtained) {
        /*──────────────── 0. filter inactive / crossed orders ───────────*/
        if (
            order.reserveToSecuredTick >= order.securedToReserveTick ||
            amountIn == 0
        ) {
            return (amountIn, 0); // nothing to do
        }

        /*──────────────── 1. price discovery ───────────────────────────*/
        uint128 px = reserveForSecured
            ? bookPriceBuySecuredForReserveFromOrder(order)
            : bookPriceBuyReservedForSecuredFromOrder(order);

        if (px == 0) return (amountIn, 0); // inactive order (price = 0)

        /*──────────────── 2. direction‑specific fill ───────────────────*/
        if (reserveForSecured) {
            /* Caller pays reserve → wants secured.                        *
             * reserveNeededToEmpty = order.securedAmount / px            */
            uint64 reserveNeeded = uint64(
                (uint256(order.securedAmount) << 64) / px
            );
            uint64 reserveFill = reserveNeeded < amountIn
                ? reserveNeeded
                : amountIn;

            uint64 securedFill = uint64((uint256(reserveFill) * px) >> 64);

            // book‑keeping
            order.securedAmount -= securedFill;
            order.reserveAmount += reserveFill;

            amountOutObtained = securedFill;
            amountInRemaining = amountIn - reserveFill;
        } else {
            /* Caller pays secured → wants reserve.                        *
             * securedNeededToEmpty = order.reserveAmount / px            */
            uint64 securedNeeded = uint64(
                (uint256(order.reserveAmount) << 64) / px
            );
            uint64 securedFill = securedNeeded < amountIn
                ? securedNeeded
                : amountIn;

            uint64 reserveFill = uint64((uint256(securedFill) * px) >> 64);

            // book‑keeping
            order.reserveAmount -= reserveFill;
            order.securedAmount += securedFill;

            amountOutObtained = reserveFill;
            amountInRemaining = amountIn - securedFill;
        }
    }

    /**
     * @notice Consume the caller’s entire `availableIn` by *alternating*
     *         between hitting the order‑book (at, or after, `bestIdx`)
     *         and the AMM pool.  Iteration stops once either:
     *
     *         1. `availableIn` is fully spent (normal exit), or
     *         2. neither the book *nor* the pool is willing to trade even
     *           a single token more (liquidity dry‑up).
     *
     *         The function is symmetric in direction:
     *           • `reservedForSecured == true`  → pay **reserve**, get **secured**.
     *           • `reservedForSecured == false` → pay **secured**, get **reserve**.
     *
     *         It returns the total counter‑side tokens obtained.  Any input
     *         left unspent (rare: book & pool empty) simply remains with the
     *         caller—nothing is transferred inside this helper.
     *
     * Assumptions & reasoning
     * ───────────────────────
     * • `orders` MUST be sorted by ascending economic attractiveness *for the
     *   caller* (best price first) and map 1‑for‑1 to `pool.orders` keys.
     *   The caller is responsible for guaranteeing this pre‑condition.
     * • We “flip” between the book and the pool on **every** successful trade
     *   so price impact is shared and the loop converges rapidly (< O(N)).
     * • A zero‑fill on either leg triggers termination—further attempts would
     *   repeat the same outcome and waste gas.
     *
     * @param pool               Pool to trade against (reserve/secured balances mutate).
     * @param reservedForSecured Direction selector (see above).
     * @param orders             List of candidate order IDs (book side).
     * @param bestIdx            Index in `orders` that is currently best.
     * @param availableIn        Exact tokens the caller is offering to trade.
     *
     * @return outObtained       Counter‑side tokens the caller receives.
     */
    function executeSlam(
        Pool storage pool,
        bool reservedForSecured,
        uint64[] memory orders,
        uint64 bestIdx,
        uint64 availableIn
    ) internal returns (uint64 outObtained) {
        /* Fast‑path: nothing to do. */
        if (availableIn == 0) return 0;

        uint64 remainingIn = availableIn; // input left to place
        bool useBook = true; // toggle: book ↔ pool

        /* Main loop: alternates until no further progress is possible.      *
         * Gas‑bounded by (orders.length + 1) iterations in the worst case.  */
        while (remainingIn > 0) {
            uint64 beforeIn = remainingIn; // sentinel to detect zero‑fill
            uint64 gotOut = 0; // holder for each leg’s fill

            if (useBook) {
                /*───────────────── BOOK LEG ─────────────────*/
                while (bestIdx < orders.length && remainingIn > 0) {
                    Order storage o = pool.orders[orders[bestIdx]];

                    (uint64 left, uint64 out) = executeBook(
                        o,
                        reservedForSecured,
                        remainingIn
                    );
                    remainingIn = left;
                    gotOut += out;

                    /* Order exhausted on its pay‑side?  Move cursor. */
                    if (
                        reservedForSecured
                            ? o.securedAmount == 0
                            : o.reserveAmount == 0
                    ) {
                        unchecked {
                            ++bestIdx;
                        }
                    }

                    /* Stop early if we consumed all input. */
                    if (remainingIn == 0) break;
                }
            } else {
                /*───────────────── POOL LEG ─────────────────*/
                (uint64 left, uint64 out) = executePool(
                    pool,
                    reservedForSecured,
                    remainingIn,
                    0 // no price limit – caller bears slippage
                );
                remainingIn = left;
                gotOut = out;
            }

            outObtained += gotOut;

            /* Terminate if this leg could not trade a single token. */
            if (beforeIn == remainingIn) break;

            /* Flip side for next iteration. */
            useBook = !useBook;
        }
    }

    /**
     * @notice Split and book‑keep a trading fee.
     *
     *         The helper is direction‑agnostic and can be used for both the
     *         input‑side (“outside” fee) and the output‑side (“embedded” fee)
     *         simply by toggling the `outside` flag.
     *
     *         Accounting rules
     *         ────────────────
     *         • Protocol share (`pro`)  → accrues under `profit[token]`.
     *         • LP share (`liq`)        → credited to `pool.reserve`.
     *         • Tip (`tip`)             → paid immediately to `msg.sender`.
     *         • Net amount              → `raw − pro − liq − tip`.
     *
     * @param pool        AMM pool whose reserve balance collects LP fees.
     * @param token       Reserve‑currency token (fees are always on reserve).
     * @param rawAmount   Amount on which the fee is calculated.
     * @param discountQ32 Caller’s FREE‑token rebate in Q.32 (0–2³²‑1).
     * @param tipQ32      Referral rate in Q.32 (0–2³²‑1).
     * @param outside     `true`  → fee added on top (input side).
     *                    `false` → fee embedded in `rawAmount` (output side).
     *
     * @return netAmount  Amount remaining for trading / settlement.
     */
    function _applyFee(
        Pool storage pool,
        IZRC20 token,
        uint64 rawAmount,
        uint32 discountQ32,
        uint32 tipQ32,
        bool outside
    ) internal returns (uint64 netAmount) {
        /* 1. Split the fee three‑ways (protocol, LP, tip). */
        (uint64 pro, uint64 liq, uint64 tipAmt) = EssentialHelpers.excise(
            outside,
            rawAmount,
            MAX_FEE,
            discountQ32,
            PRO_FEE,
            tipQ32
        );

        /* 2. Book protocol share. */
        if (pro != 0) profit[address(token)] += pro;

        /* 3. LP share accrues to the pool’s reserve balance. */
        if (liq != 0) pool.reserve += liq;

        /* 4. Pay referral tip straight to the preparer. */
        if (tipAmt != 0) token.transfer(msg.sender, tipAmt);

        /* 5. Net amount that proceeds further in the pipeline. */
        unchecked {
            netAmount = rawAmount - pro - liq - tipAmt;
        }
    }

    /**
     * @notice High‑level cross trade executor.
     *
     *         End‑to‑end flow:
     *         1.  Pull user funds via {crucify}.
     *         2.  Charge **input**‑side fee on the reserve currency.
     *         3.  Run the multi‑stage matching engine via {_execute}.
     *         4.  Charge **output**‑side fee on the reserve currency.
     *         5.  Enforce the caller’s strike‑price corridor.
     *         6.  Pro‑rata distribute the outcome to original contributors.
     *
     * @param cross       Trade specification (tokens, orders, resources).
     * @param free        Caller’s FREE‑token balance (max one full unit).
     * @param tip         Referral rate in Q.32 paid to `msg.sender`.
     *
     * @return reserveOut Net reserve tokens delivered to secured suppliers.
     * @return securedOut Net secured tokens delivered to reserve suppliers.
     */
    function execute(
        Cross calldata cross,
        uint64 free,
        uint64 tip
    ) external returns (uint64 reserveOut, uint64 securedOut) {
        /*──────────────── 1. FUND COLLECTION ────────────────*/
        Pair memory pair = cross.pair;
        CrucifyResult memory result = crucify(cross);

        if (result.reserveIn == 0 && result.securedIn == 0) return (0, 0);

        Pool storage pool = pools[pair.reserve][pair.secured];

        /*──────────────── 2. INPUT‑SIDE FEE ─────────────────*/
        uint32 discountQ32 = EssentialHelpers.discount32(FREE, free);
        result.reserveIn = _applyFee(
            pool,
            pair.reserve,
            result.reserveIn,
            discountQ32,
            uint32(tip),
            /*outside=*/ true
        );

        /*──────────────── 3. CORE MATCHING ─────────────────*/
        (reserveOut, securedOut) = _execute(
            pool,
            cross.reserveOrders,
            cross.securedOrders,
            result.reserveIn,
            result.securedIn
        );

        /*──────────────── 4. OUTPUT‑SIDE FEE ───────────────*/
        reserveOut = _applyFee(
            pool,
            pair.reserve,
            reserveOut,
            discountQ32,
            uint32(tip),
            /*outside=*/ false // embedded
        );

        /*──────────────── 5. STRIKE GUARDRAIL ──────────────*/
        // (2) average execution prices, secured / reserve (Q64.64)
        uint128 buyPxQ64  = result.reserveIn == 0
            ? 0
            : uint128((uint256(securedOut) << 64) / result.reserveIn);

        uint128 sellPxQ64 = result.securedIn == 0
            ? 0
            : uint128((uint256(result.securedIn) << 64) / reserveOut);

        // (3) enforce corridor on BOTH sides
        _enforceGuardrail(
            buyPxQ64,
            sellPxQ64,
            cross.minStrikePrice,
            cross.maxStrikePrice
        );

        /*──────────────── 6. FINAL SETTLEMENT ──────────────*/
        justify(
            pair,
            reserveOut,
            result.reserveRes,
            result.reserveLen,
            securedOut,
            result.securedRes,
            result.securedLen
        );
    }

    /**
     * @notice Enforce the caller‑supplied strike‑price corridor on *both*
     *         sides of the trade.
     *
     *         The corridor is expressed in Uniswap‑style ticks
     *         (`minStrikePrice`, `maxStrikePrice`).  We convert those once,
     *         then verify that:
     *
     *           • `buyPxQ64`  (secured / reserve paid by reserve‑side buyers)
     *           • `sellPxQ64` (secured / reserve paid by secured‑side buyers)
     *
     *         each lies inside [min, max].  A side that traded *zero* volume
     *         bypasses the check automatically.
     *
     * @param buyPxQ64   Average price on the *reserve→secured* path.
     * @param sellPxQ64  Average price on the *secured→reserve* path.
     * @param minTick    Inclusive lower bound (caller’s `minStrikePrice`).
     * @param maxTick    Inclusive upper bound (caller’s `maxStrikePrice`).
     */
    function _enforceGuardrail(
        uint128 buyPxQ64,
        uint128 sellPxQ64,
        uint24 minTick,
        uint24 maxTick
    ) internal pure {
        uint128 minPx = EssentialHelpers.priceFromTick(int24(minTick));
        uint128 maxPx = EssentialHelpers.priceFromTick(int24(maxTick));

        if (buyPxQ64 != 0) {
            require(
                buyPxQ64 >= minPx && buyPxQ64 <= maxPx,
                "guardrail: buy-side price"
            );
        }
        if (sellPxQ64 != 0) {
            require(
                sellPxQ64 >= minPx && sellPxQ64 <= maxPx,
                "guardrail: sell-side price"
            );
        }
    }

    /**
     * @dev Core trading pipe‑line – encapsulates all *execution* stages
     *      (book passes, internal netting, and final “slam”) while leaving
     *      **fee accounting** to the caller.  The flow is:
     *
     *      1.  Reserve‑for‑Secured book sweep until price ≥ pool.
     *      2.  Secured‑for‑Reserve book sweep until price ≤ pool.
     *      3.  Direct netting of the two flows via {internalSwap}.
     *      4.  One last “slam” pass against whichever side still holds input,
     *          alternating pool ↔ book to minimise slippage.
     *
     *      Assumptions
     *      ───────────
     *      • `reserveOrders` and `securedOrders` are *caller‑sorted* from best
     *        to worst price (ascending economic cost).  We do not sort them.
     *      • No fees are applied here – the caller handles that before/after.
     *
     * @param pool              AMM pool (state‑mutated in‑place).
     * @param reserveOrders     IDs of candidate orders for R→S fills.
     * @param securedOrders     IDs of candidate orders for S→R fills.
     * @param reserveIn         Net reserve tokens available to trade.
     * @param securedIn         Net secured tokens available to trade.
     *
     * @return reserveOut       Reserve tokens paid to secured suppliers.
     * @return securedOut       Secured tokens paid to reserve suppliers.
     */
    function _execute(
        Pool storage pool,
        uint64[] memory reserveOrders,
        uint64[] memory securedOrders,
        uint64 reserveIn,
        uint64 securedIn
    ) internal returns (uint64 reserveOut, uint64 securedOut) {
        /*─────────── 1. BOOK SWEEP (reserve → secured) ───────────*/
        ExecuteResult
            memory r4s = executeReserveForSecuredAgainstBookUntilPriceWorseThanPool(
                pool,
                reserveIn,
                /*maxSecuredOut=*/ 0
            );
        reserveIn -= r4s.used; // leftover reserve
        securedOut += r4s.got; // secured earned by reserve payers

        /*─────────── 2. BOOK SWEEP (secured → reserve) ───────────*/
        ExecuteResult
            memory s4r = executeSecuredForReservedAgainstBookUntilPriceWorseThanPool(
                pool,
                securedIn,
                /*maxReserveOut=*/ 0
            );
        securedIn -= s4r.used; // leftover secured
        reserveOut += s4r.got; // reserve earned by secured payers

        /*─────────── 3. DIRECT NETTING (internal swap) ───────────*/
        uint128 strikeQ64 = poolPriceSecuredPerReserve(pool); // pool Px (Q64)
        (
            uint64 resOutIS,
            uint64 secOutIS,
            uint64 resRem,
            uint64 secRem
        ) = internalSwap(strikeQ64, reserveIn, securedIn);

        reserveOut += resOutIS; // add reserve from internal swap
        securedOut += secOutIS; // add secured from internal swap
        reserveIn = resRem; // residual reserve still unfilled
        securedIn = secRem; // residual secured still unfilled

        /*─────────── 4. FINAL “SLAM” PASS ────────────────────────*/
        if (reserveIn > 0) {
            /* Still long reserve – buy secured. */
            securedOut += executeSlam(
                pool,
                /*reservedForSecured=*/ true,
                reserveOrders,
                r4s.idx,
                reserveIn
            );
        } else if (securedIn > 0) {
            /* Still long secured – buy reserve. */
            reserveOut += executeSlam(
                pool,
                /*reservedForSecured=*/ false,
                securedOrders,
                s4r.idx,
                securedIn
            );
        }
    }

    /*═══════════════════════════════════════════════════════════════*/
    /*                     internal math helper                      */
    /*═══════════════════════════════════════════════════════════════*/

    /// @dev Babylonian square‑root. Guaranteed to converge in ~7 iterations.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        // First guess: 2^(⌈log2(x)/2⌉)
        uint256 z = 1;
        uint256 tmp = x;
        if (tmp >> 128 > 0) {
            tmp >>= 128;
            z <<= 64;
        }
        if (tmp >> 64 > 0) {
            tmp >>= 64;
            z <<= 32;
        }
        if (tmp >> 32 > 0) {
            tmp >>= 32;
            z <<= 16;
        }
        if (tmp >> 16 > 0) {
            tmp >>= 16;
            z <<= 8;
        }
        if (tmp >> 8 > 0) {
            tmp >>= 8;
            z <<= 4;
        }
        if (tmp >> 4 > 0) {
            tmp >>= 4;
            z <<= 2;
        }
        if (tmp >> 2 > 0) {
            z <<= 1;
        }

        // Babylonian iterations
        y = z;
        uint256 zPrev;
        while (true) {
            zPrev = y;
            y = (y + x / y) >> 1;
            if (y >= zPrev) {
                // reached fixed point
                y = zPrev;
                break;
            }
        }
    }

    constructor(address freeToken) {
        require(freeToken != address(0), "zero free");
        FREE = IZRC20(freeToken);
    }
}

// "Just fork Uniswap!"
// Go ahead and do it.
