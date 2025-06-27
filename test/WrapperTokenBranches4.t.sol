// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/StdStorage.sol";
import "lib/forge-std/src/StdError.sol";
import "../src/_native.sol";
import "../src/IZ156Flash.sol";

/*──────── Constants ───────*/
uint64  constant ONE      = 1e8;
uint256 constant WEI_ONE  = ONE * 1e10;

/*──────────────── Borrower stubs ────────────────*/
contract WrongMagicBorrower is IZ156FlashBorrower {
    function onFlashLoan(
        address, address, uint64, uint64, bytes calldata
    ) external pure override returns (bytes32) {
        return bytes32(0);                        // triggers `"cb"` revert
    }
}

contract NoRepayBorrower is IZ156FlashBorrower {
    function onFlashLoan(
        address, address, uint64, uint64, bytes calldata
    ) external pure override returns (bytes32) {
        return keccak256("IZ156.ok");             // never approves → `"repay"` revert
    }
}

/*──────────────── Test-suite ────────────────────*/
using stdStorage for StdStorage;                  // library helpers

contract WrappedQRL_MissingBranchCoverage is Test {
    address constant CTRL = address(0xC0FE);

    WrappedQRL w;

    function setUp() public {
        vm.deal(address(this), WEI_ONE);
        w = new WrappedQRL{value: WEI_ONE}();     // 1 token pre-mint
    }

    /*──────── Supply-cap guard ────────*/
    function testDepositCapReverts() public {
        // force _tot (totalSupply) to uint64.max
        uint256 slot = stdstore
            .target(address(w))
            .sig("totalSupply()")
            .find();
        vm.store(
            address(w),
            bytes32(slot),
            bytes32(uint256(type(uint64).max))
        );

        vm.deal(address(this), WEI_ONE);
        vm.expectRevert(stdError.arithmeticError); // overflow before "cap"
        w.deposit{value: WEI_ONE}();
    }

    /*──────── Access-control on setMinStake ────────*/
    function testSetMinStakeUnauthorizedReverts() public {
        uint64 pid = w.createProtocol(CTRL, 0, ONE);

        vm.expectRevert(bytes("ctrl"));
        w.setMinStake(pid, ONE * 2);              // caller ≠ controller
    }

    /*──────── memberInfo() “empty” guard ────────*/
    function testMemberInfoEmptyReverts() public {
        vm.expectRevert(bytes("empty"));
        w.memberInfo(address(this), 0);           // slot vacant
    }

    /*──────── Flash-loan bad magic (“cb”) ────────*/
    function testFlashLoanCallbackMismatchReverts() public {
        WrongMagicBorrower b = new WrongMagicBorrower();

        vm.expectRevert(bytes("cb"));
        vm.prank(address(b));
        w.flashLoan(b, address(w), ONE, "");
    }

    /*──────── Flash-loan repay shortfall (“repay”) ────────*/
    function testFlashLoanRepayShortfallReverts() public {
        NoRepayBorrower b = new NoRepayBorrower();

        vm.expectRevert(bytes("repay"));
        vm.prank(address(b));
        w.flashLoan(b, address(w), ONE, "");
    }

    /*──────── addYield() zero-amount guard ────────*/
    function testAddYieldZeroReverts() public {
        uint64 pid = w.createProtocol(CTRL, 0, ONE);

        // controller stakes and joins so inBal > 0
        vm.deal(CTRL, WEI_ONE);
        vm.startPrank(CTRL);
        w.deposit{value: WEI_ONE}();
        uint64[8] memory arr; arr[0] = pid;
        w.setMembership(arr, 0);
        vm.stopPrank();

        vm.expectRevert(bytes("zero"));
        w.addYield(pid, 0);
    }
}
