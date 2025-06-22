// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_trader.sol"; // KRIEGSMARINE
import "../src/_token.sol"; // TradesPerDayToken used as FREE

/*──────────────────── 8-decimal mock token ───────────────────*/
contract MockZRC20 is IZRC20 {
    string public name;
    string public symbol;
    uint64 public totalSupply;
    mapping(address => uint64) public balanceOf;
    mapping(address => mapping(address => uint64)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() external pure override returns (uint8) {
        return 8; // 10^8 (decimals = 8)
    }

    function mint(address to, uint64 a) external {
        balanceOf[to] += a;
        totalSupply += a;
        emit Transfer(address(0), to, a);
    }

    function _move(address f, address t, uint64 a) private {
        require(balanceOf[f] >= a, "bal");
        unchecked {
            balanceOf[f] -= a;
            balanceOf[t] += a;
        }
        emit Transfer(f, t, a);
    }

    function transfer(address t, uint64 a) external returns (bool) {
        _move(msg.sender, t, a);
        return true;
    }

    function approve(address sp, uint64 a) external returns (bool) {
        allowance[msg.sender][sp] = a;
        emit Approval(msg.sender, sp, a);
        return true;
    }

    function transferFrom(
        address f,
        address t,
        uint64 a
    ) external returns (bool) {
        uint64 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        if (al != type(uint64).max) {
            allowance[f][msg.sender] = al - a;
            emit Approval(f, msg.sender, al - a);
        }
        _move(f, t, a);
        return true;
    }
}

/*──────────────────────────  Suite  ──────────────────────────*/
contract ReserveDEX_Comprehensive is Test {
    uint64 constant ONE = 1e8; // 1 token in 8-dec units

    MockZRC20 RSV; // reserve asset
    TradesPerDayToken FREE; // daily-lock rebate token
    MockZRC20 A;
    MockZRC20 B; // pool tokens
    KRIEGSMARINE dex;

    address LP1 = address(0xA1);
    address LP2 = address(0xA2);
    address TRD = address(0xB1);
    address PAY = address(0xB2);

    /*─────────────────────── Setup ───────────────────────*/
    function setUp() public {
        RSV = new MockZRC20("RSV", "RSV");
        FREE = new TradesPerDayToken("FREE", "FREE");
        A = new MockZRC20("A", "A");
        B = new MockZRC20("B", "B");

        /* mint everything */
        _mintAll(LP1, 1_000_000);
        _mintAll(LP2, 1_000_000);
        _mintAll(TRD, 2_000_000);
        _mintAll(PAY, 500_000);
        FREE.mint(TRD, 50_000 * ONE);

        dex = new KRIEGSMARINE(RSV, IFreeTradeToken(address(FREE)));

        /* grant dex admin rights so it can call lock() */
        FREE.addAdmin(address(dex));

        /* blanket approvals */
        _approveAll(LP1);
        _approveAll(LP2);
        _approveAll(TRD);
        _approveAll(PAY);
    }

    /*────────────── Liquidity happy & edge paths ─────────────*/
    function testInitDustRevert() public {
        vm.prank(LP1);
        vm.expectRevert("init dust");
        dex.addLiquidity(address(A), 1, 1); // share sqrt(1) =1 < 1000
    }

    function testBalancedAndRefundAdd() public {
        /* first LP balanced */
        vm.prank(LP1);
        dex.addLiquidity(address(A), 10_000 * ONE, 10_000 * ONE);

        /* second LP unbalanced → should refund surplus token */
        vm.prank(LP2);
        (, uint64 rUsed, uint64 tUsed) = dex.addLiquidity(
            address(A),
            5_000 * ONE,
            10_000 * ONE
        ); // double token side
        assertEq(rUsed, 5_000 * ONE);
        assertEq(tUsed, 5_000 * ONE);
        assertEq(A.balanceOf(LP2), 1_000_000 * ONE - 5_000 * ONE); // 5 000 refunded
    }

    function testRemoveExceedsRevert() public {
        _bootstrapA();
        vm.prank(LP2);
        vm.expectRevert("exceeds");
        dex.removeLiquidity(address(A), 1);
    }

    /*────────────────── Swap variants & fee logic ─────────────────*/
    function testAllSwapPaths() public {
        _bootstrapA();
        _bootstrapB();

        /* ── 1. direct RESERVE → Token A and back ── */
        vm.prank(TRD);
        uint64 outA = dex.swapReserveForToken(
            address(A),
            2_000 * ONE,
            0,
            TRD,
            0                // ← no FREE lock
        );
        assertGt(outA, 0);

        vm.prank(TRD);
        uint64 backRSV = dex.swapTokenForReserve(
            address(A),
            outA,
            0,
            TRD,
            0                // ← no FREE lock
        );
        assertGt(backRSV, 0);

        /* ── 2. delegated RESERVE → Token A ── */
        uint64 payStart = A.balanceOf(PAY);
        vm.prank(TRD);
        uint64 payGot = dex.tradeReserveForToken(
            TRD,
            address(A),
            1_000 * ONE,
            0,
            PAY,
            0                // ← no FREE lock
        );
        assertEq(A.balanceOf(PAY) - payStart, payGot);

        /* ── 3. Token-A → Token-B via RESERVE hop (no FREE rebate) ── */
        uint64 quoted = dex.simulateTokenForToken(
            address(A),
            address(B),
            3_000 * ONE,
            0                // ← no FREE lock
        );

        vm.prank(TRD);
        uint64 outB = dex.swapTokenForToken(
            address(A),
            address(B),
            3_000 * ONE,
            0,
            TRD,
            0                // ← no FREE lock
        );

        /* live execution should never yield less than the simulator quote */
        assertGe(outB, quoted);
    }

    function testFeeNumGuard() public {
        _bootstrapA();
        uint64 tooMuchFree = dex.FULL_FREE() + 1;
        vm.expectRevert("free > 1");
        dex.simulateReserveForToken(address(A), 100 * ONE, tooMuchFree);
    }

    function testSlippageRevert() public {
        _bootstrapA();
        vm.prank(TRD);
        vm.expectRevert("slippage");
        dex.swapReserveForToken(
            address(A),
            1_000 * ONE,
            type(uint64).max,
            TRD,
            0
        );
    }

    /*──────────────── Oracle snapshots & TWAP ────────────────*/
    function testOracleSnapAndConsult() public {
        _bootstrapA();                         // creates first snapshot

        /* take three more 10-minute spaced snapshots */
        for (uint8 i; i < 3; ++i) {
            _warpAndPoke(address(A), 10 minutes);
        }

        /* 600-second TWAP succeeds */
        uint128 px = dex.consultTWAP(address(A), 600, 0);
        assertGt(px, 0);

        /* querying further back than snapshot history reverts (any reason OK) */
        vm.expectRevert();
        dex.consultTWAP(address(A), 3_600, 0);
    }

    function testConsultGuards() public {
        vm.expectRevert("no pool");
        dex.consultTWAP(address(A), 600, 0);

        _bootstrapA();
        vm.expectRevert("range");
        dex.consultTWAP(address(A), 5 hours, 0);
    }

    /*──────────────── Guard-matrix sanity reverts ────────────────*/
    function testBadArgsMatrix() public {
        vm.expectRevert("bad args");
        dex.swapReserveForToken(address(0), 1, 0, TRD, 0);

        vm.expectRevert(); // addr               // walletFrom == 0
        dex.tradeReserveForToken(address(0), address(A), 1, 0, PAY, 0);

        vm.expectRevert("bad args");
        dex.swapTokenForReserve(address(RSV), 1, 0, TRD, 0);
    }

    /*────────────────── helpers ──────────────────*/
    function _bootstrapA() internal {
        vm.prank(LP1);
        dex.addLiquidity(address(A), 100_000 * ONE, 100_000 * ONE);
    }

    function _bootstrapB() internal {
        vm.prank(LP1);
        dex.addLiquidity(address(B), 50_000 * ONE, 25_000 * ONE); // price 0.5
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        RSV.approve(address(dex), type(uint64).max);
        A.approve(address(dex), type(uint64).max);
        B.approve(address(dex), type(uint64).max);
        FREE.approve(address(dex), type(uint64).max);
        vm.stopPrank();
    }

    function _mintAll(address to, uint64 amtWhole) internal {
        RSV.mint(to, amtWhole * ONE);
        A.mint(to, amtWhole * ONE);
        B.mint(to, amtWhole * ONE);
    }

    function _warpAndPoke(address token, uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        dex.pokeOracle(token);
    }
}
