// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";

/*───────────────────────── Helpers ─────────────────────────*/
uint64  constant ONE      = 1e9;           // token units (8-dec)
uint256 constant WEI_ONE  = ONE * 1e9;    // wei per token (scale = 1e10)

/*───────────────────────── Test Suite ──────────────────────*/
contract WrappedQRL_ViewCoverage is Test {
    address constant CTRL = address(0xC0FE);
    address constant AL   = address(0xA11);

    WrappedQRL w;

    function setUp() public {
        /* mint one token into the test contract via constructor */
        vm.deal(address(this), WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();
    }

    /*──────── 1. protocolCount / protocolInfo coverage ───────*/
    function testProtocolCountAndInfo() public {
        uint64 pid1 = w.createProtocol(CTRL, 5, ONE);     // lockWin = 5 blocks
        uint64 pid2 = w.createProtocol(AL,   0, ONE * 2); // minStake = 2 tokens

        /* slot-zero dummy entry + two created above */
        assertEq(w.protocolCount(), 3);

        (address c1, uint64 ms1, uint64 lw1,,,,,) = w.protocolInfo(pid1);
        assertEq(c1, CTRL);
        assertEq(ms1, ONE);
        assertEq(lw1, 5);

        (address c2, uint64 ms2, uint64 lw2,,,,,) = w.protocolInfo(pid2);
        assertEq(c2, AL);
        assertEq(ms2, ONE * 2);
        assertEq(lw2, 0);
    }

    /* helper to fund / deposit / join */
    function _join(address who, uint64 pid, uint256 weiAmt) internal {
        vm.deal(who, weiAmt);
        vm.prank(who);
        w.deposit{value: weiAmt}();
        uint64[8] memory arr; arr[0] = pid;
        vm.prank(who);
        w.setMembership(arr, 0);
    }

    /// @notice
    ///     Verifies that a second wallet can join a protocol in a **new block**
    ///     without triggering the duplicate-join guard, and that both
    ///     `memberInfo()` and `reservedInfo()` return the expected snapshots.
    ///
    /// @dev
    ///     ─ Preconditions ─
    ///     • Controller (`CTRL`) has already deposited and approved its tokens.
    ///     • Alice (`AL`) has already deposited and approved her tokens.
    ///     • Helper `_join()` stakes `amountWei / 1e9` tokens for the caller.
    ///
    ///     ─ Test flow ─
    ///     1. Controller creates a protocol with a 1-second lock window and
    ///        immediately joins, staking 2 tokens.
    ///     2. We **advance wall-clock time _and_ block height** so the next join
    ///        executes in a fresh block (the duplicate guard keys off
    ///        `block.number`, not `block.timestamp`).
    ///     3. Alice joins the same protocol, staking 1 token.
    ///     4. Assert that all on-chain snapshots reflect the combined state.
    ///
    ///     ─ Why both `warp` _and_ `roll`? ─
    ///     • `vm.warp()` changes `block.timestamp` only.  
    ///     • The duplicate-join guard stores the current **block number** in
    ///       `_mark[pid]`, so we also need `vm.roll()` to bump `block.number`.
    ///
    ///     ─ Assumptions ─
    ///     • `ONE` represents exactly 1 token (scaled to 9 decimals).
    ///     • `WEI_ONE` is 1 token denominated in wei ( `1e9` ).
    function testMemberAndReservedInfo() public {
        // ───────────────────────── 1. Setup ──────────────────────────
        uint64 pid = w.createProtocol(CTRL, 1, ONE); // 1-second lock window
        _join(CTRL, pid, WEI_ONE * 2);               // Controller stakes 2

        // ───────────────── Advance time & height ─────────────────────
        vm.warp(block.timestamp + 1 hours); // move wall-clock forward
        vm.roll(block.number + 1);          // move to the next block

        // ───────────────────────── 2. Action ─────────────────────────
        _join(AL, pid, WEI_ONE);            // Alice stakes 1

        // ───────────────────── 3. Assertions (member) ────────────────
        (uint64 mpid,
        uint64 stake,
        uint64 unlock,
        uint64 joinMin,
        uint64 rPtr) = w.memberInfo(AL, 0);

        assertEq(mpid,  pid,   "member pid mismatch");
        assertEq(stake, ONE,   "stake snapshot incorrect");
        assertGt(unlock, block.timestamp, "unlock should be in the future");
        assertEq(joinMin, ONE, "joinMin snapshot incorrect");

        // ───────────────────── 4. Assertions (reserved) ──────────────
        (uint128 inS,
        uint128 outS,
        uint256 yS,
        uint64  jm) = w.reservedInfo(rPtr);

        assertEq(inS, 3 * ONE, "total stake snapshot incorrect"); // 2 + 1
        assertEq(outS, 0,      "haircut snapshot should be zero");
        assertEq(yS,  0,       "yield accumulator snapshot should be zero");
        assertEq(jm,  ONE,     "joinMin reserved snapshot incorrect");
    }


    /*──────── 3. receive() fallback deposit coverage ─────────*/
    function testReceiveDeposit() public {
        uint64 balBefore = w.balanceOf(address(this));

        vm.deal(address(this), WEI_ONE);
        /* empty-calldata send triggers WrappedQRL.receive() */
        (bool ok, ) = address(w).call{value: WEI_ONE}("");
        require(ok, "native send failed");

        assertEq(w.balanceOf(address(this)), balBefore + ONE);
    }

    /*──────── 4. unlimited-allowance branch in transferFrom ──*/
    function testUnlimitedAllowanceNotDecremented() public {
        /* Alice mints one token */
        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();

        /* grant MAX allowance to this test contract */
        vm.prank(AL);
        w.approve(address(this), type(uint64).max);

        uint64 allowBefore = w.allowance(AL, address(this));

        /* pull half a token – allowance should stay MAX */
        w.transferFrom(AL, address(0xBEEF), ONE / 2);
        assertEq(w.allowance(AL, address(this)), allowBefore);
    }
}
