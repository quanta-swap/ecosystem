// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "../../IZRC20.sol";

/*╔════════════════════════ Custom errors ═══════════════════════════════╗*\
│ Gas-efficient and self-documenting revert reasons. Every param carries │
│ debugging context so off-chain indexers / UI surfaces can display the │
│ exact failure cause without string-parsing.                           │
\*╚══════════════════════════════════════════════════════════════════════╝*/

/**
 * @notice Caller is not the router authorised for this order-book instance.
 * @param caller The account that attempted the restricted call.
 * @param expected The router address stored in the contract.
 */
error RouterOnly(address caller, address expected);

/**
 * @notice A function received the zero address where non-zero was required.
 * @param slot Human-readable description of the argument (e.g. "assetA").
 */
error ZeroAddress(string slot);

/**
 * @notice Assets supplied to the constructor are identical.
 * @param asset The duplicate ERC-20 address.
 */
error SameAsset(address asset);

/**
 * @notice Order-creation attempted with zero liquidity on both sides.
 */
error ZeroReserves();

/**
 * @notice Tick range is invalid (`tickBuy >= tickSell`).
 * @param tickBuy  Lower tick supplied.
 * @param tickSell Upper tick supplied.
 */
error BadTicks(int24 tickBuy, int24 tickSell);

/**
 * @notice Tick values are out of valid range.
 * @param tickBuy  Lower tick supplied.
 * @param tickSell Upper tick supplied.
 */
error BadTicksRange(int24 tickBuy, int24 tickSell);

/**
 * @notice Tick replacement widens the spread instead of narrowing it.
 * @param newBuy   New lower tick.
 * @param newSell  New upper tick.
 * @param oldBuy   Previous lower tick.
 * @param oldSell  Previous upper tick.
 */
error WorseTicks(int24 newBuy, int24 newSell, int24 oldBuy, int24 oldSell);

/**
 * @notice Function restricted to the order’s owner.
 * @param orderId   The order being accessed.
 * @param expected  Owner stored in contract.
 * @param caller    Transaction origin attempting the action.
 */
error NotOwner(uint64 orderId, address expected, address caller);

/**
 * @notice Referenced orderId does not exist.
 * @param orderId The missing order identifier.
 */
error NoOrder(uint64 orderId);

/**
 * @notice Arithmetic overflow or result does not fit in 64-bits.
 */
error Overflow();

/**
 * @notice Attempted to trade on a side that the maker disabled.
 * @param orderId     The maker order in question.
 * @param baseForQuote `true` if taker tried base→quote, `false` otherwise.
 */
error SideDisabled(uint64 orderId, bool baseForQuote);

/**
 * @notice Attempted a swap with `amountSpecified == 0`.
 */
error ZeroAmount();

/**
 * @notice A command in a batch was invalid (e.g. both cancel and create empty).
 */
error BadCommand(uint256 index);

/**
 * @notice Both tickBuy and tickSell are disabled; order would be inert.
 * @param tickBuy  Lower tick supplied (disabled sentinel).
 * @param tickSell Upper tick supplied (disabled sentinel).
 */
error BothTicksDisabled(int24 tickBuy, int24 tickSell);

/*╔══════════════════ Minimal ReentrancyGuard (1.4 kGas) ════════════════╗*/
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
/*╚═════════════════════════════════════════════════════════════════════╝*/

/*─────────────────────── ICLOB interface (trimmed) ────────────────────*/
interface ICLOB {
    event OrderCreated(
        uint64 indexed orderId,
        address indexed owner,
        uint64 baseReserve,
        uint64 quoteReserve,
        uint24 tickBuy,
        uint24 tickSell
    );
    event OrderFilled(
        uint64 indexed orderId,
        address indexed owner,
        uint64 amountIn,
        uint64 amountOut,
        bool baseForQuote
    );
    event OrderCancelled(uint64 indexed orderId, address indexed owner);
    event OrderReplaced(
        uint64 indexed orderId,
        address indexed owner,
        uint64 baseReserve,
        uint64 quoteReserve,
        uint24 tickBuy,
        uint24 tickSell
    );

    struct Order {
        uint64 baseReserve;
        uint64 quoteReserve;
        int24 tickBuy; // MIN if not buying
        int24 tickSell; // MIN if not selling
    }

    struct OrderCreate {
        // if owner is 0 then the delta is not defined
        address owner; // tx.origin owner
        uint64 baseReserveDelta;
        uint64 quoteReserveDelta;
        int24 tickBuy;
        int24 tickSell;
    }

    struct OrderCancel {
        // if id is 0 then the cancel is not defined
        uint64 id;
        // must be owned by tx.origin
    }

    struct MakeCommand {
        OrderCancel cancel;
        OrderCreate create;
    }

    function getBase() external view returns (IZRC20);
    function getQuote() external view returns (IZRC20);
    function getPair() external view returns (IZRC20 base, IZRC20 quote);

    function getOrders(
        uint64[] calldata orderIds
    ) external view returns (Order[] memory);
    function isOwner(
        uint64 orderId,
        address owner
    ) external view returns (bool);
    function getDiscountToken() external view returns (IZRC20);

    // specifies a set of orders to cancel and a set of orders to create
    function makeFrom(
        address auth,
        MakeCommand[] calldata commands
    ) external returns (int256 netBase, int256 netQuote);

    // Does not perform any transfers into maker accounts, simply custodies the funds into
    // the orders themselves waiting to be cancelled, which functions as the claim.
    function takeFrom(
        uint64 orderId,
        bool baseForQuote,
        uint64 amountSpecified,
        bool exactIn
    )
        external
        returns (
            int256 netBase,
            int256 netQuote,
            uint64 gotBase,
            uint64 gotQuote
        );

    function simulate(
        uint64 orderId,
        bool baseForQuote,
        uint64 amountSpecified,
        bool exactIn
    )
        external
        view
        returns (
            int256 netBase,
            int256 netQuote,
            uint64 gotBase,
            uint64 gotQuote
        );

    function getPrices(
        uint64[] calldata orderIds
    )
        external
        view
        returns (uint256[] memory buyPricesX64, uint256[] memory sellPricesX64);
}

/*╔══════════════════           CLOB core          ═════════════════════╗*/
contract CLOB is ICLOB, ReentrancyGuard {
    /*────────────────── Immutable configuration ──────────────────*/
    IZRC20 private immutable _base;
    IZRC20 private immutable _quote;
    IZRC20 private immutable _discountToken;
    address private immutable _router;

    /*──────────────────   Internal state mappings   ───────────────*/
    mapping(uint64 => Order) private _orders;
    mapping(uint64 => address) private _owners;
    uint64 private _nextId = 1;

    /* Sentinel tick meaning “side disabled”.  Chosen as int24 min
       so it never collides with Uniswap’s legal range [MIN_TICK, MAX_TICK]. */
    int24 internal constant DISABLED_TICK = type(int24).min;

    /*───────── Constructor ─────────*/
    /**
     * @param assetA  ERC-20 address (unordered).
     * @param assetB  ERC-20 address (unordered).
     * @param discountToken ERC-20 used by router for fee discounts.
     * @param router  Trusted router that settles net deltas.
     */
    constructor(
        IZRC20 assetA,
        IZRC20 assetB,
        IZRC20 discountToken,
        address router
    ) {
        if (address(assetA) == address(0)) revert ZeroAddress("assetA");
        if (address(assetB) == address(0)) revert ZeroAddress("assetB");
        if (address(discountToken) == address(0))
            revert ZeroAddress("discountToken");
        if (router == address(0)) revert ZeroAddress("router");
        if (address(assetA) == address(assetB))
            revert SameAsset(address(assetA));

        /* Canonicalise ordering so (token0,token1) is deterministic. */
        if (address(assetA) > address(assetB)) {
            (assetA, assetB) = (assetB, assetA);
        }
        _base = assetA;
        _quote = assetB;
        _discountToken = discountToken;
        _router = router;
    }

    /*──────────────────────────── View helpers ───────────────────────────*/
    function getBase() external view override returns (IZRC20) {
        return _base;
    }
    function getQuote() external view override returns (IZRC20) {
        return _quote;
    }
    function getPair()
        external
        view
        override
        returns (IZRC20 base_, IZRC20 quote_)
    {
        return (_base, _quote);
    }

    function getDiscountToken() external view override returns (IZRC20) {
        return _discountToken;
    }

    function getMaster() external view returns (address) {
        return _router;
    }

    /*──────────────────── Internal order helpers ───────────────────*/

    // ────────────────────────────────────────────────────────────────────────
    //  _createOrder ‒ registers a brand-new maker order
    // ────────────────────────────────────────────────────────────────────────
    /**
     * @notice Creates a new order and assigns ownership.
     *
     * @dev
     * ─ Validates tick ranges via {_enforceTicks} **before** any storage writes.
     * ─ Rejects the zero-address owner and all-zero reserves.
     * ─ Guards against `uint64` overflow on the order-ID counter so a wrap-around
     *   can never silently corrupt state.
     * ─ Emits {OrderCreated} with canonicalised ticks (uint24 cast).
     *
     * @param owner         Maker address (must be non-zero).
     * @param baseReserve   Initial base-token liquidity (0 allowed if quote>0).
     * @param quoteReserve  Initial quote-token liquidity (0 allowed if base>0).
     * @param tickBuy       Buy-side limit tick (`DISABLED_TICK` disables buying).
     * @param tickSell      Sell-side limit tick (`DISABLED_TICK` disables selling).
     *
     * @return orderId  Monotonically-increasing identifier allocated to the order.
     *
     * @custom:error ZeroAddress      `owner` was the zero address.
     * @custom:error ZeroReserves     Both reserves were zero.
     * @custom:error Overflow         `_nextId` exceeded `type(uint64).max`.
     * @custom:error BadTicksRange    One or both ticks out of Uniswap range.
     * @custom:error BadTicks         Both sides enabled but `tickBuy >= tickSell`.
     * @custom:error BothTicksDisabled Both ticks passed as `DISABLED_TICK`.
     */
    function _createOrder(
        address owner,
        uint64 baseReserve,
        uint64 quoteReserve,
        int24 tickBuy,
        int24 tickSell
    ) internal returns (uint64 orderId) {
        /* ────── Argument sanity checks ────── */
        _enforceTicks(tickBuy, tickSell);
        if (owner == address(0)) revert ZeroAddress("owner");
        if (baseReserve == 0 && quoteReserve == 0) revert ZeroReserves();

        /* ────── Allocate identifier with overflow guard ────── */
        orderId = _nextId;
        if (orderId == type(uint64).max) revert Overflow(); // no wrap-around
        unchecked {
            _nextId = orderId + 1;
        }

        /* ────── Persist order ────── */
        _orders[orderId] = Order({
            baseReserve: baseReserve,
            quoteReserve: quoteReserve,
            tickBuy: tickBuy,
            tickSell: tickSell
        });
        _owners[orderId] = owner; // save before emit for indexer consistency

        emit OrderCreated(
            orderId,
            owner,
            baseReserve,
            quoteReserve,
            uint24(tickBuy),
            uint24(tickSell)
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    //  _replaceOrder ‒ in-place order mutation (only in taker-favourable dir.)
    // ────────────────────────────────────────────────────────────────────────
    /**
     * @notice Mutates an existing order, optionally adding liquidity.
     *
     * @dev
     * ─ Caller must be the recorded owner (enforced via {NotOwner}).
     * ─ **Only** price moves that benefit takers are allowed:
     *     • `newBuy` ≥ `oldBuy` (maker pays more quote per base)
     *     • `newSell` ≤ `oldSell` (maker accepts less quote per base)
     * ─ Adds explicit arithmetic overflow guards so the custom {Overflow} error
     *   is surfaced instead of the generic `panic(0x11)`.
     * ─ Emits {OrderReplaced} with the new persistent state.
     *
     * @param owner     Maker asserted by the router.
     * @param id        Identifier of the order being modified.
     * @param addBase   Additional base liquidity to credit (may be 0).
     * @param addQuote  Additional quote liquidity to credit (may be 0).
     * @param newBuy    Replacement buy tick (`DISABLED_TICK` keeps side disabled).
     * @param newSell   Replacement sell tick (`DISABLED_TICK` keeps side disabled).
     *
     * @custom:error NoOrder       `id` did not reference a live order.
     * @custom:error NotOwner      `owner` mismatch.
     * @custom:error WorseTicks    Update makes prices worse for takers.
     * @custom:error Overflow      Reserve addition overflowed 64-bits.
     * @custom:error ZeroReserves  Resulting order would hold zero liquidity.
     */
    function _replaceOrder(
        address owner,
        uint64 id,
        uint64 addBase,
        uint64 addQuote,
        int24 newBuy,
        int24 newSell
    ) internal {
        _enforceTicks(newBuy, newSell);

        address actualOwner = _owners[id];
        if (actualOwner == address(0)) revert NoOrder(id);
        if (actualOwner != owner) revert NotOwner(id, actualOwner, owner);

        Order storage o = _orders[id];

        // ─── Ensure price move is taker-favourable ───
        if (newBuy < o.tickBuy || newSell > o.tickSell)
            revert WorseTicks(newBuy, newSell, o.tickBuy, o.tickSell);

        // ─── Compute new reserves with explicit overflow detection ───
        uint64 newBase;
        uint64 newQuote;
        unchecked {
            newBase = o.baseReserve + addBase;
            newQuote = o.quoteReserve + addQuote;
        }
        if (newBase < o.baseReserve || newQuote < o.quoteReserve)
            revert Overflow();
        if (newBase == 0 && newQuote == 0) revert ZeroReserves();

        // ─── Persist updated state ───
        o.baseReserve = newBase;
        o.quoteReserve = newQuote;
        o.tickBuy = newBuy;
        o.tickSell = newSell;

        emit OrderReplaced(
            id,
            owner,
            newBase,
            newQuote,
            uint24(newBuy),
            uint24(newSell)
        );
    }

    /**
     * @dev Cancels order and returns its reserves (router must refund owner).
     */
    function _cancelOrder(
        address owner,
        uint64 orderId
    ) internal returns (uint64 br, uint64 qr) {
        address actual = _owners[orderId];
        if (actual == address(0)) revert NoOrder(orderId);
        if (actual != owner) revert NotOwner(orderId, actual, owner);

        Order memory o = _orders[orderId];
        br = o.baseReserve;
        qr = o.quoteReserve;

        delete _orders[orderId];
        delete _owners[orderId];

        emit OrderCancelled(orderId, owner);
    }

    /*────────────────────────── Maker entrypoint ──────────────────────────*/
    /**
     * @inheritdoc ICLOB
     *
     * @custom:param auth  Maker address asserted by router.
     * @dev    Returns **signed** liquidity deltas so the router can net-settle
     *         the entire batch with one ERC-20 transfer per token.
     */
    function makeFrom(
        address auth,
        MakeCommand[] calldata cmds
    ) external override nonReentrant returns (int256 netBase, int256 netQuote) {
        if (msg.sender != _router) revert RouterOnly(msg.sender, _router);

        /* Positive → refund to maker ; Negative → maker must deposit. */
        int256 dBase;
        int256 dQuote;

        unchecked {
            for (uint256 i; i < cmds.length; ++i) {
                MakeCommand calldata c = cmds[i];

                /* Replace = cancel+create in same slot (saves orderId churn). */
                if (c.cancel.id != 0 && c.create.owner != address(0)) {
                    _replaceOrder(
                        auth,
                        c.cancel.id,
                        c.create.baseReserveDelta,
                        c.create.quoteReserveDelta,
                        c.create.tickBuy,
                        c.create.tickSell
                    );
                    dBase -= int256(uint256(c.create.baseReserveDelta));
                    dQuote -= int256(uint256(c.create.quoteReserveDelta));
                } else if (c.cancel.id != 0) {
                    (uint64 br, uint64 qr) = _cancelOrder(auth, c.cancel.id);
                    dBase += int256(uint256(br));
                    dQuote += int256(uint256(qr));
                } else if (c.create.owner != address(0)) {
                    _createOrder(
                        auth,
                        c.create.baseReserveDelta,
                        c.create.quoteReserveDelta,
                        c.create.tickBuy,
                        c.create.tickSell
                    );
                    dBase -= int256(uint256(c.create.baseReserveDelta));
                    dQuote -= int256(uint256(c.create.quoteReserveDelta));
                } else {
                    revert BadCommand(i);
                }
            }
        }
        return (dBase, dQuote);
    }

    /*────────────────────────── Taker entrypoint ──────────────────────────*/
    /**
     * @inheritdoc ICLOB
     *
     * @dev Fixes over-charge in the base→quote *exact-in* path by
     *      recomputing the actual `baseIn` required after we clip the maker’s
     *      `quoteReserve`.  Also emits the {Taken} convenience event.
     */
    function takeFrom(
        uint64 orderId,
        bool baseForQuote,
        uint64 amountSpecified,
        bool exactIn
    )
        external
        override
        nonReentrant
        returns (
            int256 netBase,
            int256 netQuote,
            uint64 gotBase,
            uint64 gotQuote
        )
    {
        if (msg.sender != _router) revert RouterOnly(msg.sender, _router);
        if (amountSpecified == 0) revert ZeroAmount();

        address maker = _owners[orderId];
        if (maker == address(0)) revert NoOrder(orderId);

        Order storage o = _orders[orderId];

        /* ───────────── taker buys QUOTE for BASE ───────────── */
        if (baseForQuote) {
            if (o.tickBuy == DISABLED_TICK || o.quoteReserve == 0)
                revert SideDisabled(orderId, true);

            uint256 px = TickMath.priceX64(o.tickBuy); // quote / base  (Q64.64)

            if (exactIn) {
                /* ‒ taker specifies BASE they are willing to pay ‒ */
                uint256 baseIn = amountSpecified;

                // maximum quote the taker could receive at this price
                uint256 maxQuote = (baseIn * px) >> 64;
                if (maxQuote == 0) revert Overflow();

                // clip by maker inventory
                uint256 quoteOut = maxQuote <= o.quoteReserve
                    ? maxQuote
                    : o.quoteReserve;

                // recompute the *actual* base required after clipping
                uint256 needBase = ((quoteOut << 64) + px - 1) / px; // ceilDiv
                if (needBase > type(uint64).max) revert Overflow();

                // state updates
                o.baseReserve += uint64(needBase);
                o.quoteReserve -= uint64(quoteOut);

                netBase = int256(needBase);
                netQuote = -int256(quoteOut);
                gotBase = uint64(needBase);
                gotQuote = uint64(quoteOut);
            } else {
                /* ‒ taker specifies desired QUOTE output ‒ */
                uint256 quoteWant = amountSpecified;
                uint256 quoteOut = quoteWant <= o.quoteReserve
                    ? quoteWant
                    : o.quoteReserve;

                uint256 needBase = ((quoteOut << 64) + px - 1) / px; // ceilDiv
                if (needBase > type(uint64).max) revert Overflow();

                o.baseReserve += uint64(needBase);
                o.quoteReserve -= uint64(quoteOut);

                netBase = int256(needBase);
                netQuote = -int256(quoteOut);
                gotBase = uint64(needBase);
                gotQuote = uint64(quoteOut);
            }

            emit OrderFilled(orderId, maker, gotBase, gotQuote, true);
            /* ───────────── taker sells QUOTE for BASE ───────────── */
        } else {
            if (o.tickSell == DISABLED_TICK || o.baseReserve == 0)
                revert SideDisabled(orderId, false);

            uint256 px = TickMath.priceX64(o.tickSell); // quote / base (Q64.64)

            if (exactIn) {
                uint256 quoteIn = amountSpecified;
                uint256 baseOut = (quoteIn << 64) / px; // floor div
                if (baseOut == 0) revert Overflow();

                if (baseOut > o.baseReserve) {
                    baseOut = o.baseReserve;
                    quoteIn = (baseOut * px) >> 64; // re-solve for quoteIn
                }

                o.quoteReserve += uint64(quoteIn);
                o.baseReserve -= uint64(baseOut);

                netBase = -int256(baseOut);
                netQuote = int256(quoteIn);
                gotBase = uint64(baseOut);
                gotQuote = uint64(quoteIn);
            } else {
                uint256 baseWant = amountSpecified;
                uint256 baseOut = baseWant <= o.baseReserve
                    ? baseWant
                    : o.baseReserve;

                uint256 needQuote = (baseOut * px) >> 64;
                if (needQuote > type(uint64).max) revert Overflow();

                o.quoteReserve += uint64(needQuote);
                o.baseReserve -= uint64(baseOut);

                netBase = -int256(baseOut);
                netQuote = int256(needQuote);
                gotBase = uint64(baseOut);
                gotQuote = uint64(needQuote);
            }

            emit OrderFilled(orderId, maker, gotQuote, gotBase, false);
        }
    }

    /*────────────────────── View-only “what-if” ──────────────────────────*/
    /**
     * @inheritdoc ICLOB
     *
     * @dev Never reverts; any invalid combination returns all-zeros so callers
     *      can probe the book safely.
     */
    function simulate(
        uint64 orderId,
        bool baseForQuote,
        uint64 amountSpecified,
        bool exactIn
    )
        external
        view
        override
        returns (
            int256 netBase,
            int256 netQuote,
            uint64 gotBase,
            uint64 gotQuote
        )
    {
        if (amountSpecified == 0) return (0, 0, 0, 0);
        address maker = _owners[orderId];
        if (maker == address(0)) return (0, 0, 0, 0);

        Order storage o = _orders[orderId];

        /* Same math as takeFrom but without state changes. Any branch that
           would revert simply early-returns zeros instead. */
        if (baseForQuote) {
            if (o.tickBuy == DISABLED_TICK || o.quoteReserve == 0)
                return (0, 0, 0, 0);
            uint256 px = TickMath.priceX64(o.tickBuy);

            if (exactIn) {
                uint64 baseIn = amountSpecified;
                uint256 maxQ = (uint256(baseIn) * px) >> 64;
                if (maxQ == 0) return (0, 0, 0, 0);
                uint64 quoteOut = maxQ <= o.quoteReserve
                    ? uint64(maxQ)
                    : o.quoteReserve;

                netBase = int256(uint256(baseIn));
                netQuote = -int256(uint256(quoteOut));
                gotBase = baseIn;
                gotQuote = quoteOut;
            } else {
                uint64 quoteWant = amountSpecified;
                uint64 quoteOut = quoteWant <= o.quoteReserve
                    ? quoteWant
                    : o.quoteReserve;
                uint256 needBase = ((uint256(quoteOut) << 64) + px - 1) / px;

                if (needBase == 0 || needBase > type(uint64).max)
                    return (0, 0, 0, 0);

                netBase = int256(needBase);
                netQuote = -int256(uint256(quoteOut));
                gotBase = uint64(needBase);
                gotQuote = quoteOut;
            }
        } else {
            if (o.tickSell == DISABLED_TICK || o.baseReserve == 0)
                return (0, 0, 0, 0);
            uint256 px = TickMath.priceX64(o.tickSell);

            if (exactIn) {
                uint64 quoteIn = amountSpecified;
                uint64 baseOut = uint64((uint256(quoteIn) << 64) / px);
                if (baseOut == 0) return (0, 0, 0, 0);
                if (baseOut > o.baseReserve) {
                    baseOut = o.baseReserve;
                    quoteIn = uint64((uint256(baseOut) * px) >> 64);
                }

                netBase = -int256(uint256(baseOut));
                netQuote = int256(uint256(quoteIn));
                gotBase = baseOut;
                gotQuote = quoteIn;
            } else {
                uint64 baseWant = amountSpecified;
                uint64 baseOut = baseWant <= o.baseReserve
                    ? baseWant
                    : o.baseReserve;
                uint256 needQuote = (uint256(baseOut) * px) >> 64;

                if (needQuote == 0 || needQuote > type(uint64).max)
                    return (0, 0, 0, 0);

                netBase = -int256(uint256(baseOut));
                netQuote = int256(needQuote);
                gotBase = baseOut;
                gotQuote = uint64(needQuote);
            }
        }
    }

    /*──────────────────────── Batch price helper ─────────────────────────*/
    /**
     * @inheritdoc ICLOB
     */
    function getPrices(
        uint64[] calldata ids
    )
        external
        view
        override
        returns (uint256[] memory buyPx, uint256[] memory sellPx)
    {
        uint256 n = ids.length;
        buyPx = new uint256[](n);
        sellPx = new uint256[](n);

        unchecked {
            for (uint256 i; i < n; ++i) {
                uint64 id = ids[i];
                if (_owners[id] == address(0)) {
                    continue;
                } // gap remains zero
                Order storage o = _orders[id];

                if (o.tickBuy != DISABLED_TICK)
                    buyPx[i] = TickMath.priceX64(o.tickBuy);
                if (o.tickSell != DISABLED_TICK)
                    sellPx[i] = TickMath.priceX64(o.tickSell);
            }
        }
    }

    /*──────────────────── Public getters (unchanged ABI) ─────────────────*/
    function getOrders(
        uint64[] calldata ids
    ) external view override returns (Order[] memory out) {
        uint256 n = ids.length;
        out = new Order[](n);
        unchecked {
            for (uint256 i; i < n; ++i) {
                uint64 id = ids[i];
                out[i] = _owners[id] != address(0)
                    ? _orders[id]
                    : Order({
                        baseReserve: 0,
                        quoteReserve: 0,
                        tickBuy: DISABLED_TICK,
                        tickSell: DISABLED_TICK
                    });
            }
        }
    }

    function isOwner(
        uint64 id,
        address who
    ) external view override returns (bool) {
        return _owners[id] == who && who != address(0);
    }

    // helpers
    function _validTick(int24 t) private pure returns (bool) {
        return
            t == DISABLED_TICK ||
            (t >= TickMath.MIN_TICK && t <= TickMath.MAX_TICK);
    }

    /// @dev Sanity-checks tick inputs.
    ///      – Each tick must be either DISABLED_TICK **or** within the Uni V3 range.
    ///      – At least **one** side must be enabled (avoids “zombie” orders).
    ///      – When both sides are enabled we still enforce tickBuy < tickSell.
    function _enforceTicks(int24 tickBuy, int24 tickSell) internal pure {
        // 1. Individual-tick bounds.
        if (!_validTick(tickBuy) || !_validTick(tickSell))
            revert BadTicksRange(tickBuy, tickSell);

        // 2. Disallow both sides disabled => untakeable order.
        if (tickBuy == DISABLED_TICK && tickSell == DISABLED_TICK)
            revert BothTicksDisabled(tickBuy, tickSell);

        // 3. If both enabled, maintain buy < sell invariant.
        if (
            tickBuy != DISABLED_TICK &&
            tickSell != DISABLED_TICK &&
            tickBuy >= tickSell
        ) revert BadTicks(tickBuy, tickSell);
    }
}
/*╚══════════════════════════  End of CLOB  ════════════════════════════*/

/*══════════════════════════════════════════════════════════════════════*\
│                         TickMath — Uniswap V3                         │
│  • getSqrtRatioAtTick: √(1.0001^tick) × 2^96 (Q64.96)                 │
│  • priceX64          : (√price)^2      →  Q64.64 (quote/base)         │
\*══════════════════════════════════════════════════════════════════════*/

library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

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
        require(
            absTick <= uint256(int256(MAX_TICK)), // cast int24 → int256 → uint256
            "T"
        );

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

    /// @notice Converts a Uniswap V3 tick to a fixed-point Q64.64 price
    ///         (token1 / token0, i.e. quote / base).
    /// @param  tick   Signed pool tick.
    /// @return priceX64_ Q64.64 price.
    function priceX64(int24 tick) internal pure returns (uint256 priceX64_) {
        uint160 sqrtX96 = getSqrtRatioAtTick(tick); // Q64.96
        uint256 r = uint256(sqrtX96); // widen
        priceX64_ = (r * r) >> 128; // Q64.64
        require(priceX64_ > 0, "price=0");
    }
}
