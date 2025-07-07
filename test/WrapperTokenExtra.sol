// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";
import "../src/IZRC20.sol";
import "../src/IZ156Flash.sol";

/*───────────────────────── Helpers ─────────────────────────*/
uint64 constant ONE      = 1e9;          // 1 token (8-dec)
uint256 constant WEI_ONE = ONE * 1e9;   // 1 token in wei

/* very thin borrower used for the flash-loan happy-path */
contract FlashBorrower is IZ156FlashBorrower {
    IZRC20 immutable tok;
    constructor(IZRC20 t) { tok = t; }

    function onFlashLoan(
        address initiator,
        address token,
        uint64 amount,
        uint64 /*fee*/,
        bytes calldata /*data*/
    ) external override returns (bytes32) {
        require(msg.sender == initiator,   "initiator");
        require(token       == address(tok),"token");
        tok.approve(initiator, amount);                // grant repayment
        return keccak256("IZ156.ok");
    }
}

/*──────────────────── Full-coverage test ───────────────────*/
contract WrappedQRLCoverage is Test {
    address constant CTRL = address(0xC0FE);
    address constant AL   = address(0xA11);

    WrappedQRL  w;

    /* basic one-token mint in constructor */
    function setUp() public {
        vm.deal(address(this), WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();
    }

    /*────────── Static metadata / view paths ──────────*/
    function testMetadataAndSupplyViews() public view {
        assertEq(w.name(),   "Wrapped QRL-Z");
        assertEq(w.symbol(), "WQRLZ");
        assertEq(w.decimals(), 9);
        assertEq(w.totalSupply(), ONE);
        assertEq(w.maxFlashLoan(address(w)), type(uint64).max - ONE); // sanity
        assertEq(w.flashFee(address(w), ONE), 0);
    }

    /*──────── Protocol creation + min-stake updates ────────*/
    function testCreateProtocolAndSetMinStake() public {
        uint64 pid = w.createProtocol(CTRL, 2, ONE);
        (address ctrl,,,,,,,) = w.protocolInfo(pid);
        assertEq(ctrl, CTRL);

        vm.prank(CTRL);
        w.setMinStake(pid, ONE * 2);
        (,uint64 newMinStake,,,,,,) = w.protocolInfo(pid);
        assertEq(newMinStake, ONE * 2);

        vm.expectRevert(); // ctrl         // only controller may update
        w.setMinStake(pid, 0);
    }

    /**
     * @notice
     *     End-to-end sanity check for the trio of public getters:
     *       • `accountInfo()`  – top-level balance / slot bitmap / pid list
     *       • `memberInfo()`   – per-slot membership snapshot
     *       • `reservedInfo()` – underlying protocol-level reserve snapshot
     *     It also verifies that leaving the protocol recycles the `Reserved` and
     *     `Member` structs back onto their free-lists.
     *
     * @dev
     *     Execution flow
     *     ───────────────
     *     1. Controller creates a protocol (1-second lock window) and stakes 1 token.
     *     2. We increment both wall-clock **and block height** so Alice’s join runs
     *        in a fresh block, avoiding the duplicate-join guard that keys off
     *        `block.number`.
     *     3. Alice deposits 1 token and joins the same protocol.
     *     4. Assertions confirm that all getter snapshots match the expected state.
     *     5. We fast-forward two hours (timestamp **and** block height again) so
     *        Alice’s lock expires, then she leaves the protocol.
     *     6. Free-list counters must grow — proving the `Reserved` and `Member`
     *        entries were recycled.
     *
     *     Constants
     *     ──────────
     *       • `ONE`      – exactly 1 token in 9-dec units (`1e9` wei).
     *       • `WEI_ONE`  – 1 token expressed in wei (helper constant for deposits).
     *
     *     Cheat-codes used
     *     ────────────────
     *       • `vm.deal(addr, wei)`    – fund an address with native ETH.
     *       • `vm.startPrank(addr)`   – subsequent calls use `addr` as `msg.sender`.
     *       • `vm.stopPrank()`        – restore original `msg.sender`.
     *       • `vm.warp(ts)`           – set *next* block’s `timestamp`.
     *       • `vm.roll(bn)`           – set *next* block’s `number`.
     */
    function testAccountMemberReserveFreeListInfo() public {
        /*────────────────── 1. Controller bootstrap ──────────────────*/
        uint64 pid = w.createProtocol(CTRL, 1, ONE);        // 1-s lock window

        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);                                // ≡ msg.sender = CTRL
        w.deposit{value: WEI_ONE}();                        // mint 1 token
        uint64[8] memory arr; arr[0] = pid;                 // join-list
        w.setMembership(arr, 0);                            // CTRL joins
        vm.stopPrank();

        /*────────────────── 2. Advance time & height ─────────────────*/
        vm.warp(block.timestamp + 1 hours);                 // wall-clock +1 h
        vm.roll(block.number + 1);                          // new block → bypass “dup”

        /*──────────────────── 3. Alice joins ────────────────────────*/
        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();                        // mint 1 token

        vm.prank(AL);
        w.setMembership(arr, 0);                            // Alice joins pid

        /*────────────────── 4. Getter assertions ────────────────────*/
        (uint64 bal, uint64[8] memory pids, uint8 mask) = w.accountInfo(AL);
        assertEq(bal, ONE,            "balance snapshot wrong");
        assertEq(pids[0], pid,        "pid list snapshot wrong");
        assertEq(mask, 1,             "slot-mask snapshot wrong");

        (uint64 mpid,
        uint64 stake,
        uint64 unlock,
        uint64 joinMin,
        uint64 resPtr) = w.memberInfo(AL, 0);

        assertEq(mpid,   pid,         "member pid incorrect");
        assertEq(stake,  ONE,         "stake snapshot incorrect");
        assertGt(unlock, block.timestamp, "unlock must be in the future");
        assertEq(joinMin, ONE,        "joinMin snapshot incorrect");

        ( , , uint256 yAcc, ) = w.reservedInfo(resPtr);
        assertEq(yAcc, 0,             "yield accumulator should start at 0");

        (uint256 freeResBefore, uint256 freeMemBefore) = w.freeLists();

        /*──────────────── 5. Alice leaves after lock ────────────────*/
        vm.warp(block.timestamp + 2 hours);                 // surpass 1-s lock
        vm.roll(block.number + 1);                          // fresh block again

        uint64[8] memory none;                              // empty add-list
        vm.prank(AL);
        w.setMembership(none, 0);                           // exit all slots

        /*──────────────── 6. Free-list growth checks ───────────────*/
        (uint256 freeResAfter, uint256 freeMemAfter) = w.freeLists();
        assertGt(freeResAfter, freeResBefore, "Reserved free-list did not grow");
        assertGt(freeMemAfter, freeMemBefore, "Member free-list did not grow");
    }

    /*──────── Flash-loan happy path & repeated borrow ───────*/
    function testFlashLoanRoundTripsAndRepeats() public {
        FlashBorrower borrower = new FlashBorrower(IZRC20(address(w)));

        uint64 max = w.maxFlashLoan(address(w));

        /* first loan succeeds */
        vm.prank(address(borrower));
        assertTrue(w.flashLoan(borrower, address(w), max, ""));

        /* supply is back to original → second identical loan succeeds too */
        vm.prank(address(borrower));
        assertTrue(w.flashLoan(borrower, address(w), max, ""));
    }

    /*──────── Flash-loan failure when exceeding cap ───────*/
    function testFlashLoanExceedsCapReverts() public {
        FlashBorrower borrower = new FlashBorrower(IZRC20(address(w)));

        uint64 cap = w.maxFlashLoan(address(w));
        uint64 tooMuch = cap + 1;                 // one unit over

        vm.expectRevert("supply");
        vm.prank(address(borrower));
        w.flashLoan(borrower, address(w), tooMuch, "");
    }
}
