// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* forge-std harness */
import "lib/forge-std/src/Test.sol";

/* project contracts */
import "../src/_dollar.sol";                             // QSD
import {IFreeTradeToken, KRIEGSMARINE} from "../src/_trader.sol";
import {TradesPerDayToken}               from "../src/_token.sol";

contract MockZRC20 is IZRC20 {
    string public name; string public symbol;
    uint8 public constant override decimals = 8;
    mapping(address=>uint64) public override balanceOf;
    mapping(address=>mapping(address=>uint64)) public override allowance;
    uint64 public totalSupply;
    constructor(string memory n,string memory s){name=n;symbol=s;}
    function _mv(address f,address t,uint64 v) internal {require(balanceOf[f]>=v,"bal");unchecked{balanceOf[f]-=v;balanceOf[t]+=v;}emit Transfer(f,t,v);}
    function transfer(address t,uint64 v) external override returns(bool){_mv(msg.sender,t,v);return true;}
    function approve(address s,uint64 v) external override returns(bool){allowance[msg.sender][s]=v;emit Approval(msg.sender,s,v);return true;}
    function transferFrom(address f,address t,uint64 v) external override returns(bool){
        uint64 al=allowance[f][msg.sender];require(al>=v,"allow");if(al!=type(uint64).max){allowance[f][msg.sender]=al-v;emit Approval(f,msg.sender,al-v);} _mv(f,t,v);return true;
    }
    /* test helper */
    function mint(address to,uint64 v) external {balanceOf[to]+=v;totalSupply+=v;emit Transfer(address(0),to,v);}
}

/* ─────────────────────────────  Flash borrower stub  ───────────────────────────── */
contract FlashBorrower is IZ156FlashBorrower {
    IZRC20 public immutable tok;
    constructor(IZRC20 _t){tok=_t;}
    function onFlashLoan(address initiator,address token,uint64 amt,uint64,bytes calldata) external override returns(bytes32){
        require(msg.sender==initiator && token==address(tok),"bad");
        tok.approve(initiator,amt);
        return keccak256("IZ156.ok");
    }
}

/* ─────────────────────────────  Comprehensive test  ───────────────────────────── */
contract QSD_Comprehensive is Test {
    uint64 constant ONE = 1e8;               // 1e8 = 1 token (8 dec)
    /* core */
    MockZRC20          wQRL;
    TradesPerDayToken  FREE;
    KRIEGSMARINE       dex;
    QSD                qsd;
    /* actors */
    address alice  = address(0xA11);
    address bob    = address(0xB22);
    address keep   = address(0xC33);
    address oracle = address(0xDEAD);

    /* ─────────────────────────────  SET-UP  ───────────────────────────── */
    function setUp() public {
        wQRL = new MockZRC20("Wrapped QRL","wQRL");
        FREE = new TradesPerDayToken("FREE","FREE");

        dex  = new KRIEGSMARINE(wQRL, IFreeTradeToken(address(FREE)));
        FREE.addAdmin(address(dex));                         // let AMM lock() without revert

        qsd  = new QSD(address(wQRL), 14000, 2*ONE, oracle, address(dex)); // 140 % MCR, $2 peg

        _fund(alice,  2_000_000);
        _fund(bob,    2_000_000);
        _fund(keep,     500_000);

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(keep);
    }

    /* =================================================================== *
                             VAULT  –  HAPPY PATH
     * =================================================================== */
    function testVaultFullLifecycle() public {
        vm.startPrank(alice);

        // 1. add collateral
        qsd.deposit(alice, 1_000 * ONE);                    // 1 000 wQRL

        // 2. borrow (0 .30 % fee auto-added → debt = 601 .8 QSD)
        qsd.borrow(600 * ONE);

        // 3. repay part of the debt – releases proportional collateral
        qsd.repay(alice, 101 * ONE);

        // 4. withdraw a chunk of the now-free collateral
        qsd.withdraw(50 * ONE);                             // 50 wQRL

        // ── final book-keeping checks ─────────────────────────────────────
        (uint64 col, uint64 deb) = _vault(alice);

        // • debt: 601 .8 − 101 = 500 .8 QSD  →  500 80000000 in 1e-8 units
        assertEq(deb, 500_80000000);

        // • collateral: precise integer maths leaves 782 .17015620 wQRL
        //   (1000 − 1000×101/601.8 − 50) × 1e8 = 78 217 015 620
        assertEq(col, 78_217_015_620);

        vm.stopPrank();
    }

    /* =================================================================== *
                   VAULT  –  CRITICAL REVERT / EDGE CONDITIONS
     * =================================================================== */
    function testBorrowZeroReverts() public {
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000*ONE);
        vm.expectRevert(); // zero
        qsd.borrow(0);
        vm.stopPrank();
    }
    function testBorrowPastMcrReverts() public {
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000 * ONE);          // $2 000 collateral
        vm.expectRevert();                        // would violate 140 % MCR
        qsd.borrow(1_500 * ONE);                  // ← now really too large
        vm.stopPrank();
    }

    function testWithdrawExcessReverts() public {
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000 * ONE);
        qsd.borrow(600 * ONE);                    // healthy (≈332 % CR)
        vm.expectRevert(); // "MCR"
        qsd.withdraw(600 * ONE);                  // would push CR below 140 %
        vm.stopPrank();
    }
    function testRepayOverDebtReverts() public {
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000*ONE);
        qsd.borrow(200*ONE);
        vm.expectRevert(">debt");
        qsd.repay(alice, 300*ONE);
        vm.stopPrank();
    }

    /* =================================================================== *
                             LIQUIDATION
     * =================================================================== */
    function testLiquidationEdge() public {
        // Bob opens a vault sitting **exactly** at 140 % CR (wQRL @ $2)
        vm.startPrank(bob);
        qsd.deposit(bob, 1_000 * ONE);
        qsd.borrow(1_424 * ONE);                  // debt ≈ 1 428.272 QSD
        vm.stopPrank();

        // Price halves → CR ≈ 70 % (unsafe)
        vm.prank(oracle);
        qsd.setPrice(ONE);

        // Keeper prepares QSD to repay 30 tokens
        vm.prank(bob);
        qsd.transfer(keep, 30 * ONE);

        vm.startPrank(keep);
        qsd.approve(address(qsd), type(uint64).max);
        qsd.liquidate(bob, 30 * ONE);             // should now succeed
        vm.stopPrank();
    }

    /* =================================================================== *
                      LIQUIDITY-LOAN  –  VALID + REVERTs
     * =================================================================== */
    function testLiquidityLoanDuplicateReverts() public {
        _seedDex();                                        // initial pool

        vm.startPrank(alice);
        qsd.liquidityLoanIn(1_000*ONE,1);
        vm.expectRevert("loan live");
        qsd.liquidityLoanIn(100*ONE,1);                    // second loan not allowed
        vm.stopPrank();
    }

    function testLiquidityLoanOutBadSharesReverts() public {
        _seedDex();
        vm.prank(alice);
        qsd.liquidityLoanIn(1_000 * ONE, 1);

        (uint128 owned, ) = qsd.liqLoan(alice);   // actual LP shares
        vm.expectRevert("no-loan/slip");
        vm.prank(alice);
        qsd.liquidityLoanOut(owned + 1, 0, 0);    // ask for > owned → revert
    }
    /* =================================================================== *
                  LIQUIDITY-LOAN  –  SOFT DEFAULT & DEADPOOL
     * =================================================================== */
    function testDeadpoolFullCycle() public {
        _seedDex();                                         // initial pool
        vm.prank(bob);
        qsd.liquidityLoanIn(1_000 * ONE, 1);                // Bob adds 1 000 wQRL

        // Drain QSD side of the AMM so Bob’s exit soft-defaults
        vm.prank(alice);
        dex.swapReserveForToken(address(qsd), 800_000 * ONE, 0, alice, 0);

        // Loan exit → collateral quarantined
        vm.prank(bob);
        qsd.liquidityLoanOut(0, 0, 0);
        uint64 poolBefore = _deadpool();
        assertGt(poolBefore, 0);

        /* keeper burns QSD to rescue **up to 1 000 wQRL** — never more than
        their balance can cover at the current oracle price (2 $).        */
        uint64 claim = poolBefore > 1_000 * ONE ? 1_000 * ONE : poolBefore;

        vm.startPrank(keep);
        qsd.deposit(keep, 10_000 * ONE);                    // post collateral
        qsd.borrow(14_000 * ONE);                           // max safe borrow
        qsd.approve(address(qsd), type(uint64).max);

        qsd.claimDeadpool(claim, type(uint64).max);         // burn & release

        uint64 poolAfter = _deadpool();
        assertEq(poolAfter, poolBefore - claim);            // bucket shrank
        vm.stopPrank();
    }

    /* =================================================================== *
                          FLASH-LOAN  –  GOOD & BAD
     * =================================================================== */
    function testFlashLoanExcessSupplyReverts() public {
        FlashBorrower fb = new FlashBorrower(qsd);

        uint64 cap = qsd.maxFlashLoan(address(qsd));
        vm.prank(address(fb));
        vm.expectRevert("supply");
        qsd.flashLoan(fb, address(qsd), cap + 1, "");  // just over the limit
    }
    function testFlashLoanNonBorrowerCallReverts() public {
        FlashBorrower fb = new FlashBorrower(qsd);
        vm.expectRevert(); // rcv
        qsd.flashLoan(fb, address(qsd), 1_000*ONE, "");
    }
    function testFlashLoanHappy() public {
        FlashBorrower fb = new FlashBorrower(qsd);
        vm.prank(address(fb));
        qsd.flashLoan(fb, address(qsd), 5_000*ONE, "");
        assertEq(qsd.balanceOf(address(fb)), 0);
    }

    /* =================================================================== *
                           ORACLE AUTH — EDGE
     * =================================================================== */
    function testSetPriceOnlyOracle() public {
        vm.expectRevert("oracle");
        qsd.setPrice(3*ONE);

        vm.prank(oracle);
        qsd.setPrice(3*ONE);                               // succeeds
        assertEq(qsd.wqrlPrice(), 3*ONE);
    }

    /* =================================================================== *
                                 HELPERS
     * =================================================================== */
    function _vault(address who) internal view returns(uint64 col,uint64 debt){
        return qsd.vaults(who);
    }

    function _deadpool() internal view returns(uint64 dp){
        uint256 slot0 = uint256(vm.load(address(qsd), bytes32(uint256(0))));
        dp = uint64(slot0 >> 8);
    }

    /* direct storage poke → testing only */
    function _setDeadpool(uint64 amt) internal {
        uint256 slot0 = uint256(vm.load(address(qsd), bytes32(uint256(0))));
        slot0 = (slot0 & 0xff) | uint256(amt)<<8;
        vm.store(address(qsd), bytes32(uint256(0)), bytes32(slot0));
    }

    function _seedDex() internal {
        address s = address(0xBEEF);
        _fund(s, 20_000);
        _approveAll(s);
        vm.prank(s);
        qsd.liquidityLoanIn(10_000*ONE, 1);                // seeds initial pool
    }

    function _fund(address to,uint64 whole) internal {
        uint64 amt = whole*ONE;
        wQRL.mint(to, amt);
        FREE.mint(to, amt);
    }
    function _approveAll(address w) internal {
        vm.prank(w); wQRL.approve(address(qsd), type(uint64).max);
        vm.prank(w); wQRL.approve(address(dex), type(uint64).max);
        vm.prank(w); qsd.approve(address(qsd), type(uint64).max);
        vm.prank(w); qsd.approve(address(dex), type(uint64).max);
    }
}
