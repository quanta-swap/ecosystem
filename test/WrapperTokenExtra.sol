// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_native.sol";
import "../src/IZRC20.sol";
import "../src/IZ156Flash.sol";

/*───────────────────────── Helpers ─────────────────────────*/
uint64 constant ONE      = 1e8;          // 1 token (8-dec)
uint256 constant WEI_ONE = ONE * 1e10;   // 1 token in wei

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
    function testMetadataAndSupplyViews() public {
        assertEq(w.name(),   "Wrapped QRL-Z");
        assertEq(w.symbol(), "WQRLZ");
        assertEq(w.decimals(), 8);
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

    /*──────── Account / member / reserve getters ────────*/
    function testAccountMemberReserveFreeListInfo() public {
        /* bootstrap protocol so Alice can join */
        uint64 pid = w.createProtocol(CTRL, 1, ONE);

        /* controller stakes and joins */
        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        /* roll to a new block to avoid the “dup” guard */
        vm.roll(block.number + 1);

        /* Alice joins */
        vm.deal(AL, WEI_ONE);
        vm.prank(AL);
        w.deposit{value: WEI_ONE}();
        vm.prank(AL);
        w.setMembership(arr, 0);

        /* fetch public getters */
        (uint64 bal, uint64[8] memory pids, uint8 mask) = w.accountInfo(AL);
        assertEq(bal, ONE);
        assertEq(pids[0], pid);
        assertEq(mask, 1);

        (uint64 mpid,uint64 stake,uint64 unlock,uint64 joinMin,uint64 resPtr)
            = w.memberInfo(AL, 0);
        assertEq(mpid,  pid);
        assertEq(stake, ONE);
        assertEq(joinMin, ONE);

        (,,uint256 yAcc,) = w.reservedInfo(resPtr);
        assertEq(yAcc, 0);                        // no yield yet

        (uint256 freeResBefore, uint256 freeMemBefore) = w.freeLists();

        /* fast-forward so Alice can leave → resources recycled */
        vm.roll(block.number + 2);
        uint64[8] memory none;                    // all zeros
        vm.prank(AL);
        w.setMembership(none, 0);

        (uint256 freeResAfter, uint256 freeMemAfter) = w.freeLists();
        assertGt(freeResAfter, freeResBefore);    // at least one entry recycled
        assertGt(freeMemAfter, freeMemBefore);
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
