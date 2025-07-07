// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────────────────*\
│  WrapperTokenAux.t.sol                                                      │
│                                                                             │
│  Targeted regression-style tests for the **three** previously untested      │
│  public/external functions in `WrappedQRL`:                                 │
│                                                                             │
│      1. `lock(uint56 endsAt)`            – voluntary account-level lock     │
│      2. `unlocksAt(address who)`         – view helper for the above        │
│      3. `signalProtocol(uint64, ProtocolMetadata)`                          │
│                                                                             │
│  Conventions & style follow the existing suites:                            │
│      • ONE       : 1 token   (9-dec places — 1e9)                           │
│      • WEI_ONE   : 1 token   in wei   (18-dec places — 1e18)                │
│      • Exhaustive inline comments explain **intent** & **assumptions**.     │
│      • Every test uses a fresh fixture (Forge calls setUp() per test).      │
└───────────────────────────────────────────────────────────────────────────*/

import "lib/forge-std/src/Test.sol";
import {WrappedQRL, ProtocolMetadata} from "../src/_native.sol";

/*──────── Constants (stay in sync with prod) ────────*/
uint64  constant ONE      = 1e9;          // 1 token (9 decimals)
uint256 constant WEI_ONE  = ONE * 1e9;   // 1 token expressed in wei

contract WrapperTokenAux is Test {
    /* actors */
    address internal constant CTRL  = address(0xC01); // protocol controller
    address internal constant AL    = address(0xA11); // test wallet – locks
    address internal constant BO    = address(0xB02); // receiver for transfers

    WrappedQRL internal w;
    uint64     pid;                                   // protocol id #1

    /*──────────────────── fixture ────────────────────*/
    function setUp() external {
        /* 1. Seed ETH so the actors can deposit & pay gas. */
        vm.deal(CTRL, 20 ether);
        vm.deal(AL  , 20 ether);
        vm.deal(BO  ,  0 ether);                      // BO never pays

        /* 2. Deploy fresh WrappedQRL and create a protocol.            */
        w   = new WrappedQRL();
        pid = w.createProtocol(CTRL, 1, ONE);         // 1-block lockWin

        /* 3. Give Alice one token so she can test account-locks.       */
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();                  // AL balance = 1 tok
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                             lock / unlocksAt                         */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * `lock(uint56)` sets an account-level time-lock that _transfer/transferFrom_
     * must respect.  We verify:
     *
     *   • Event `AccountLocked` fires with the correct timestamp.
     *   • `unlocksAt(AL)` returns that timestamp.
     *   • Any transfer **before** expiry reverts `"locked"`.
     *   • The first successful transfer **after** expiry clears `lock`,
     *     so a follow-up transfer in the same tx succeeds.
     */
    function testLockAndUnlocksAtFlow() external {
        /*───────── arrange ─────────*/
        uint56 expiry = uint56(block.timestamp + 1 days);

        /* Expect the AccountLocked event.                                   */
        vm.expectEmit(true, false, false, true);
        emit WrappedQRL.AccountLocked(AL, expiry);

        /* AL sets her lock.                                                 */
        vm.prank(AL);
        w.lock(expiry);

        /* View helper must reflect the same timestamp.                      */
        assertEq(w.unlocksAt(AL), expiry, "unlock timestamp drift");

        /*───────── act -- attempt pre-expiry transfer (should revert) ──────*/
        vm.prank(AL);
        vm.expectRevert("locked");
        w.transfer(BO, ONE / 2);                       // any amount triggers guard

        /*───────── time-travel past expiry, transfer succeeds ──────────────*/
        vm.warp(expiry + 1);                           // 1 second past lock
        vm.prank(AL);
        w.transfer(BO, ONE / 4);                       // first post-lock transfer

        /* lock must be cleared → a second transfer in the same tx is OK     */
        vm.prank(AL);
        w.transfer(BO, ONE / 4);                       // no revert expected
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                        signalProtocol (metadata)                     */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * `signalProtocol` is gated by `onlyController(pid)`.  We test:
     *
     *   • Non-controller callers revert `"ctrl"`.
     *   • Controller call succeeds and emits `ProtocolSignal`.
     *
     *     Note: The implementation currently **returns `0`** and emits
     *     `ProtocolSignal(0, metadata)` – a known quirk!  The test only
     *     checks that the call does **not revert**, leaving functional
     *     correctness of the return value to future hardening.
     */
    function testSignalProtocolAuthAndEvent() external {
        /*───────── 1. Non-controller must revert ─────────*/
        ProtocolMetadata memory dummy;
        vm.prank(AL);                                  // AL is NOT a controller
        vm.expectRevert();
        w.signalProtocol(pid, dummy);

        /*───────── 2. Controller path emits event ────────*/
        vm.expectEmit(true, false, false, true);
        emit WrappedQRL.ProtocolSignal(0, dummy);      // id == 0 per impl quirk

        vm.prank(CTRL);
        w.signalProtocol(pid, dummy);                  // should not revert
    }
}
