// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DollarCore.t.sol"; // re-use QSD_Test with setUp() & helpers

/* helper */
contract MalReenter is IZ156FlashBorrower {
    QSD public immutable qsd;

    constructor(QSD q) {
        qsd = q;
    }

    function onFlashLoan(
        address initiator,
        address,
        uint64 amount,
        uint64,
        bytes calldata
    ) external override returns (bytes32) {
        // re-enter
        qsd.flashLoan(this, address(qsd), 1, ""); // must revert “re-enter”
        // approve so the outer call could be repaid (never reached)
        qsd.approve(initiator, amount);
        return keccak256("IZ156.ok");
    }
}

/**
 * Extra-coverage test-bed for QSD.
 *
 * ──────────────────────────────────────────────
 *  Topics covered
 *  ──────────────────────────────────────────────
 *  ①  Interest accrual over time
 *  ②  Third-party debt repay
 *  ③  Vault boundary / revert paths
 *  ④  Soft-default & claim-Deadpool edge-cases
 *  ⑤  Flash-loan safety (re-entrancy & supply cap)
 *  ⑥  Yield-protocol: join/leave, min-stake, yield, haircuts
 *  ⑦  Liquidity-loan slippage guards
 *  ⑧  Full-debt liquidation
 */
contract QSD_More is QSD_Comprehensive {
    /*════════════════════════════════════════════
      ①  Interest accrual
      ════════════════════════════════════════════*/
    function testInterestAccrual() public {
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000 * ONE);
        qsd.borrow(1_000 * ONE);                     // 50 % LTV, but zero APR
        (, uint64 beforeDebt) = qsd.vaults(alice);

        // jump one year ahead and poke the vault
        vm.warp(block.timestamp + 365 days);
        qsd.deposit(alice, 1);                       // triggers _accrue()

        (, uint64 afterDebt) = qsd.vaults(alice);
        assertEq(afterDebt, beforeDebt, "unexpected interest accrued");
        vm.stopPrank();
    }

    /*════════════════════════════════════════════
      ②  Third-party repay
      ════════════════════════════════════════════*/
    function testThirdPartyRepay() public {
        /* Bob opens vault and borrows 500 QSD (debt = 501 .5) */
        vm.startPrank(bob);
        qsd.deposit(bob, 1_000 * ONE);
        qsd.borrow(500 * ONE);
        (, uint64 bobDebt) = qsd.vaults(bob);
        vm.stopPrank();

        /* Bob hands Alice the 500 principal he received */
        vm.prank(bob);
        qsd.transfer(alice, 500 * ONE);

        /* Alice tops up the fee shortfall (≈1 .5 QSD) and repays everything */
        vm.startPrank(alice);
        uint64 gap = bobDebt - 500 * ONE;            // debt minus principal
        if (gap > 0) {
            qsd.deposit(alice, 1_000 * ONE);         // collateral to borrow against
            qsd.borrow(gap);
        }
        qsd.repay(bob, bobDebt);
        (, uint64 debtAfter) = qsd.vaults(bob);
        assertEq(debtAfter, 0, "debt not cleared");
        vm.stopPrank();
    }

    /*════════════════════════════════════════════
      ③  Vault boundary checks
      ════════════════════════════════════════════*/

    function testWithdrawTooMuchReverts() public {
        vm.prank(alice);
        qsd.deposit(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert("excess");
        qsd.withdraw(200 * ONE);
    }

    /*════════════════════════════════════════════
      ④  claimDeadpool slip / pool size guards
      ════════════════════════════════════════════*/
    function testClaimDeadpoolSlipReverts() public {
        /* seed 100 wQRL into the dead-pool */
        uint256 raw = (uint256(100 * ONE) << 8) | 1;
        vm.store(address(qsd), bytes32(uint256(0)), bytes32(raw));

        /* give Alice 50 QSD via a normal vault */
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000 * ONE); // plenty of collateral
        qsd.borrow(50 * ONE);
        vm.stopPrank();

        /* ask for 80 wQRL but cap burn at 10 QSD ⇒ “slip” revert */
        vm.prank(alice);
        vm.expectRevert(); // slip
        qsd.claimDeadpool(80 * ONE, 10 * ONE);
    }

    /*════════════════════════════════════════════
      ⑤  Flash-loan – re-entrancy guard & supply cap
      ════════════════════════════════════════════*/

    function testFlashLoanReentrancyBlocked() public {
        MalReenter re = new MalReenter(qsd); // helper below
        uint64 amt = 1_000 * ONE;

        vm.expectRevert("re-enter");
        vm.prank(address(re));
        qsd.flashLoan(re, address(qsd), amt, "");
    }

    /* ask for more than the current flash-loan head-room → must revert “supply” */
    function testFlashLoanSupplyCap() public {
        /* create a tiny outstanding supply so the cap is strictly below 2²⁶⁴-1 */
        vm.startPrank(alice);
        qsd.deposit(alice, 10 * ONE);
        qsd.borrow(1);                                        // mint 0.00000001 QSD
        vm.stopPrank();

        uint64 cap = qsd.maxFlashLoan(address(qsd));          // = MAX_BAL – _tot
        uint64 tooMuch;
        unchecked { tooMuch = cap + 1; }                      // still fits in uint64

        IZ156FlashBorrower fb = new FlashBorrower(qsd);       // dummy round-trip actor

        vm.expectRevert("supply");
        vm.prank(address(fb));                                // caller **must** be borrower
        qsd.flashLoan(fb, address(qsd), tooMuch, "");
    }

    /*════════════════════════════════════════════
      ⑥  Yield-protocol basics
     ════════════════════════════════════════════*/
    /* join + leave workflow and min-stake enforcement */
    function testYieldJoinLeaveAndMinStake() public {
        uint64 pid = qsd.createProtocol(address(this), 0, 1_000 * ONE);

        vm.startPrank(alice);
        qsd.deposit(alice, 2_000 * ONE);
        qsd.borrow(2_000 * ONE);                          // obtain stake balance

        /* join */
        uint64[8] memory add; add[0] = pid;
        qsd.setMembership(add, 0);

        /* dropping below min-stake must fail */
        vm.expectRevert("minStake");
        qsd.transfer(bob, 1_500 * ONE);

        /* leave completely, then transfer succeeds */
        vm.roll(block.number + 1);                        // avoid “dup” marker
        uint64[8] memory none;                            // all zeros → leave all
        qsd.setMembership(none, 0);
        qsd.transfer(bob, 1_500 * ONE);
        vm.stopPrank();
    }

    /*════════════════════════════════════════════
    ⑦  Yield-protocol: yield & haircut workflow
    ════════════════════════════════════════════*/
    function testYieldAndHaircutAccounting() public {
        uint64 pid = qsd.createProtocol(address(this), 0, 10 * ONE);

        /* ── Controller treasury: mint 150 QSD ───────────────────────── */
        wQRL.mint(address(this), 1_000 * ONE);
        wQRL.approve(address(qsd), type(uint64).max);
        qsd.deposit(address(this), 1_000 * ONE);
        qsd.borrow(150 * ONE);

        /* ── Alice stakes 100 QSD ─────────────────────────────────────── */
        vm.startPrank(alice);
        qsd.deposit(alice, 1_000 * ONE);
        qsd.borrow(100 * ONE);
        uint64[8] memory add; add[0] = pid;
        qsd.setMembership(add, 0);
        vm.stopPrank();

        /* ── Controller adds 50 QSD yield ─────────────────────────────── */
        qsd.addYield(pid, 50 * ONE);

        /* Harvest (any tx touching Alice triggers it) */
        uint64 before = qsd.balanceOf(alice);
        vm.prank(alice);
        qsd.transfer(bob, 1);                       // ping-harvest
        assertEq(qsd.balanceOf(alice) - before, 50 * ONE, "yield mismatch");

        /* ── Haircut round-trip ───────────────────────────────────────── */
        uint64 cut = 25 * ONE;

        /* Immediately after signalling, nothing is burned yet           *
        * so signalHaircut must return 0.                               */
        assertEq(qsd.signalHaircut(pid, cut), 0, "nothing burned yet");

        /* Trigger a harvest (burns the haircut from stakers)            */
        vm.prank(alice);
        qsd.transfer(bob, 1);                       // another ping

        /* Now the controller can collect exactly `cut` back             */
        assertEq(qsd.collectHaircut(pid, bob), cut, "haircut mismatch");
    }

    /*════════════════════════════════════════════
      ⑦  Liquidity-loan slippage guards
      ════════════════════════════════════════════*/
    function testLiquidityLoanMinSharesRevert() public {
        _seedDex();
        vm.prank(alice);
        vm.expectRevert("slip shares");
        qsd.liquidityLoanIn(500 * ONE, type(uint128).max); // impossible min
    }

    /*════════════════════════════════════════════
      ⑧  Full-debt liquidation
      ════════════════════════════════════════════*/
    /* full-debt liquidation – seize is capped by the vault’s collateral (1 000) */
    function testFullLiquidation() public {
        /* Bob vault: 1 000 wQRL collateral, borrow 1 333 QSD */
        vm.startPrank(bob);
        qsd.deposit(bob, 1_000 * ONE);
        qsd.borrow(1_333 * ONE);
        (, uint64 debt) = qsd.vaults(bob);           // includes 0 .30 % fee
        vm.stopPrank();

        /* Price halves → vault unsafe */
        vm.prank(oracle);
        qsd.setPrice(ONE);                           // $2 → $1

        /* Bob transfers all minted QSD (1 333) to Alice */
        vm.prank(bob);
        qsd.transfer(alice, 1_333 * ONE);

        /* Make sure Alice can cover the **entire** debt */
        vm.startPrank(alice);
        uint64 bal = qsd.balanceOf(alice);
        if (bal < debt) {
            qsd.deposit(alice, 1_000 * ONE);         // fresh collateral
            qsd.borrow(debt - bal);                  // top-up to exact debt
        }

        uint64 before = wQRL.balanceOf(alice);
        qsd.approve(address(qsd), type(uint64).max);
        qsd.liquidate(bob, type(uint64).max);        // burns full debt
        uint64 haul = wQRL.balanceOf(alice) - before;

        /* capped by vault collateral ⇒ 1 000 wQRL seized */
        assertEq(haul, 1_000 * ONE);
        vm.stopPrank();
    }
}
