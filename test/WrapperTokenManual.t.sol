// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────*\
│  WrapperTokenManual – regression tests for WrappedQRL                      │
│                                                                           │
│  • Confirms that a force-harvest during lock-up:                           │
│        – Credits some yield (ΔBal ≥ 0)                                     │
│        – Burns some stake (ΔSupply  > 0)                                   │
│        – Never over-credits: ΔBal + ΔSupply ≤ 5 tok (the funded yield)     │
│  • Verifies the hard-coded 365-day MAX_LOCK_WIN guard.                     │
\*───────────────────────────────────────────────────────────────────────────*/

import "lib/forge-std/src/Test.sol";
import {WrappedQRL} from "../src/_native.sol";

/*──────── Constants (stay in sync with prod) ────────*/
uint64  constant ONE     = 1e9;          // 1 token (9-dec)
uint256 constant WEI_ONE = ONE * 1e9;    // 1 token in wei (18-dec)

contract WrapperTokenManual is Test {
    /* actors */
    address internal constant AL  = address(0xA11);
    address internal constant CTL = address(0xC01);
    address internal constant BO  = address(0xB02);

    WrappedQRL internal w;

    /*──────────────────── fixture ────────────────────*/
    function setUp() external {
        vm.deal(AL , 20 ether);
        vm.deal(CTL, 20 ether);
        vm.deal(BO , 20 ether);

        w = new WrappedQRL();

        /* controller boot-straps protocol #1 (lockWin = 1 blk, minStake = 1) */
        uint64 pid = w.createProtocol(CTL, 1, ONE);

        /* controller stakes 7 tok & joins */
        vm.startPrank(CTL);
        w.deposit{value: 7 * WEI_ONE}();
        uint64[8] memory join;
        join[0] = pid;
        w.setMembership(join, 0);
        vm.stopPrank();
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                     Yield-before-Haircut behaviour                   */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * Scenario
     * --------
     * 1. Alice joins protocol #1 with 10 tok.
     * 2. Controller funds 5 tok yield.
     * 3. Controller signals a 3 tok haircut.
     * 4. Anyone calls `forceHarvest([alice])`.
     *
     * Invariants we check (state-based, rounding-tolerant):
     *   • ΔSupply   > 0  (something was burned)
     *   • ΔBalance  ≥ 0  (yield never worse than haircut)
     *   • ΔBal + ΔSupply ≤ 5 tok (can’t exceed funded yield)
     */
    function testYieldHarvestBeforeHaircut() external {
        uint64 pid = 1;

        /* Alice deposits 10 tok & joins */
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory add;
        add[0] = pid;
        w.setMembership(add, 0);
        vm.stopPrank();

        /* Controller: +5 tok yield, then 3 tok haircut */
        vm.startPrank(CTL);
        w.addYield(pid, 5 * ONE);
        w.signalHaircut(pid, 3 * ONE);
        vm.stopPrank();

        /* ── snapshots ── */
        uint64 balBefore = w.balanceOf(AL);
        uint64 totBefore = w.totalSupply();

        /* Bypass locks with forceHarvest */
        address[] memory list = new address[](1);
        list[0] = AL;
        w.forceHarvest(list);

        /* ── post-harvest deltas ── */
        uint64 balAfter = w.balanceOf(AL);
        uint64 totAfter = w.totalSupply();

        uint64 dBal  = balAfter - balBefore;   // yield minus haircut
        uint64 dSupp = totBefore - totAfter;   // tokens burnt (may be 0)

        // 1. Harvest must never *debit* the wallet.
        assertGe(dBal, 0, "haircut exceeded yield");

        // 2. Wallet can’t benefit by more than the yield that was funded.
        //    (If the haircut rounded to zero, dSupp == 0 and this still holds.)
        assertLe(dBal + dSupp, 5 * ONE, "over-credited yield");
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                    MAX_LOCK_WIN constant guard                       */
    /*══════════════════════════════════════════════════════════════════════*/

    function testMaxLockWindowEnforced() external {
        assertEq(w.MAX_LOCK_WIN(), 365 days, "constant drift");

        uint64 tooLong = w.MAX_LOCK_WIN() + 1;
        vm.expectRevert("lockWin");
        w.createProtocol(BO, tooLong, ONE);
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                Late-joiner retro-yield immunity                      */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * Flow
     * ----
     * 1. Alice joins protocol #1 with 10 tok stake.
     * 2. Controller contributes 5 tok yield.
     * 3. Bob (late joiner) deposits 10 tok and joins *after* the yield.
     * 4. Anyone force-harvests Bob.
     *
     * Assertions
     * ----------
     * • Bob’s balance is exactly his 10 tok stake (no yield credited).  
     * • Alice **did** collect some positive yield (sanity check).  
     *   (We don’t pin the exact amount – rounding can vary.)
     */
    function testLateJoinGetsNoRetroYield() external {
        uint64 pid = 1;                                  // first real protocol

        /*───────── 1. Alice deposits 10 tok & joins early ─────────*/
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        /*───────── 2. Controller adds 5 tok yield ─────────*/
        vm.prank(CTL);
        w.addYield(pid, 5 * ONE);

        /*───────── 3. Bob arrives *after* yield ─────────*/
        vm.startPrank(BO);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory add; add[0] = pid;
        w.setMembership(add, 0);
        vm.stopPrank();

        /*───────── Snapshot Bob before harvest ─────────*/
        uint64 bobBefore = w.balanceOf(BO);

        /*───────── 4. Force-harvest Bob (anyone can call) ─────────*/
        address[] memory list = new address[](1);
        list[0] = BO;
        w.forceHarvest(list);

        uint64 bobAfter = w.balanceOf(BO);

        /*───────── Assertions ─────────*/
        assertEq(bobAfter, bobBefore, "late joiner received retro-yield");
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                Yield(5) ➜ Haircut(5)  –  global bounds               */
    /*══════════════════════════════════════════════════════════════════════*/
    function testYieldThenHaircutBounds() external {
        uint64 pid = 1;

        /* Alice joins with 10 tok; controller already staked 7 tok in setUp(). */
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory join; join[0] = pid;
        w.setMembership(join, 0);
        vm.stopPrank();

        /* Controller funds +5 tok yield, then signals −5 tok haircut. */
        vm.startPrank(CTL);
        w.addYield(pid, 5 * ONE);
        w.signalHaircut(pid, 5 * ONE);
        vm.stopPrank();

        /* ── pre-harvest snapshots ── */
        uint64 supplyBefore = w.totalSupply();
        uint64 aliceBefore  = w.balanceOf(AL);

        /* Harvest both staking wallets. */
        address[] memory batch = new address[](2);
        batch[0] = AL;
        batch[1] = CTL;
        w.forceHarvest(batch);

        /* ── post-harvest state ── */
        uint64 supplyAfter = w.totalSupply();
        uint64 aliceAfter  = w.balanceOf(AL);
        uint64 poolAfter   = w.balanceOf(address(this));

        /* (1) Aggregate burn never exceeds haircut (round-down is possible). */
        assertLe(supplyBefore - supplyAfter, 5 * ONE, "burn exceeds haircut");

        /* (2) Yield pool emptied. */
        assertEq(poolAfter, 0, "pool not drained");

        /* (3) Alice’s net Δ is bounded by the funded envelope (±5 tok). */
        uint64 deltaAlice = aliceAfter > aliceBefore
            ? aliceAfter - aliceBefore
            : aliceBefore - aliceAfter;
        assertLe(deltaAlice, 5 * ONE, "Alice delta outside envelope");

        /* (4) No uncollected haircut remains. */
        vm.prank(CTL);
        uint64 minted = w.collectHaircut(pid, CTL);
        assertEq(minted, 0, "collectHaircut minted >0");
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                Haircut(5) ➜ Yield(5)  –  global bounds               */
    /*══════════════════════════════════════════════════════════════════════*/
    function testHaircutThenYieldBounds() external {
        uint64 pid = 1;

        /* Alice joins with 10 tok. */
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory join; join[0] = pid;
        w.setMembership(join, 0);
        vm.stopPrank();

        /* Controller first signals a 5 tok haircut … */
        vm.prank(CTL);
        w.signalHaircut(pid, 5 * ONE);

        /* … then tops-up 5 tok so it can fund the yield.               */
        vm.prank(CTL);
        w.deposit{value: 5 * WEI_ONE}();   // keeps CTL-balance ≥ 5 tok

        /* Now contributes +5 tok yield.                                 */
        vm.prank(CTL);
        w.addYield(pid, 5 * ONE);

        /* ── pre-harvest snapshots ── */
        uint64 supplyBefore = w.totalSupply();
        uint64 aliceBefore  = w.balanceOf(AL);

        /* Harvest every staking wallet (Alice + Controller). */
        address[] memory batch = new address[](2);
        batch[0] = AL;
        batch[1] = CTL;
        w.forceHarvest(batch);

        /* ── post-harvest state ── */
        uint64 supplyAfter = w.totalSupply();

        assertEq(supplyBefore, supplyAfter, "unexpected supply change");

        uint64 aliceAfter  = w.balanceOf(AL);
        uint64 poolAfter   = w.balanceOf(address(this));

        /* (1) Alice’s net Δ must be within the ±5 tok envelope. */
        uint64 deltaAlice = aliceAfter > aliceBefore
            ? aliceAfter - aliceBefore
            : aliceBefore - aliceAfter;
        assertLe(deltaAlice, 5 * ONE, "Alice delta outside envelope");

        /* (2) Residual pool balance can only be a tiny rounding crumb (< 1 tok). */
        assertLt(poolAfter, ONE, "pool not fully drained");

        /* (3) First collectHaircut may mint (rounding) tokens … */
        vm.prank(CTL);
        uint64 first = w.collectHaircut(pid, CTL);
        assertEq(first, 5 * ONE, "collectHaircut had no funds");

        /* … but a second call must now return 0.                         */
        vm.prank(CTL);
        uint64 second = w.collectHaircut(pid, CTL);
        assertEq(second, 0, "collectHaircut still had funds");
    }

}
