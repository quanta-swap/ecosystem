// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────
│  External interfaces & helpers   │
└──────────────────────────────────*/
import "../_launch.sol"; // pulls in IDEX, IZRC20, custom errors
import "../IZRC20.sol";

/*══════════════════════════════════════
│          QuantaSwap Constant‑Product  │
╚══════════════════════════════════════*/
contract QuantaSwap is IDEX {
    using IZRC20Helper for address;

    /*────────── errors ─────────*/
    error UnsupportedReserve(address);
    error UnsupportedPair(address, address);
    error PairNotFound(address, address);
    error NotEnoughLiquidity(uint128 have, uint256 need);
    error Slippage(uint64 minA, uint64 amtA, uint64 minB, uint64 amtB);

    /*────────── pool bookkeeping ─────────*/
    struct PoolState {
        uint64 reserve0; // token‑0 inside pool
        uint64 reserve1; // token‑1 inside pool
        uint128 depth; // total LP issued  (includes MIN_LIQUIDITY lock‑up)
    }

    mapping(address => mapping(address => PoolState)) public pairs; // token0 → token1 → state
    mapping(address => mapping(IZRC20 => mapping(IZRC20 => uint128)))
        public liquidity; // provider → pair → LP
    mapping(address => address) public routers; // reserved for future router whitelists

    uint256 private constant MINIMUM_LIQUIDITY = 1_000; // identical to Uniswap‑V2

    /*────────── misc view ─────────*/
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=tqOHiDKPxe0";
    }

    /*════════════════════════════════════════════════════
     *                    Compatibility probe             *
     *════════════════════════════════════════════════════*/
    function checkSupportForPair(
        address tokenA,
        address tokenB
    ) external view override returns (bool) {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB)
            return false;
        return _isSupported(tokenA) && _isSupported(tokenB);
    }

    /// Best‑effort validation that `token` meets all QuantaSwap requirements.
    function _isSupported(address token) internal view returns (bool) {
        if (!token.isIZRC20()) return false; // 1. 64‑bit supply
        IZRC20 t = IZRC20(token);
        if (!t.checkSupportsMover(address(this))) return false; // 2. mover ACL
        if (!t.checkSupportsOwner(address(this))) return false; // 3. owner ACL
        return true;
    }

    /*════════════════════════════════════════════════════
     *                  Pool initialisation               *
     *════════════════════════════════════════════════════*/
    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to
    ) external override returns (address location, uint256 liquidity_) {
        /*──── 1. canonical ordering & validation ────*/
        if (tokenA == tokenB || tokenA == address(0) || tokenB == address(0))
            revert UnsupportedPair(tokenA, tokenB);

        // sort so tokenA < tokenB; swap amounts accordingly
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
            (amountA, amountB) = (amountB, amountA);
        }

        if (!_isSupported(tokenA) || !_isSupported(tokenB))
            revert UnsupportedPair(tokenA, tokenB);

        PoolState storage p = pairs[tokenA][tokenB];
        if (p.depth != 0) revert PairNotFound(tokenA, tokenB); // already initialised

        require(amountA > 0 && amountB > 0, "zero amounts");
        uint64 amountA64 = uint64(amountA);
        uint64 amountB64 = uint64(amountB);
        /*──── 2. pull reserves from caller ────*/
        require(
            IZRC20(tokenA).transferFrom(msg.sender, address(this), amountA64) &&
                IZRC20(tokenB).transferFrom(msg.sender, address(this), amountB64),
            "reserve transfer fail"
        );

        /*──── 3. liquidity maths ────*/
        uint256 product = uint256(amountA) * uint256(amountB); // cast ⇒ 256‑bit
        uint256 rootK256 = _sqrt(product);
        require(rootK256 > MINIMUM_LIQUIDITY, "insuf liq");

        liquidity_ = rootK256 - MINIMUM_LIQUIDITY; // LP minted to user
        uint128 depthAfter = uint128(liquidity_ + MINIMUM_LIQUIDITY);

        /*──── 4. state updates ────*/
        p.reserve0 = amountA64;
        p.reserve1 = amountB64;
        p.depth = depthAfter;

        liquidity[to][IZRC20(tokenA)][IZRC20(tokenB)] += uint128(liquidity_);

        return (address(this), liquidity_);
    }

    /*════════════════════════════════════════════════════
     *                   LP burn & withdraw               *
     *════════════════════════════════════════════════════*/
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity_,
        address to,
        uint64 minA,
        uint64 minB
    ) external override returns (uint64 amountA, uint64 amountB) {
        /*──── canonical ordering ────*/
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
            (minA, minB) = (minB, minA);
        }

        PoolState storage p = pairs[tokenA][tokenB];
        if (p.depth == 0) revert PairNotFound(tokenA, tokenB);

        uint128 owned = liquidity[msg.sender][IZRC20(tokenA)][IZRC20(tokenB)];
        if (liquidity_ > owned) revert NotEnoughLiquidity(owned, liquidity_);

        /*──── proportional reserves ────*/
        amountA = uint64((uint256(p.reserve0) * liquidity_) / p.depth);
        amountB = uint64((uint256(p.reserve1) * liquidity_) / p.depth);
        if (amountA < minA || amountB < minB)
            revert Slippage(minA, amountA, minB, amountB);

        /*──── state mutation ────*/
        p.reserve0 -= amountA;
        p.reserve1 -= amountB;
        p.depth -= uint128(liquidity_);

        liquidity[msg.sender][IZRC20(tokenA)][IZRC20(tokenB)] =
            owned -
            uint128(liquidity_);

        /*──── transfers ────*/
        require(
            IZRC20(tokenA).transfer(to, amountA) &&
                IZRC20(tokenB).transfer(to, amountB),
            "transfer fail"
        );

        return (amountA, amountB);
    }

    /*════════════════════════════════════════════════════
     *                 Internal math helpers              *
     *════════════════════════════════════════════════════*/
    /// @dev Babylonian square‑root (uint256 → uint256, returns floor).
    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = y;
        uint256 k = (x + 1) >> 1;
        while (k < z) {
            z = k;
            k = (x / k + k) >> 1;
        }
    }
}
