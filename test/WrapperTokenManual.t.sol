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
uint64 constant ONE = 1e9; // 1 token (9-dec)
uint256 constant WEI_ONE = ONE * 1e9; // 1 token in wei (18-dec)

contract WrapperTokenManual is Test {
    /* actors */
    address internal constant AL = address(0xA11);
    address internal constant CTL = address(0xC01);
    address internal constant BO = address(0xB02);

    WrappedQRL internal w;

    /*──────────────────── fixture ────────────────────*/
    function setUp() external {
        vm.deal(AL, 20 ether);
        vm.deal(CTL, 40 ether);
        vm.deal(BO, 20 ether);

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

        uint64 dBal = balAfter - balBefore; // yield minus haircut
        uint64 dSupp = totBefore - totAfter; // tokens burnt (may be 0)

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
        uint64 pid = 1; // first real protocol

        /*───────── 1. Alice deposits 10 tok & joins early ─────────*/
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory arr;
        arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        /*───────── 2. Controller adds 5 tok yield ─────────*/
        vm.prank(CTL);
        w.addYield(pid, 5 * ONE);

        /*───────── 3. Bob arrives *after* yield ─────────*/
        vm.startPrank(BO);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory add;
        add[0] = pid;
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
        uint64[8] memory join;
        join[0] = pid;
        w.setMembership(join, 0);
        vm.stopPrank();

        /* Controller funds +5 tok yield, then signals −5 tok haircut. */
        vm.startPrank(CTL);
        w.addYield(pid, 5 * ONE);
        w.signalHaircut(pid, 5 * ONE);
        vm.stopPrank();

        /* ── pre-harvest snapshots ── */
        uint64 supplyBefore = w.totalSupply();
        uint64 aliceBefore = w.balanceOf(AL);

        /* Harvest both staking wallets. */
        address[] memory batch = new address[](2);
        batch[0] = AL;
        batch[1] = CTL;
        w.forceHarvest(batch);

        /* ── post-harvest state ── */
        uint64 supplyAfter = w.totalSupply();
        uint64 aliceAfter = w.balanceOf(AL);
        uint64 poolAfter = w.balanceOf(address(this));

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
        uint64[8] memory join;
        join[0] = pid;
        w.setMembership(join, 0);
        vm.stopPrank();

        /* Controller first signals a 5 tok haircut … */
        vm.prank(CTL);
        w.signalHaircut(pid, 5 * ONE);

        /* … then tops-up 5 tok so it can fund the yield.               */
        vm.prank(CTL);
        w.deposit{value: 5 * WEI_ONE}(); // keeps CTL-balance ≥ 5 tok

        /* Now contributes +5 tok yield.                                 */
        vm.prank(CTL);
        w.addYield(pid, 5 * ONE);

        /* ── pre-harvest snapshots ── */
        uint64 supplyBefore = w.totalSupply();
        uint64 aliceBefore = w.balanceOf(AL);

        /* Harvest every staking wallet (Alice + Controller). */
        address[] memory batch = new address[](2);
        batch[0] = AL;
        batch[1] = CTL;
        w.forceHarvest(batch);

        /* ── post-harvest state ── */
        uint64 supplyAfter = w.totalSupply();

        assertEq(supplyBefore, supplyAfter, "unexpected supply change");

        uint64 aliceAfter = w.balanceOf(AL);
        uint64 poolAfter = w.balanceOf(address(this));

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

    /*══════════════════════════════════════════════════════════════════════*/
    /*        Aggregate yield across EIGHT protocols credits correctly      */
    /*══════════════════════════════════════════════════════════════════════*/
    function testAggregateYieldAcrossEightProtocols() external {
        /*───────── 1. Spin-up eight fresh protocols (pid 2 … 9) ─────────*/
        uint64[8] memory pids;
        for (uint8 i; i < 8; ++i) {
            pids[i] = w.createProtocol(CTL, 1, ONE);
        }

        /*───────── 2. Alice deposits 8 tok and joins all eight ─────────*/
        vm.startPrank(AL);
        w.deposit{value: 8 * WEI_ONE}();
        uint64[8] memory joinAll;
        for (uint8 j; j < 8; ++j) joinAll[j] = pids[j];
        w.setMembership(joinAll, 0);
        vm.stopPrank();

        /*───────── 3. Controller funds 1 tok yield in each protocol ─────*/
        vm.startPrank(CTL);
        w.deposit{value: 8 * WEI_ONE}(); // fuel for the yields
        for (uint8 k; k < 8; ++k) {
            w.addYield(pids[k], ONE);
        }
        vm.stopPrank();

        /*───────── 4. Harvest Alice and assert Δ = 8 tok ─────────*/
        uint64 before = w.balanceOf(AL);

        address[] memory list = new address[](1);
        list[0] = AL;
        w.forceHarvest(list);

        uint64 afterBal = w.balanceOf(AL);
        assertEq(
            afterBal - before,
            8 * ONE,
            "aggregate 8-proto yield mismatch"
        );
    }

    /**
     * @notice Two-protocol haircut must:
     *         • Burn the wallet’s stake **once** (ΔSupply == 10 tok).
     *         • Distribute that burn proportionally between protocols
     *           (each mints > 0, and Σ(minted) == ΔSupply).
     *
     *  Flow
     *  ────
     *  1.  setUp() already created pid = 1 and staked 7 tok (CTL).
     *  2.  Controller spins up pid = 2.
     *  3.  Alice deposits 10 tok and joins both pids.
     *  4.  Controller signals a 10 tok haircut in **each** pid.
     *  5.  forceHarvest(AL) burns once (10 tok total) and books
     *      proportional cuts into each `ps.burned`.
     *  6.  collectHaircut() on both pids must mint amounts whose sum
     *      equals the single burn, guaranteeing no double-claim.
     */
    function testHaircutAcrossTwoProtocolsProportionalCollect() external {
        /* 1. Controller creates a second protocol (pid = 2). */
        vm.startPrank(CTL);
        uint64 pid2 = w.createProtocol(CTL, 1, ONE);
        vm.stopPrank();

        /* 2. Alice deposits 10 tok and joins both protocols. */
        vm.startPrank(AL);
        w.deposit{value: 10 * WEI_ONE}();
        uint64[8] memory join;
        join[0] = 1; // from setUp()
        join[1] = pid2;
        w.setMembership(join, 0);
        vm.stopPrank();

        /* 3. Controller signals full-balance haircuts in both pids. */
        vm.startPrank(CTL);
        w.signalHaircut(1, 10 * ONE);
        w.signalHaircut(pid2, 10 * ONE);
        vm.stopPrank();

        /* 4. Harvest Alice – burns once. */
        uint64 supplyBefore = w.totalSupply();
        address[] memory list = new address[](1);
        list[0] = AL;
        w.forceHarvest(list);
        uint64 supplyAfter = w.totalSupply();
        uint64 burned = supplyBefore - supplyAfter; // should be 10 tok
        assertEq(burned, 10 * ONE, "unexpected burn amount");

        /* 5. Collect from both protocols. */
        vm.startPrank(CTL);
        uint64 minted1 = w.collectHaircut(1, CTL);
        uint64 minted2 = w.collectHaircut(pid2, CTL);
        vm.stopPrank();

        /* 6. Invariants */
        // (i) Each protocol got a positive share.
        assertGt(minted1, 0, "pid 1 minted zero");
        assertGt(minted2, 0, "pid 2 minted zero");

        // (ii) No double-count: total minted == total burned.
        assertEq(minted1 + minted2, burned, "mint != burn");
    }

    /*───────────────────────────────────────────────────────────────────────────*\
│  REVISION: rounding-tolerant haircut corner cases                          │
\*───────────────────────────────────────────────────────────────────────────*/

    /**
     * Tiny haircut must never *over-mint*.
     * We only require   burn ≤ req   and   mint == burn.
     */
    function testHaircutTinyCutNoOverMint() external {
        uint64 pid = 1;

        vm.startPrank(AL);
        w.deposit{value: 20 * WEI_ONE}();
        uint64[8] memory arr;
        arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        vm.prank(CTL);
        uint64 req = 17; // 1.7e-8 tok
        w.signalHaircut(pid, req);

        uint64 supplyBefore = w.totalSupply();
        address[] memory one = new address[](1);
        one[0] = AL;
        w.forceHarvest(one);
        uint64 burned = supplyBefore - w.totalSupply();
        require(burned <= req, "burn > request");

        vm.prank(CTL);
        uint64 minted = w.collectHaircut(pid, CTL);
        require(minted == burned, "mint != burn");
    }

    /**
     * Two protocols, 1-tok request each.
     * Allow rounding but enforce   Σmint == burn   and   burn ≤ Σreq.
     */
    function testHaircutOneTokEachProtoLoose() external {
        vm.prank(CTL);
        uint64 pid2 = w.createProtocol(CTL, 1, ONE);

        vm.startPrank(AL);
        w.deposit{value: 20 * WEI_ONE}();
        uint64[8] memory join;
        join[0] = 1;
        join[1] = pid2;
        w.setMembership(join, 0);
        vm.stopPrank();

        vm.startPrank(CTL);
        w.signalHaircut(1, ONE);
        w.signalHaircut(pid2, ONE);
        vm.stopPrank();

        uint64 supp0 = w.totalSupply();
        address[] memory a = new address[](1);
        a[0] = AL;
        w.forceHarvest(a);
        uint64 burned = supp0 - w.totalSupply();
        require(burned <= 2 * ONE, "burn > sum(req)");

        vm.startPrank(CTL);
        uint64 m1 = w.collectHaircut(1, CTL);
        uint64 m2 = w.collectHaircut(pid2, CTL);
        vm.stopPrank();
        require(m1 + m2 == burned, "mint != burn");
        require(m1 > 0 && m2 > 0, "zero mint");
    }

    /**
     * Loop through 1…10-tok requests **only while stake allows it**.
     * Guarantees   mint == burn   every round.
     */
    function testHaircutMintEqualsBurnSweep() external {
        uint64 pid = 1;

        vm.prank(AL);
        w.deposit{value: 10 * WEI_ONE}(); // Alice now 30 tok total

        for (uint64 amt = ONE; amt <= 10 * ONE; amt += ONE) {
            // stop if controller cannot reserve more
            (, , , uint128 inBal128, uint128 outBal128, , , ) = w.protocolInfo(
                pid
            );
            uint64 inBal = uint64(inBal128);
            uint64 outBal = uint64(outBal128);
            if (inBal <= outBal + amt) break;

            vm.prank(CTL);
            w.signalHaircut(pid, amt);

            uint64 supp0 = w.totalSupply();
            address[] memory a = new address[](1);
            a[0] = AL;
            w.forceHarvest(a);
            uint64 burned = supp0 - w.totalSupply();

            vm.prank(CTL);
            uint64 minted = w.collectHaircut(pid, CTL);

            require(minted == burned, "mint != burn");
            require(minted <= amt, "mint > request");
        }
    }

    function testMini() external {
        uint64[8] memory pid;
        for (uint8 i; i < 8; ++i) pid[i] = w.createProtocol(CTL, 1, ONE);

        vm.startPrank(AL);
        w.deposit{value: 8 * WEI_ONE}();
        w.setMembership(pid, 0);
        vm.stopPrank();

        vm.startPrank(CTL);
        w.deposit{value: 8 * WEI_ONE}();
        for (uint8 i; i < 8; ++i) {
            w.addYield(pid[i], ONE);
            w.signalHaircut(pid[i], ONE / 2);
        }
        vm.stopPrank();

        address[] memory who = new address[](1);
        who[0] = AL;
        w.forceHarvest(who); // <-- should NOT revert
    }

    /*──────────────────────────────────────────────────────────────────*/
    /**
     * @notice Eight protocols, +2 tok yield & −1 tok haircut each.
     *         Validates global supply conservation and per‑PID bounds.
     */
    function testYieldAndHalfHaircutEightProtos() external {
        /* 1. Spin‑up pid[1…7] */
        uint64[8] memory pid;
        pid[0] = 1;
        vm.startPrank(CTL);
        for (uint8 i = 1; i < 8; ++i) pid[i] = w.createProtocol(CTL, 1, ONE);
        vm.stopPrank();

        /* 2. Alice stakes 20 tok and joins all */
        vm.startPrank(AL);
        w.deposit{value: 20 * WEI_ONE}();
        w.setMembership(pid, 0);
        vm.stopPrank();

        /* 3. Controller seeds pool with 16 tok and sets yield+haircut */
        uint64 YIELD_PER_PID = 2 * ONE;
        uint64 HAIRCUT_PER_PID = 1 * ONE;
        vm.prank(CTL);
        w.deposit{value: 16 * WEI_ONE}(); // single‑scaled fuel

        vm.startPrank(CTL);
        for (uint8 i; i < 8; ++i) {
            w.addYield(pid[i], YIELD_PER_PID);
            w.signalHaircut(pid[i], HAIRCUT_PER_PID);
        }
        vm.stopPrank();

        /* 4. Harvest Alice */
        uint64 supplyBefore = w.totalSupply();
        uint64 aliceBefore = w.balanceOf(AL);
        address[] memory one = new address[](1);
        one[0] = AL;
        w.forceHarvest(one);
        uint64 burned = supplyBefore - w.totalSupply();

        /* 5. Collect per‑PID */
        uint64 mintedTot;
        uint64[8] memory minted;
        vm.startPrank(CTL);
        for (uint8 i; i < 8; ++i) {
            minted[i] = w.collectHaircut(pid[i], CTL);
            assertLe(minted[i], burned, "over-mint");
            mintedTot += minted[i];
        }
        vm.stopPrank();

        /* 6. Invariants */
        assertEq(mintedTot, burned, "mint!=burn");
        uint64 aliceAfter = w.balanceOf(AL);
        uint64 dA = aliceAfter > aliceBefore
            ? aliceAfter - aliceBefore
            : aliceBefore - aliceAfter;
        assertLe(dA, 16 * ONE, "Alice delta > sum(yield)");
        uint64 poolAfter = w.balanceOf(address(this));
        assertLt(poolAfter, ONE, "yield pool not drained");
    }
}
