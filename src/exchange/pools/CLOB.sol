// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../IZRC20.sol";

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

    event Taken(
        address indexed taker,
        uint64 amountIn,
        uint64 amountOut,
        bool baseForQuote
    );

    struct Order {
        uint64 baseReserve;
        uint64 quoteReserve;
        int24 tickBuy; // MIN if not buying
        int24 tickSell; // MIN if not selling
    }

    struct TakeCommand {
        bool baseForQuote;
        uint64 amountIn;
        uint64 amountOut;
        uint64[] orderIds; // order ids to take
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

contract CLOB is ICLOB, ReentrancyGuard {
    IZRC20 private immutable _base;
    IZRC20 private immutable _quote;
    IZRC20 private immutable _discountToken;
    address private immutable _master;

    mapping(uint64 => ICLOB.Order) private _orders;
    mapping(uint64 => address) private _owners;
    uint64 private _nextOrderId = 1;

    constructor(
        IZRC20 assetA,
        IZRC20 assetB,
        IZRC20 discountToken,
        address master
    ) {
        require(
            address(assetA) != address(0) &&
                address(assetB) != address(0) &&
                address(discountToken) != address(0) &&
                master != address(0),
            "zero addr"
        );
        require(address(assetA) != address(assetB), "same asset");
        // sort the assets
        if (address(assetA) > address(assetB)) {
            (assetA, assetB) = (assetB, assetA);
        }
        _base = assetA;
        _quote = assetB;
        _discountToken = discountToken;
        _master = master;
    }

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
        returns (IZRC20 base, IZRC20 quote)
    {
        return (_base, _quote);
    }

    function getDiscountToken() external view override returns (IZRC20) {
        return _discountToken;
    }

    function getMaster() external view returns (address) {
        return _master;
    }

    /**
     * @notice Creates a new order and assigns ownership to `authority`.
     * @dev
     * ▸ Either reserve may be zero (pure-bid *or* pure-ask liquidity).
     * ▸ Tick‐range sanity: `tickBuy < tickSell` (spread must be positive).
     * ▸ Storage is **fully written before** the `OrderCreated` event is emitted
     *   so off-chain indexers never see a transient owner = 0 address.
     *
     * @param authority  The account that controls the order (passed down by router).
     * @param baseReserve  Initial base-asset liquidity committed to the order.
     * @param quoteReserve Initial quote-asset liquidity committed to the order.
     * @param tickBuy  Lower tick (boundary price) at which the order will buy base.
     * @param tickSell Upper tick (boundary price) at which the order will sell base.
     * @return orderId  Auto-incremented identifier of the freshly created order.
     */
    function createOrder(
        address authority,
        uint64 baseReserve,
        uint64 quoteReserve,
        int24 tickBuy,
        int24 tickSell
    ) internal returns (uint64 orderId) {
        require(authority != address(0), "owner-0");
        require(baseReserve > 0 || quoteReserve > 0, "zero-reserves");
        require(tickBuy < tickSell, "bad-ticks");

        orderId = _nextOrderId++;
        _orders[orderId] = ICLOB.Order({
            baseReserve: baseReserve,
            quoteReserve: quoteReserve,
            tickBuy: tickBuy,
            tickSell: tickSell
        });
        _owners[orderId] = authority; // storage first, then event

        emit ICLOB.OrderCreated(
            orderId,
            authority,
            baseReserve,
            quoteReserve,
            uint24(tickBuy),
            uint24(tickSell)
        );
    }

    /**
     * @notice Cancels an existing order and refunds its reserves.
     * @dev    Callable only by the designated owner (`authority`).
     *
     * @param authority  The caller-supplied owner address (router passes it through).
     * @param orderId    The order to cancel.
     * @return baseRecovered   Base-asset liquidity returned to the owner.
     * @return quoteRecovered  Quote-asset liquidity returned to the owner.
     */
    function cancelOrder(
        address authority,
        uint64 orderId
    ) internal returns (uint64 baseRecovered, uint64 quoteRecovered) {
        ICLOB.Order memory order = _orders[orderId];
        address owner = _owners[orderId];

        require(owner != address(0), "no-order");
        require(authority == owner, "not-owner");

        baseRecovered = order.baseReserve;
        quoteRecovered = order.quoteReserve;

        delete _orders[orderId];
        delete _owners[orderId];

        emit ICLOB.OrderCancelled(orderId, owner);
    }

    /**
     * @notice Replaces the parameters of an existing order, only in the
     *         *direction of improvement* (tighter spread and/or deeper reserves).
     * @dev
     * ▸ Deltas must be **funded later in the batch**; here we only update storage.
     * ▸ Addition on `uint64` is checked-arithmetic in 0.8+, so overflow reverts.
     *
     * @param authority          The owner asserting control of `orderId`.
     * @param orderId            Order to mutate in-place.
     * @param baseReserveDelta   Additional base liquidity to add (no negatives).
     * @param quoteReserveDelta  Additional quote liquidity to add (no negatives).
     * @param tickBuy            New lower tick (≤ old).
     * @param tickSell           New upper tick (≥ old).
     */
    function replaceOrder(
        address authority,
        uint64 orderId,
        uint64 baseReserveDelta,
        uint64 quoteReserveDelta,
        int24 tickBuy,
        int24 tickSell
    ) internal {
        ICLOB.Order storage order = _orders[orderId];
        address owner = _owners[orderId];

        require(owner != address(0), "no-order");
        require(authority == owner, "not-owner");

        uint64 newBase = order.baseReserve + baseReserveDelta; // reverts on ovf
        uint64 newQuote = order.quoteReserve + quoteReserveDelta; // reverts on ovf
        require(newBase > 0 || newQuote > 0, "zero-reserves");
        require(tickBuy < tickSell, "bad-ticks");
        require(
            tickBuy <= order.tickBuy && tickSell >= order.tickSell,
            "worse-ticks"
        );

        order.baseReserve = newBase;
        order.quoteReserve = newQuote;
        order.tickBuy = tickBuy;
        order.tickSell = tickSell;
        // emit event
        emit ICLOB.OrderReplaced(
            orderId,
            owner,
            newBase,
            newQuote,
            uint24(tickBuy),
            uint24(tickSell)
        );
    }

    /**
     * @notice Batch-process a maker’s order instructions, returning the **net**
     *         liquidity delta without moving any tokens.  The router that
     *         invoked this call is responsible for settling the result with a
     *         single `transfer{From}` per asset, so the maker only needs one
     *         approval per token.
     *
     * @dev Implementation rules & assumptions
     * ───────────────────────────────────────
     * • `auth` is the maker’s EOA whose authority the router asserts.
     * • `msg.sender` **must** be the trusted router (`_master`); the book never
     *   interacts with arbitrary callers.
     * • Positive return values ⇒ CLOB owes the maker a refund (router will
     *   pull funds *out* of the book).
     *   Negative return values ⇒ maker must supply additional liquidity
     *   (router will push funds *into* the book).
     * • Uses `int256` accumulators to eliminate overflow risk on whale batches.
     * • Helper functions (`createOrder`, `replaceOrder`, `cancelOrder`) enforce
     *   all per-order invariants (ownership, tick sanity, reserve > 0, etc.).
     *
     * @param  auth       Maker address, trusted and verified by the router.
     * @param  commands   Sequence of create / replace / cancel directives.
     * @return netBase    Signed net change of base-asset liquidity.
     * @return netQuote   Signed net change of quote-asset liquidity.
     */
    function makeFrom(
        address auth,
        ICLOB.MakeCommand[] calldata commands
    ) external override nonReentrant returns (int256 netBase, int256 netQuote) {
        require(msg.sender == _master, "router-only");

        /* Running signed totals:   +ve → refund,  -ve → additional deposit. */
        int256 baseDelta;
        int256 quoteDelta;

        uint256 len = commands.length;
        for (uint256 i; i < len; ++i) {
            /* Calldata pointer stays cheap; no copy to memory needed.        */
            ICLOB.MakeCommand calldata cmd = commands[i];

            /* ───────────────── Replace (cancel + create) ───────────────── */
            if (cmd.cancel.id != 0 && cmd.create.owner != address(0)) {
                replaceOrder(
                    auth,
                    cmd.cancel.id,
                    cmd.create.baseReserveDelta,
                    cmd.create.quoteReserveDelta,
                    cmd.create.tickBuy,
                    cmd.create.tickSell
                );
                baseDelta -= int256(uint256(cmd.create.baseReserveDelta));
                quoteDelta -= int256(uint256(cmd.create.quoteReserveDelta));

                /* ───────────────────── Pure cancel ─────────────────────────── */
            } else if (cmd.cancel.id != 0) {
                (uint64 br, uint64 qr) = cancelOrder(auth, cmd.cancel.id);
                baseDelta += int256(uint256(br));
                quoteDelta += int256(uint256(qr));

                /* ───────────────────── Pure create ─────────────────────────── */
            } else if (cmd.create.owner != address(0)) {
                createOrder(
                    auth,
                    cmd.create.baseReserveDelta,
                    cmd.create.quoteReserveDelta,
                    cmd.create.tickBuy,
                    cmd.create.tickSell
                );
                baseDelta -= int256(uint256(cmd.create.baseReserveDelta));
                quoteDelta -= int256(uint256(cmd.create.quoteReserveDelta));

                /* ───────────────────── Bad tuple ───────────────────────────── */
            } else {
                revert("bad-command");
            }
        }

        /* Return the signed totals to the router for settlement. */
        return (baseDelta, quoteDelta);
    }

    /**
     * @notice Fills **one** maker order and returns *signed* deltas that the
     *         router can net across multiple calls before doing any ERC-20
     *         transfers.  The function supports both **exact-in** and **exact-out**
     *         semantics, decided by the `exactIn` flag.
     *
     * Swap directions
     * ───────────────
     * • `baseForQuote == true`   →  taker *sells base*, receives quote
     * • `baseForQuote == false`  →  taker *sells quote*, receives base
     *
     * Amount interpretation
     * ─────────────────────
     * • `exactIn  == true`  →  `amountSpecified` is the taker’s **input** amount
     * • `exactIn  == false` →  `amountSpecified` is the taker’s **desired output**
     *
     * Returned deltas (signed)
     * ────────────────────────
     * • `netBase`  > 0  →  router must **pull** that many base tokens *into* CLOB
     *             < 0  →  router must **push** that many base tokens *out* of CLOB
     * • `netQuote` same convention for quote tokens
     *
     * @param orderId          Maker order to hit (no-op if it doesn’t exist).
     * @param baseForQuote     Swap side flag (see table above).
     * @param amountSpecified  Exact-in amount *or* exact-out amount, per `exactIn`.
     * @param exactIn          Swap mode selector.
     *
     * @return netBase   Signed base-token delta for router settlement.
     * @return netQuote  Signed quote-token delta for router settlement.
     * @return gotBase   Actual base tokens that changed hands.
     * @return gotQuote  Actual quote tokens that changed hands.
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
        require(msg.sender == _master, "router-only");
        
        /* Fast-exit for unknown or empty orders. */
        address maker = _owners[orderId];
        if (maker == address(0) || amountSpecified == 0) return (0, 0, 0, 0);

        ICLOB.Order storage o = _orders[orderId];

        /* ───── Direction: taker sells base → receives quote ───── */
        if (baseForQuote) {
            uint256 priceX64 = TickMath.priceX64(o.tickBuy); // quote / base
            require(priceX64 > 0, "buy-disabled");

            if (exactIn) {
                /* exact-in: amountSpecified = baseIn */
                uint64 baseIn = amountSpecified;

                /* Maximum quote we could pay at this price */
                uint256 maxQuote = (uint256(baseIn) * priceX64) >> 64;
                if (maxQuote == 0 || o.quoteReserve == 0) return (0, 0, 0, 0);

                uint64 quoteOut = maxQuote <= o.quoteReserve
                    ? uint64(maxQuote)
                    : o.quoteReserve; // partial if not enough quote

                /* Mutate reserves */
                o.baseReserve += baseIn;
                o.quoteReserve -= quoteOut;

                /* Signed deltas for the router */
                netBase = int256(uint256(baseIn)); // router must pull IN base
                netQuote = -int256(uint256(quoteOut)); // router must pay OUT quote

                gotBase = baseIn;
                gotQuote = quoteOut;
            } else {
                /* exact-out: amountSpecified = quote desired */
                uint64 quoteWant = amountSpecified;
                if (o.quoteReserve == 0) return (0, 0, 0, 0);

                uint64 quoteOut = quoteWant <= o.quoteReserve
                    ? quoteWant
                    : o.quoteReserve; // partial if not enough quote

                /* base needed, ceil-division */
                uint256 needBase = ((uint256(quoteOut) << 64) + priceX64 - 1) /
                    priceX64;

                require(
                    needBase > 0 &&
                        needBase <= type(uint64).max &&
                        o.baseReserve + needBase <= type(uint64).max,
                    "ovf"
                );

                o.baseReserve += uint64(needBase);
                o.quoteReserve -= quoteOut;

                netBase = int256(needBase); // pull IN base
                netQuote = -int256(uint256(quoteOut)); // pay OUT quote

                gotBase = uint64(needBase);
                gotQuote = quoteOut;
            }

            emit ICLOB.OrderFilled(orderId, maker, gotBase, gotQuote, true);

            /* ───── Direction: taker sells quote → receives base ───── */
        } else {
            uint256 priceX64 = TickMath.priceX64(o.tickSell); // quote / base
            require(priceX64 > 0, "sell-disabled");

            if (exactIn) {
                /* exact-in: amountSpecified = quoteIn */
                uint64 quoteIn_ = amountSpecified;

                uint64 baseOut = uint64((uint256(quoteIn_) << 64) / priceX64);
                if (baseOut == 0 || o.baseReserve == 0) return (0, 0, 0, 0);

                if (baseOut > o.baseReserve) {
                    /* Partial fill, scale quoteIn down to max possible */
                    baseOut = o.baseReserve;
                    quoteIn_ = uint64((uint256(baseOut) * priceX64) >> 64);
                }

                o.quoteReserve += quoteIn_;
                o.baseReserve -= baseOut;

                netBase = -int256(uint256(baseOut)); // pay OUT base
                netQuote = int256(uint256(quoteIn_)); // pull IN quote

                gotBase = baseOut;
                gotQuote = quoteIn_;
            } else {
                /* exact-out: amountSpecified = base desired */
                uint64 baseWant = amountSpecified;
                if (o.baseReserve == 0) return (0, 0, 0, 0);

                uint64 baseOut = baseWant <= o.baseReserve
                    ? baseWant
                    : o.baseReserve;

                uint256 needQuote = (uint256(baseOut) * priceX64) >> 64;
                require(
                    needQuote > 0 &&
                        needQuote <= type(uint64).max &&
                        o.quoteReserve + needQuote <= type(uint64).max,
                    "ovf"
                );

                o.quoteReserve += uint64(needQuote);
                o.baseReserve -= baseOut;

                netBase = -int256(uint256(baseOut)); // pay OUT base
                netQuote = int256(needQuote); // pull IN quote

                gotBase = baseOut;
                gotQuote = uint64(needQuote);
            }

            emit ICLOB.OrderFilled(orderId, maker, gotQuote, gotBase, false);
        }
    }

    /**
     * @notice “What-if” version of `takeFrom` that touches **no** storage and
     *         performs **no** ERC-20 transfers.  It tells the router how many
     *         tokens would move if this exact swap were executed right now.
     *
     * Parameters mirror `takeFrom`
     * ────────────────────────────
     * • `orderId`        – maker order to hit (silently ignored if missing).
     * • `baseForQuote`   – `true`  ⇒ taker sells base, receives quote
     *                       `false` ⇒ taker sells quote, receives base
     * • `amountSpecified`– exact amount on the *taker* side (see `exactIn`).
     * • `exactIn`        – `true`  ⇒ `amountSpecified` is the **input** amount
     *                       `false` ⇒ `amountSpecified` is the **desired output**.
     *
     * Return values
     * ─────────────
     * • `netBase`, `netQuote` – signed deltas for router-level netting
     *   (>0 pull-in, <0 pay-out; 0 means no movement for that asset).
     * • `gotBase`, `gotQuote` – gross token amounts that would actually change
     *   hands (taker-perspective).  Helpful for detecting partial fills.
     *
     * The function never reverts for “missing order”, “side disabled”, or
     * “insufficient liquidity”; it just returns zeros so callers can probe
     * without risk.
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
        /* Short-circuit for bad inputs or unknown order */
        if (amountSpecified == 0 || _owners[orderId] == address(0)) {
            return (0, 0, 0, 0);
        }

        ICLOB.Order storage o = _orders[orderId];

        /* ─────── taker sells base, receives quote ─────── */
        if (baseForQuote) {
            /* side disabled? → no-op */
            if (o.quoteReserve == 0 || o.tickBuy == TickMath.MIN_TICK) {
                return (0, 0, 0, 0);
            }

            uint256 priceX64 = TickMath.priceX64(o.tickBuy); // quote / base

            if (exactIn) {
                /* amountSpecified = baseIn */
                uint64 baseIn = amountSpecified;

                uint256 maxQuote = (uint256(baseIn) * priceX64) >> 64;
                if (maxQuote == 0) return (0, 0, 0, 0);

                uint64 quoteOut = maxQuote <= o.quoteReserve
                    ? uint64(maxQuote)
                    : o.quoteReserve; // partial

                /* compose deltas */
                netBase = int256(uint256(baseIn)); // pull base IN
                netQuote = -int256(uint256(quoteOut)); // pay quote OUT
                gotBase = baseIn;
                gotQuote = quoteOut;
            } else {
                /* amountSpecified = quote desired (exact-out) */
                uint64 quoteWant = amountSpecified;
                uint64 quoteOut = quoteWant <= o.quoteReserve
                    ? quoteWant
                    : o.quoteReserve; // partial

                uint256 needBase = ((uint256(quoteOut) << 64) + priceX64 - 1) /
                    priceX64; // ceil

                netBase = int256(needBase);
                netQuote = -int256(uint256(quoteOut));
                gotBase = uint64(needBase);
                gotQuote = quoteOut;
            }

            /* ─────── taker sells quote, receives base ─────── */
        } else {
            if (o.baseReserve == 0 || o.tickSell == TickMath.MIN_TICK) {
                return (0, 0, 0, 0);
            }

            uint256 priceX64 = TickMath.priceX64(o.tickSell); // quote / base

            if (exactIn) {
                /* amountSpecified = quoteIn */
                uint64 quoteIn_ = amountSpecified;

                uint64 baseOut = uint64((uint256(quoteIn_) << 64) / priceX64);
                if (baseOut == 0) return (0, 0, 0, 0);

                if (baseOut > o.baseReserve) {
                    baseOut = o.baseReserve; // partial
                    quoteIn_ = uint64((uint256(baseOut) * priceX64) >> 64);
                }

                netBase = -int256(uint256(baseOut)); // pay base OUT
                netQuote = int256(uint256(quoteIn_)); // pull quote IN
                gotBase = baseOut;
                gotQuote = quoteIn_;
            } else {
                /* amountSpecified = base desired (exact-out) */
                uint64 baseWant = amountSpecified;
                uint64 baseOut = baseWant <= o.baseReserve
                    ? baseWant
                    : o.baseReserve;

                uint256 needQuote = (uint256(baseOut) * priceX64) >> 64;

                netBase = -int256(uint256(baseOut));
                netQuote = int256(needQuote);
                gotBase = baseOut;
                gotQuote = uint64(needQuote);
            }
        }
    }

    /**
     * @notice Batch-fetch the buy-side and sell-side prices for a list of orders.
     *
     * @dev
     * • Each price is returned as a Q64.64 fixed-point number (quote / base).
     * • Missing orders or disabled sides (tick == MIN_TICK) return **0**.
     * • The two returned arrays always have the same length as `orderIds`,
     *   indexed 1-for-1 with the input.
     *
     * @param  orderIds        Array of maker-order IDs.
     * @return buyPricesX64    Q64.64 prices at which each order *buys* base.
     * @return sellPricesX64   Q64.64 prices at which each order *sells* base.
     */
    function getPrices(
        uint64[] calldata orderIds
    )
        external
        view
        returns (uint256[] memory buyPricesX64, uint256[] memory sellPricesX64)
    {
        uint256 n = orderIds.length;
        buyPricesX64 = new uint256[](n);
        sellPricesX64 = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            uint64 id = orderIds[i];
            address owner = _owners[id];
            if (owner == address(0)) continue; // order missing → 0,0

            ICLOB.Order storage o = _orders[id];

            if (o.tickBuy != TickMath.MIN_TICK) {
                buyPricesX64[i] = TickMath.priceX64(o.tickBuy); // may be 0 if tickBuy sentinel
            }
            if (o.tickSell != TickMath.MIN_TICK) {
                sellPricesX64[i] = TickMath.priceX64(o.tickSell); // 0 if tickSell sentinel
            }
        }
    }

    function getOrders(
        uint64[] calldata orderIds
    ) external view override returns (Order[] memory) {
        uint256 n = orderIds.length;
        Order[] memory orders = new Order[](n);
        for (uint256 i; i < n; ++i) {
            uint64 id = orderIds[i];
            address owner = _owners[id];
            if (owner != address(0)) {
                orders[i] = _orders[id];
            } else {
                orders[i] = Order({
                    baseReserve: 0,
                    quoteReserve: 0,
                    tickBuy: TickMath.MIN_TICK,
                    tickSell: TickMath.MIN_TICK
                });
            }
        }
        return orders;
    }

    function isOwner(
        uint64 orderId,
        address owner
    ) external view override returns (bool) {
        address actual = _owners[orderId];
        return actual != address(0) && actual == owner;
    }
}

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
