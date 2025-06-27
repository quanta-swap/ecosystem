// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────
│  ReserveDEX v1.1.0                                             │
│  • Single‑reserve constant‑product AMM with 64‑bit ZRC‑20s      │
│  • Daily‑locked FREE‑token fee rebate (0–100 %)                 │
│  • 10‑minute TWAP oracle (24‑slot ring ⇒ 4 h window)           │
│  • Safe‑math via 0.8.x built‑ins + explicit range checks       │
│  • Fully deterministic, single‑entry re‑entrancy guard          │
└───────────────────────────────────────────────────────────────*/

import {IZRC20} from "./IZRC20.sol";

/**
 * @dev FREE token must expose `lock()` so ReserveDEX can freeze a user’s
 * already‑held FREE in‑wallet for the rest of the UTC day (simple fee rebate).
 */
interface IFreeTradeToken is IZRC20 {
    function lock(address account, uint64 amount) external;
}

/*──────────────── Re‑entrancy guard (2‑state, gas‑minified) ───────────────*/
abstract contract ReentrancyGuard {
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;
    uint8 private _status = _NOT_ENTERED;
    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "reenter");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface IReserveDEX {
    function RESERVE() external view returns (IZRC20);

    /* liquidity */
    function addLiquidity(
        address token,
        uint64  reserveDesired,
        uint64  tokenDesired
    ) external returns (uint128 shares, uint64 reserveUsed, uint64 tokenUsed);

    function removeLiquidity(
        address token,
        uint128 shares
    ) external returns (uint64 reserveOut, uint64 tokenOut);

    /* swap: RESERVE → token (fee paid in RESERVE) */
    function swapReserveForToken(
        address token,
        uint64  amountIn,
        uint64  minOut,
        address to,
        uint64 freeAmt
    ) external returns (uint64 amountOut);

    /*──────────────────── VIEW-ONLY SIMULATION ───────────────────*/
    function simulateReserveForToken(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);

    function simulateTokenForReserve(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);

    function simulateTokenForToken(
        address tokenFrom,
        address tokenTo,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 amountOut);
}

contract KRIEGSMARINE is ReentrancyGuard, IReserveDEX {
    /*──────────────────── IMMUTABLES ────────────────────*/
    IZRC20 public immutable RESERVE; // reserve asset (e.g. wrapped native)
    IFreeTradeToken public immutable FREE; // fee‑rebate token
    uint64 public immutable FULL_FREE; // 1.0 FREE scaled to uint64

    /*───────────── FEE CONSTANTS (0.30 % base) ───────────*/
    uint64 private constant _FEE_DEN = 1000; // denominator (basis‑points style)
    uint64 private constant _FEE_NUM_0 = 997; // numerator at 0 FREE locked (0.30 %)
    uint64 private constant _FEE_SPAN = _FEE_DEN - _FEE_NUM_0; // 3 → full rebate range

    /*───────────── ORACLE CONSTANTS (10 min ×24) ─────────*/
    uint32 private constant _OBS_PERIOD = 10 minutes;
    uint8 private constant _OBS_SIZE = 24; // 4 h time‑weighted window

    /*────────────────── POOL / ORACLE STORAGE ─────────────*/
    struct Pool {
        uint64 reserveR; // RESERVE side
        uint64 reserveT; // token side (non‑reserve token)
        uint128 totalLiq; // LP shares (≠0 → pool live)
        uint256 priceCum; // ∑ (reserveR <<64 / reserveT) · dt
        uint64 lastTs; // last cumulative update timestamp
    }

    struct Obs {
        uint64 ts;
        uint256 priceCum;
    } // ring‑buffer entry

    mapping(address token => Pool) private pools;
    mapping(address token => mapping(address lp => uint128)) public liqOf; // LP shares
    mapping(address token => Obs[_OBS_SIZE]) private _obs;
    mapping(address token => uint8) private _obsIdx; // newest index
    mapping(address token => uint64) private _lastSnap; // last snapshot ts

    /*──────────────────────── EVENTS ─────────────────────*/
    event AddLiquidity(
        address indexed provider,
        address indexed token,
        uint64 reserveIn,
        uint64 tokenIn,
        uint128 shares
    );
    event RemoveLiquidity(
        address indexed provider,
        address indexed token,
        uint64 reserveOut,
        uint64 tokenOut,
        uint128 shares
    );
    event Swap(
        address indexed trader,
        address indexed token,
        bool reserveToToken,
        uint64 amountIn,
        uint64 amountOut
    );
    event OracleSnap(address indexed token, uint64 timestamp, uint256 priceCum);

    /*────────────────────── CONSTRUCTOR ──────────────────*/
    constructor(IZRC20 reserveToken, IFreeTradeToken freeToken) {
        require(
            address(reserveToken) != address(0) &&
                address(freeToken) != address(0),
            "zero addr"
        );
        uint8 dec = freeToken.decimals();
        require(dec <= 18, "FREE decimals >18");
        RESERVE = reserveToken;
        FREE = freeToken;
        FULL_FREE = uint64(10 ** dec); // fits because dec ≤18 → 1e18 < 2^64
    }

    // "FEE... FIE! FOE!! FUM!!!"
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=et-VRZoChLY";
    }

    /*=====================================================================
                                VIEW HELPERS
    =====================================================================*/
    function getReserves(
        address token
    ) external view returns (uint64 reserveR, uint64 reserveT) {
        Pool storage p = pools[token];
        return (p.reserveR, p.reserveT);
    }

    function getLiquidity(
        address token,
        address provider
    )
        external
        view
        returns (uint64 reserveAmt, uint64 tokenAmt, uint128 shares)
    {
        Pool storage p = pools[token];
        uint128 tot = p.totalLiq;
        require(tot > 0, "empty pool");
        shares = liqOf[token][provider];
        if (shares == 0) return (0, 0, 0);
        reserveAmt = uint64((uint256(p.reserveR) * shares) / tot);
        tokenAmt = uint64((uint256(p.reserveT) * shares) / tot);
    }

    /*──────────────────── INTERNAL HELPERS ───────────────────*/
    function _pull(IZRC20 t, address from, uint64 amt) private {
        if (amt == 0) return; // skip gas
        require(t.transferFrom(from, address(this), amt), "pull fail");
    }

    function _push(IZRC20 t, address to, uint64 amt) private {
        if (amt == 0) return;
        require(t.transfer(to, amt), "push fail");
    }

    /* Babylonian sqrt (uint256 → uint128, rounds down) */
    function _sqrt(uint256 y) private pure returns (uint128 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = uint128(y);
        uint128 k = uint128((x + 1) >> 1);
        while (k < z) {
            z = k;
            k = uint128((x / k + k) >> 1);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /*──────────── Fee‑numerator given locked FREE────────────*/
    function _feeNum(uint64 freeAmt) private view returns (uint64) {
        if (freeAmt == 0) return _FEE_NUM_0;
        require(freeAmt <= FULL_FREE, "free > 1");
        unchecked {
            return
                _FEE_NUM_0 + uint64((_FEE_SPAN * uint256(freeAmt)) / FULL_FREE);
        }
    }

    /* Lock FREE tokens in‑wallet for rest of current UTC day */
    function _applyFree(address trader, uint64 amt) private {
        if (amt == 0) return;
        FREE.lock(trader, amt); // reverts on insufficient balance / already locked
    }

    /*──────────── AMM math with variable fee ‑ R→T ───────────*/
    function _outRtoT(
        uint64 amtIn,
        uint64 resIn,
        uint64 resOut,
        uint64 feeN
    ) private pure returns (uint64 out) {
        // out = amtIn*feeN*resOut / (resIn*den + amtIn*feeN)
        uint256 inFee = uint256(amtIn) * feeN;
        uint256 num = inFee * resOut;
        uint256 den = uint256(resIn) * _FEE_DEN + inFee;
        out = uint64(num / den);
        require(out > 0 && out <= resOut, "out range");
    }

    /*──────────── AMM math with variable fee ‑ T→R ───────────*/
    function _outTtoR(
        uint64 amtIn,
        uint64 resR,
        uint64 resT,
        uint64 feeN
    ) private pure returns (uint64 out) {
        // grossOut = amtIn * resR / (resT + amtIn)
        uint256 gross = (uint256(amtIn) * resR) / (resT + amtIn);
        out = uint64((gross * feeN) / _FEE_DEN);
        require(out > 0 && out <= resR, "out range");
    }

    /*=====================================================================
                        ORACLE – CUMULATIVE PRICE
    =====================================================================*/
    function _updateCumulative(address /* token */, Pool storage p) private {
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = p.lastTs;
        if (last != 0 && nowTs > last && p.reserveT > 0) {
            uint256 priceQ64 = (uint256(p.reserveR) << 64) / p.reserveT;
            unchecked {
                p.priceCum += priceQ64 * (nowTs - last);
            }
        }
        p.lastTs = nowTs;
    }

    function _maybeSnap(address token, Pool storage p) private {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs - _lastSnap[token] >= _OBS_PERIOD) {
            uint8 idx = (_obsIdx[token] + 1) % _OBS_SIZE;
            _obs[token][idx] = Obs(nowTs, p.priceCum);
            _obsIdx[token] = idx;
            _lastSnap[token] = nowTs;
            emit OracleSnap(token, nowTs, p.priceCum);
        }
    }

    /* keeper‑optional */
    function pokeOracle(address token) external {
        Pool storage p = pools[token];
        _updateCumulative(token, p);
        _maybeSnap(token, p);
    }

    /*=====================================================================
                           LIQUIDITY MANAGEMENT
    =====================================================================*/
    function addLiquidity(
        address token,
        uint64 reserveDesired,
        uint64 tokenDesired
    )
        external
        nonReentrant
        returns (uint128 shares, uint64 reserveUsed, uint64 tokenUsed)
    {
        require(token != address(0) && token != address(RESERVE), "token bad");
        require(reserveDesired > 0 && tokenDesired > 0, "zero add");

        Pool storage p = pools[token];
        _updateCumulative(token, p);

        _pull(RESERVE, msg.sender, reserveDesired);
        _pull(IZRC20(token), msg.sender, tokenDesired);

        if (p.totalLiq > 0) {
            uint256 rNeed = (uint256(p.reserveR) * tokenDesired) / p.reserveT;
            if (rNeed <= reserveDesired) {
                reserveUsed = uint64(rNeed);
                tokenUsed = tokenDesired;
            } else {
                reserveUsed = reserveDesired;
                tokenUsed = uint64(
                    (uint256(p.reserveT) * reserveDesired) / p.reserveR
                );
            }
        } else {
            reserveUsed = reserveDesired;
            tokenUsed = tokenDesired;
        }

        /* refund un‑matched amounts */
        if (reserveUsed < reserveDesired)
            _push(RESERVE, msg.sender, reserveDesired - reserveUsed);
        if (tokenUsed < tokenDesired)
            _push(IZRC20(token), msg.sender, tokenDesired - tokenUsed);

        if (p.totalLiq == 0) {
            shares = _sqrt(uint256(reserveUsed) * tokenUsed);
            require(shares >= 1_000, "init dust");
        } else {
            shares = uint128(
                _min(
                    (uint256(reserveUsed) * p.totalLiq) / p.reserveR,
                    (uint256(tokenUsed) * p.totalLiq) / p.reserveT
                )
            );
        }
        require(shares > 0, "no shares");

        /* mutate pool */
        p.reserveR += reserveUsed;
        p.reserveT += tokenUsed;
        p.totalLiq += shares;
        liqOf[token][msg.sender] += shares;

        /* bootstrap first observation */
        if (_lastSnap[token] == 0) {
            uint64 ts = uint64(block.timestamp);
            _obs[token][0] = Obs(ts, p.priceCum);
            _obsIdx[token] = 0;
            _lastSnap[token] = ts;
            emit OracleSnap(token, ts, p.priceCum);
        }

        _maybeSnap(token, p);
        emit AddLiquidity(msg.sender, token, reserveUsed, tokenUsed, shares);
    }

    function removeLiquidity(
        address token,
        uint128 shares
    ) external nonReentrant returns (uint64 reserveOut, uint64 tokenOut) {
        require(shares > 0, "zero shares");
        Pool storage p = pools[token];
        require(p.totalLiq > 0, "empty");

        uint128 userShares = liqOf[token][msg.sender];
        require(shares <= userShares, "exceeds");

        _updateCumulative(token, p);

        reserveOut = uint64((uint256(p.reserveR) * shares) / p.totalLiq);
        tokenOut = uint64((uint256(p.reserveT) * shares) / p.totalLiq);
        require(reserveOut > 0 && tokenOut > 0, "dust out");

        p.reserveR -= reserveOut;
        p.reserveT -= tokenOut;
        p.totalLiq -= shares;
        liqOf[token][msg.sender] = userShares - shares;

        _push(RESERVE, msg.sender, reserveOut);
        _push(IZRC20(token), msg.sender, tokenOut);

        _maybeSnap(token, p);
        emit RemoveLiquidity(msg.sender, token, reserveOut, tokenOut, shares);
    }

    /*=====================================================================
                         INTERNAL SWAP CORE (shared)
    =====================================================================*/
    function _swapRtoT(
        address token,
        address from,
        address to,
        uint64 amtIn,
        uint64 minOut,
        uint64 freeAmt
    ) private returns (uint64 out) {
        Pool storage p = pools[token];
        require(p.reserveR > 0 && p.reserveT > 0, "empty pool");

        _updateCumulative(token, p);
        uint64 feeN = _feeNum(freeAmt);
        _applyFree(from, freeAmt);

        out = _outRtoT(amtIn, p.reserveR, p.reserveT, feeN);
        require(out >= minOut, "slippage");

        _pull(RESERVE, from, amtIn); // external call before state‑mutate prevents sandwich
        p.reserveR += amtIn;
        p.reserveT -= out;

        _maybeSnap(token, p);
        _push(IZRC20(token), to, out);
        emit Swap(from, token, true, amtIn, out);
    }

    function _swapTtoR(
        address token,
        address from,
        address to,
        uint64 amtIn,
        uint64 minOut,
        uint64 freeAmt
    ) private returns (uint64 out) {
        Pool storage p = pools[token];
        require(p.reserveR > 0 && p.reserveT > 0, "empty pool");

        _updateCumulative(token, p);
        uint64 feeN = _feeNum(freeAmt);
        _applyFree(from, freeAmt);

        out = _outTtoR(amtIn, p.reserveR, p.reserveT, feeN);
        require(out >= minOut, "slippage");

        _pull(IZRC20(token), from, amtIn);
        p.reserveT += amtIn;
        p.reserveR -= out;

        _maybeSnap(token, p);
        _push(RESERVE, to, out);
        emit Swap(from, token, false, amtIn, out);
    }

    /*=====================================================================
                                PUBLIC SWAPS
    =====================================================================*/
    function swapReserveForToken(
        address token,
        uint64 amountIn,
        uint64 minOut,
        address to,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(
            token != address(0) &&
                token != address(RESERVE) &&
                amountIn > 0 &&
                to != address(0),
            "bad args"
        );
        out = _swapRtoT(token, msg.sender, to, amountIn, minOut, freeAmt);
    }

    function swapTokenForReserve(
        address token,
        uint64 amountIn,
        uint64 minOut,
        address to,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(
            token != address(0) &&
                token != address(RESERVE) &&
                amountIn > 0 &&
                to != address(0),
            "bad args"
        );
        out = _swapTtoR(token, msg.sender, to, amountIn, minOut, freeAmt);
    }

    /*────────── Delegated versions: pulls from `walletFrom`, pays `payWallet` ─────────*/
    function tradeReserveForToken(
        address walletFrom,
        address token,
        uint64 amountIn,
        uint64 minOut,
        address payWallet,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(walletFrom != address(0) && payWallet != address(0), "addr");
        require(
            token != address(0) && token != address(RESERVE) && amountIn > 0,
            "bad args"
        );
        out = _swapRtoT(
            token,
            walletFrom,
            payWallet,
            amountIn,
            minOut,
            freeAmt
        );
    }

    function tradeTokenForReserve(
        address walletFrom,
        address token,
        uint64 amountIn,
        uint64 minOut,
        address payWallet,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(walletFrom != address(0) && payWallet != address(0), "addr");
        require(
            token != address(0) && token != address(RESERVE) && amountIn > 0,
            "bad args"
        );
        out = _swapTtoR(
            token,
            walletFrom,
            payWallet,
            amountIn,
            minOut,
            freeAmt
        );
    }

    /*──────────────────────── TOKEN ↔ TOKEN (single FREE lock) ───────────────*/
    function swapTokenForToken(
        address tokenFrom,
        address tokenTo,
        uint64 amountIn,
        uint64 minOut,
        address to,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(
            tokenFrom != address(0) &&
                tokenTo != address(0) &&
                tokenFrom != tokenTo &&
                tokenFrom != address(RESERVE) &&
                tokenTo != address(RESERVE) &&
                amountIn > 0 &&
                to != address(0),
            "bad args"
        );

        uint64 feeN = _feeNum(freeAmt);
        _applyFree(msg.sender, freeAmt);

        /* hop‑1: tokenFrom → RESERVE */
        Pool storage pA = pools[tokenFrom];
        require(pA.reserveR > 0 && pA.reserveT > 0, "empty A");
        _updateCumulative(tokenFrom, pA);
        uint64 reserveGot = _outTtoR(amountIn, pA.reserveR, pA.reserveT, feeN);
        _pull(IZRC20(tokenFrom), msg.sender, amountIn);
        pA.reserveT += amountIn;
        pA.reserveR -= reserveGot;
        _maybeSnap(tokenFrom, pA);
        emit Swap(msg.sender, tokenFrom, false, amountIn, reserveGot);

        /* hop‑2: RESERVE → tokenTo */
        Pool storage pB = pools[tokenTo];
        require(pB.reserveR > 0 && pB.reserveT > 0, "empty B");
        _updateCumulative(tokenTo, pB);
        out = _outRtoT(reserveGot, pB.reserveR, pB.reserveT, feeN);
        require(out >= minOut, "slippage");
        pB.reserveR += reserveGot;
        pB.reserveT -= out;
        _maybeSnap(tokenTo, pB);
        _push(IZRC20(tokenTo), to, out);
        emit Swap(msg.sender, tokenTo, true, reserveGot, out);
    }

    /* delegated variant */
    function tradeTokenForToken(
        address walletFrom,
        address tokenFrom,
        address tokenTo,
        uint64 amountIn,
        uint64 minOut,
        address payWallet,
        uint64 freeAmt
    ) external nonReentrant returns (uint64 out) {
        require(walletFrom != address(0) && payWallet != address(0), "addr");
        require(
            tokenFrom != address(0) &&
                tokenTo != address(0) &&
                tokenFrom != tokenTo &&
                tokenFrom != address(RESERVE) &&
                tokenTo != address(RESERVE) &&
                amountIn > 0,
            "bad args"
        );

        uint64 feeN = _feeNum(freeAmt);
        _applyFree(walletFrom, freeAmt);

        /* hop‑1 */
        Pool storage pA = pools[tokenFrom];
        require(pA.reserveR > 0 && pA.reserveT > 0, "empty A");
        _updateCumulative(tokenFrom, pA);
        uint64 reserveGot = _outTtoR(
            amountIn,
            pA.reserveR,
            pA.reserveT,
            feeN
        );
        _pull(IZRC20(tokenFrom), walletFrom, amountIn);
        pA.reserveT += amountIn;
        pA.reserveR -= reserveGot;
        _maybeSnap(tokenFrom, pA);
        emit Swap(walletFrom, tokenFrom, false, amountIn, reserveGot);

        /* hop‑2 */
        Pool storage pB = pools[tokenTo];
        require(pB.reserveR > 0 && pB.reserveT > 0, "empty B");
        _updateCumulative(tokenTo, pB);
        out = _outRtoT(reserveGot, pB.reserveR, pB.reserveT, feeN);
        require(out >= minOut, "slippage");
        pB.reserveR += reserveGot;
        pB.reserveT -= out;
        _maybeSnap(tokenTo, pB);
        _push(IZRC20(tokenTo), payWallet, out);
        emit Swap(walletFrom, tokenTo, true, reserveGot, out);
    }

    /*=====================================================================
                            VIEW-ONLY SIMULATION
    ======================================================================*/
    /**
     * @notice Quote how much `token` you’d get for a given RESERVE input.
     * @param token      Non-reserve token address (pool must exist)
     * @param amountIn   RESERVE amount offered
     * @param freeAmt    FREE you intend to lock (0–FULL_FREE)
     * @return out       Expected token output (after fees)
     */
    function simulateReserveForToken(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 out) {
        Pool storage p = pools[token];
        require(p.reserveR > 0 && p.reserveT > 0, "empty pool");
        uint64 feeN = _feeNum(freeAmt); // same rebate curve
        out = _outRtoT(amountIn, p.reserveR, p.reserveT, feeN);
    }

    /**
     * @notice Quote how much RESERVE you’d get for a given `token` input.
     */
    function simulateTokenForReserve(
        address token,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 out) {
        Pool storage p = pools[token];
        require(p.reserveR > 0 && p.reserveT > 0, "empty pool");
        uint64 feeN = _feeNum(freeAmt);
        out = _outTtoR(amountIn, p.reserveR, p.reserveT, feeN);
    }

    /**
     * @notice Quote TOKEN-for-TOKEN output via the RESERVE hop
     *         (identical fee logic to `swapTokenForToken`).
     * @return out  Final `tokenTo` amount you’d receive
     */
    function simulateTokenForToken(
        address tokenFrom,
        address tokenTo,
        uint64 amountIn,
        uint64 freeAmt
    ) external view returns (uint64 out) {
        require(
            tokenFrom != address(0) &&
                tokenTo != address(0) &&
                tokenFrom != tokenTo &&
                tokenFrom != address(RESERVE) &&
                tokenTo != address(RESERVE),
            "bad args"
        );

        uint64 feeN = _feeNum(freeAmt);

        /* hop-1: tokenFrom → RESERVE */
        Pool storage pA = pools[tokenFrom];
        require(pA.reserveR > 0 && pA.reserveT > 0, "empty A");
        uint64 reserveGot = _outTtoR(amountIn, pA.reserveR, pA.reserveT, feeN);

        /* hop-2: RESERVE → tokenTo */
        Pool storage pB = pools[tokenTo];
        require(pB.reserveR > 0 && pB.reserveT > 0, "empty B");
        out = _outRtoT(reserveGot, pB.reserveR, pB.reserveT, feeN);
    }

    /*=====================================================================
                                TWAP QUERY
    =====================================================================*/
    /**
     * @notice Return time‑weighted average (RESERVE/token) price as Q64.64.
     * @param token    Non‑reserve token address
     * @param secsAgo  Lookback in seconds (>0, ≤4 h)
     * @return priceQ64  (reserveR <<64) / reserveT averaged over interval
     */
    function consultTWAP(
        address token,
        uint32 secsAgo,
        uint128 /*minVolume unused*/
    ) external view returns (uint128 priceQ64) {
        require(secsAgo > 0 && secsAgo <= _OBS_PERIOD * _OBS_SIZE, "range");
        Pool storage p = pools[token];
        require(p.reserveT > 0, "no pool");

        /* current cumulative up to now */
        uint256 curCum = p.priceCum;
        uint64 nowTs = uint64(block.timestamp);
        if (p.lastTs != 0 && nowTs > p.lastTs && p.reserveT > 0) {
            uint256 priceNow = (uint256(p.reserveR) << 64) / p.reserveT;
            unchecked {
                curCum += priceNow * (nowTs - p.lastTs);
            }
        }

        uint64 targetTs = nowTs - secsAgo;
        Obs memory older;
        {
            uint8 idx = _obsIdx[token];
            for (uint8 i = 0; i < _OBS_SIZE; ++i) {
                Obs memory o = _obs[token][(idx + _OBS_SIZE - i) % _OBS_SIZE];
                if (o.ts == 0) break; // uninitialised slot
                if (o.ts <= targetTs) {
                    older = o;
                    break;
                }
            }
        }
        require(older.ts > 0 && older.ts <= targetTs, "snap missing");
        uint64 dt = nowTs - older.ts;
        priceQ64 = uint128((curCum - older.priceCum) / dt);
    }

}
