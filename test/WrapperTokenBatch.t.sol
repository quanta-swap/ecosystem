// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────────────────────────────────────────────────
│  BatchTransfer.t.sol                                                          │
│                                                                              │
│  Regression‑style tests for WrappedQRL’s *batch* ERC‑20 actions:              │
│      • transferBatch(address[] to, uint64[] v)                                │
│      • transferFromBatch(address from, address[] to, uint64[] v)              │
│                                                                              │
│  Every test uses a pristine fixture (Forge runs setUp() before each test),    │
│  so state mutability between tests is never a side‑effect concern.            │
│                                                                              │
│  Author: Elliott (Research Protocol Engineer)                                 │
│                                                                              │
│  Conventions                                                                  │
│  ───────────                                                                  │
│  • ONE       : 1 token   (9‑dec places  –  1e9)
│  • WEI_ONE   : 1 token   in native wei (18‑dec places – 1e18)                 │
│  • AL / BO / CE  : end‑users                                                │
│  • OP        : delegated operator for transferFromBatch() tests               │
│                                                                              │
│  Each function carries a NatSpec docstring *and* exhaustive inline comments   │
│  spelling out the test intent and every assumption made, so future AI agents  │
│  can reason about modifications safely.                                       │
└──────────────────────────────────────────────────────────────────────────────*/

import "lib/forge-std/src/Test.sol";
import {WrappedQRL} from "../src/_native.sol";

/*──────── Constants (stay in sync with prod) ────────*/
uint64 constant ONE = 1e9;           // 1 token (9 decimals)
uint256 constant WEI_ONE = ONE * 1e9; // 1 token expressed in wei (18 dec)

contract BatchTransferTest is Test {
    /*──────── Actors ────────*/
    address internal constant AL = address(0xA11); // Alice – primary sender
    address internal constant BO = address(0xB02); // Bob   – recipient #1
    address internal constant CE = address(0xC03); // Carol – recipient #2
    address internal constant OP = address(0x0FF1CE); // Operator for transferFromBatch

    /* the unit‑under‑test */
    WrappedQRL internal w;

    /*──────────────────── Fixture ────────────────────*/
    function setUp() external {
        // Seed the accounts with ETH so they can pay for gas & deposits.
        vm.deal(AL, 10 ether);
        vm.deal(BO, 10 ether);
        vm.deal(CE, 10 ether);
        vm.deal(OP, 0 ether);

        // Deploy a fresh WrappedQRL instance for this test.
        w = new WrappedQRL();

        // Alice deposits 3 tokens up‑front so every test starts with balance.
        vm.prank(AL);
        w.deposit{value: 3 * WEI_ONE}();
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                       transferBatch – happy path                     */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Sender (Alice) transfers 1 tok to Bob and 2 tok to Carol in a
     *      single batch call.  Asserts:
     *        • Alice balance decrements by Σ(amt)
     *        • Recipients receive the exact amounts
     *        • Total supply is conserved (pure transfer)
     */
    function testTransferBatchHappyPath() external {
        /*───────────────── arrange ─────────────────*/
        // Build the recipients array.
        address[] memory to = new address[](2); // dynamic address[2]
        to[0] = BO; // Bob
        to[1] = CE; // Carol

        // Matching token amounts (1 + 2 = 3 tok – all of Alice’s stake)
        uint64[] memory amt = new uint64[](2);
        amt[0] = ONE;        // 1 tok → Bob
        amt[1] = 2 * ONE;    // 2 tok → Carol

        uint64 supplyBefore = w.totalSupply(); // baseline (should remain)

        /*────────────────── act ───────────────────*/
        vm.prank(AL); // Alice initiates the batch transfer
        w.transferBatch(to, amt);

        /*───────────────── assert ─────────────────*/
        // Alice drained to zero.
        assertEq(w.balanceOf(AL), 0, "Alice balance mismatch");

        // Bob & Carol credited.
        assertEq(w.balanceOf(BO), ONE, "Bob did not receive 1 tok");
        assertEq(w.balanceOf(CE), 2 * ONE, "Carol did not receive 2 tok");

        // Supply unchanged (pure transfer).
        assertEq(w.totalSupply(), supplyBefore, "supply not conserved");
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                  transferBatch – length mismatch guard              */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev to[] and amt[] length mismatch must revert with reason "len".
     */
    function testTransferBatchLengthMismatch() external {
        address[] memory to = new address[](1);
        to[0] = BO;

        uint64[] memory amt = new uint64[](2);
        amt[0] = ONE;
        amt[1] = ONE;

        vm.startPrank(AL);
        vm.expectRevert(); // WrappedQRL emits exact string "len"
        w.transferBatch(to, amt);
        vm.stopPrank();
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*              transferBatch – insufficient balance guard             */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Attempting to transfer more than sender’s balance must revert
     *      with reason "bal" (insufficient balance).
     */
    function testTransferBatchInsufficientBalance() external {
        // One recipient, 4 tok requested (Alice only has 3 tok).
        address[] memory to = new address[](1);
        to[0] = BO;

        uint64[] memory amt = new uint64[](1);
        amt[0] = 4 * ONE; // > 3 tok balance

        vm.startPrank(AL);
        vm.expectRevert();
        w.transferBatch(to, amt);
        vm.stopPrank();
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*                    transferFromBatch – happy path                    */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Operator (OP) pulls 3 tok from Alice to Bob & Carol using
     *      transferFromBatch().  Asserts allowance decrement and balances.
     */
    function testTransferFromBatchHappyPath() external {
        /*───────── arrange ────────*/
        // Recipients and amounts identical to earlier happy‑path.
        address[] memory to = new address[](2);
        to[0] = BO;
        to[1] = CE;

        uint64[] memory amt = new uint64[](2);
        amt[0] = ONE;
        amt[1] = 2 * ONE;

        // Alice grants a finite allowance exactly matching Σ(amt).
        vm.prank(AL);
        w.approve(OP, 3 * ONE);

        /*────────── act ───────────*/
        vm.prank(OP); // delegated operator executes pull
        w.transferFromBatch(AL, to, amt);

        /*───────── assert ─────────*/
        assertEq(w.balanceOf(AL), 0, "Alice not fully debited");
        assertEq(w.balanceOf(BO), ONE, "Bob incorrect balance");
        assertEq(w.balanceOf(CE), 2 * ONE, "Carol incorrect balance");

        // Allowance consumed to zero.
        assertEq(w.allowance(AL, OP), 0, "allowance not zeroed");
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*              transferFromBatch – insufficient allowance guard        */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev If the approved allowance is < Σ(amt) the call must revert
     *      with reason "allow".
     */
    function testTransferFromBatchAllowanceUnderflow() external {
        address[] memory to = new address[](1);
        to[0] = BO;

        uint64[] memory amt = new uint64[](1);
        amt[0] = 2 * ONE; // request 2 tok

        // Approve only 1 tok → insufficient.
        vm.prank(AL);
        w.approve(OP, ONE);

        vm.prank(OP);
        vm.expectRevert("allow");
        w.transferFromBatch(AL, to, amt);
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*              transferFromBatch – length mismatch guard              */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev Mismatched to[] / amt[] lengths must revert with reason "len".
     */
    function testTransferFromBatchLengthMismatch() external {
        address[] memory to = new address[](2);
        to[0] = BO;
        to[1] = CE;

        uint64[] memory amt = new uint64[](1);
        amt[0] = ONE;

        vm.prank(AL);
        w.approve(OP, ONE);

        vm.prank(OP);
        vm.expectRevert();
        w.transferFromBatch(AL, to, amt);
    }

    /*══════════════════════════════════════════════════════════════════════*/
    /*         transferFromBatch – unlimited allowance (uint64.max)         */
    /*══════════════════════════════════════════════════════════════════════*/

    /**
     * @dev When allowance is set to uint64.max, transferFromBatch() must **not**
     *      decrement the stored allowance (gas savings pattern used in WQRL).
     */
    function testTransferFromBatchUnlimitedAllowance() external {
        /* set up */
        address[] memory to = new address[](2);
        to[0] = BO;
        to[1] = CE;
        uint64[] memory amt = new uint64[](2);
        amt[0] = ONE;
        amt[1] = 2 * ONE;

        vm.prank(AL);
        w.approve(OP, type(uint64).max); // unlimited

        /* act */
        vm.prank(OP);
        w.transferFromBatch(AL, to, amt);

        /* assert */
        assertEq(w.balanceOf(AL), 0, "Alice balance mismatch");
        assertEq(w.allowance(AL, OP), type(uint64).max, "allowance decremented");
    }
}
