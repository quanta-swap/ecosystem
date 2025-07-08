// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

///  ─────────────────────────────────────────────────────────────────────────────
///  WrappedQRL – comprehensive functional & invariance tests
///
///  • Uses forge-std’s `Test` cheat-codes for balance setup and revert oracles.
///  • All public mutators are covered, including batch helpers and allowance
///    edge-cases.  Re-entrancy protection is proven with a malicious receiver.
///  • Every *effect* (balances, totalSupply, allowances, ETH vault) is checked
///    after each action.  Invariants are re-asserted where relevant.
///  • All numbers are 64-bit; `uint256` is used only for intermediate math.
///
///  Assumptions
///  ───────────
///  • Native QRL uses **18 decimals** (wei), WQRL uses **9 decimals**.
///  • 1 QRL native  ==  1e9 WQRL units  (↔ `_SCALE` inside the wrapper).
///  • No yield / flash / governance extensions exist in the contract under test.
///
///  Run       :  forge test -vv
///  Coverage  :  forge coverage -vv
///  ────────────────────────────────────────────────────────────────────────────
import "lib/forge-std/src/Test.sol";
import {WrappedQRL, ReentrancyGuard, IZRC20} from "../src/_simple.sol"; // adjust path if needed

/* ─────────────────── helpers & constants ─────────────────── */
uint256 constant ONE_QRL_WEI = 1e18; // 1 native QRL (18-dec)
uint64 constant ONE_WQRL = 1e9; // 1 wrapped unit  (9-dec)
uint256 constant SCALE = 1e9; // wei → tok conversion factor

/* 2 ─ withdraw path where ETH send fails → “native send” revert  */
contract _BadRecv {
    WrappedQRL private immutable w;
    constructor(WrappedQRL _w) {
        w = _w;
    }

    /// Wrap 1 QRL then try to withdraw – receive() always reverts.
    function trigger() external payable {
        w.deposit{value: msg.value}();
        w.withdraw(uint64(msg.value / SCALE));
    }
    receive() external payable {
        revert("nope");
    }
}

/*──────────────────────────────────────────────────────────────────────────────\
│  Reenterer – malicious contract that tries to call WrappedQRL.deposit again  │
│               from its receive() fallback to prove the guard works.          │
\*──────────────────────────────────────────────────────────────────────────────*/
contract Reenterer {
    WrappedQRL private immutable _w;
    bool private _armed;

    constructor(WrappedQRL w) payable {
        _w = w;
    }

    function arm() external {
        _armed = true;
    }

    /// Wrap some QRL first so we have tokens to withdraw.
    function prime() external payable {
        _w.deposit{value: msg.value}();
    }

    /// Start the first withdraw (re-entry happens in receive()).
    function attack(uint64 amt) external {
        _w.withdraw(amt);
    }

    receive() external payable {
        if (_armed) {
            _armed = false;
            _w.withdraw(1); // second (nested) withdraw → must revert
        }
    }
}

contract WrappedQRLTest is Test {
    WrappedQRL private w; // system under test
    address private AL = address(0xA11); // Alice
    address private BO = address(0xB0B); // Bob
    address private CA = address(0xCa7); // Carol

    /*──────── set-up ────────*/
    function setUp() public {
        // Fresh deployment; pre-mint 10 QRL to msg.sender for constructor path.
        w = new WrappedQRL{value: 10 * ONE_QRL_WEI}();

        // Fund test actors with native QRL for deposit calls.
        vm.deal(AL, 20 * ONE_QRL_WEI);
        vm.deal(BO, 20 * ONE_QRL_WEI);
        vm.deal(CA, 20 * ONE_QRL_WEI);
    }

    /*──────────────────────────────────────────────────────────────────*
     *                      Constructor & deposit                       *
     *──────────────────────────────────────────────────────────────────*/
    /// @notice Constructor mints exactly the ether sent.
    function testConstructorMint() public {
        assertEq(w.totalSupply(), 10 * ONE_WQRL, "supply");
        assertEq(w.balanceOf(address(this)), 10 * ONE_WQRL, "bal");
        assertEq(address(w).balance, 10 * ONE_QRL_WEI, "vault");
    }

    /// @notice Happy-path deposit mints 1:1 and transfers ETH in.
    function testDeposit() public {
        vm.prank(AL);
        w.deposit{value: 5 * ONE_QRL_WEI}();

        assertEq(w.balanceOf(AL), 5 * ONE_WQRL, "bal");
        assertEq(w.totalSupply(), 15 * ONE_WQRL, "supply");
        assertEq(address(w).balance, 15 * ONE_QRL_WEI, "vault");
    }

    /*──────────────────────── deposit UX tests ────────────────────────*/

    /*──────────────────────── deposit() – typed-error guards ─────────────────────*/

    /**
     * @notice Depositing **less than** one full token (1 × 10⁹ wei) must revert
     *         with `MinDepositOneToken(value)`.
     *
     * Rationale
     * ─────────
     * • Verifies the dust-guard cannot be bypassed.
     * • Supplies the exact `msg.value` (1 wei) so Forge matches selector
     *   **and** argument in the returndata.
     */
    function testDepositBelowOneTokenRevert() public {
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.MinDepositOneToken.selector,
                uint256(1) // the same value we pass in
            )
        );
        w.deposit{value: 1}(); // < 1 WQRL → must revert
    }

    /**
     * @notice Zero-value deposits are equally disallowed and revert with
     *         `MinDepositOneToken(0)`.
     */
    function testDepositZeroRevert() public {
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.MinDepositOneToken.selector,
                uint256(0)
            )
        );
        w.deposit{value: 0}();
    }

    /*──────────────────────── deposit() – event emission ─────────────────────────*/

    /**
     * @notice A successful deposit MUST emit `Deposited(caller, minted)`.
     *
     * Flow
     * ────
     * 1. Fund Alice with enough native QRL.
     * 2. Expect the `Deposited` event (indexed `account`, data `amount`).
     * 3. Execute the deposit; event must surface with exact values.
     */
    function testDepositEmitsDepositedEvent() public {
        uint256 sendValue = 3 * ONE_QRL_WEI + 5; // 3 QRL + small dust
        uint64 minted = uint64(sendValue / SCALE); // == 3 × 1 e9 units

        vm.deal(AL, sendValue); // give Alice funds

        /* checkTopic1 = true  (indexed account)
         * checkData   = true  (minted amount)      */
        vm.expectEmit(true, true, false, true);
        emit WrappedQRL.Deposited(AL, minted);

        vm.prank(AL);
        w.deposit{value: sendValue}(); // fires the event
    }

    /**
     * @notice Depositing 1 WQ + 7 wei should:
     *         • mint exactly one WQ,
     *         • leave caller down 1 e9 wei,
     *         • increase contract balance by 1 e9 wei (dust refunded out).
     */
    function testDepositRefundsDust() public {
        uint256 WEI_PER_WQ = 1e9;
        uint256 dust = 7;
        uint256 sendValue = WEI_PER_WQ + dust; // 1 WQ + dust

        vm.deal(AL, sendValue); // fund caller
        uint256 callerBefore = AL.balance; // snapshot balances
        uint256 contractBefore = address(w).balance;

        vm.startPrank(AL);
        w.deposit{value: sendValue}();
        vm.stopPrank();

        // ── Assertions ─────────────────────────────────────────────────
        assertEq(uint256(w.balanceOf(AL)), 1, "minted amount");

        // caller net ETH change: −1 WQ
        assertEq(AL.balance, callerBefore - WEI_PER_WQ, "caller net eth");

        // contract net ETH change: +1 WQ
        assertEq(
            address(w).balance,
            contractBefore + WEI_PER_WQ,
            "contract delta"
        );
    }

    /*──────────────────────────────────────────────────────────────────*
     *                            Withdraw                              *
     *──────────────────────────────────────────────────────────────────*/
    /// @notice Full withdraw burns tokens and returns ETH.
    function testWithdraw() public {
        // ① Alice wraps 2 QRL
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}();

        // ② Withdraw
        vm.prank(AL);
        w.withdraw(2 * ONE_WQRL);

        assertEq(w.balanceOf(AL), 0, "bal");
        assertEq(w.totalSupply(), 10 * ONE_WQRL, "supply unchanged");
        assertEq(address(w).balance, 10 * ONE_QRL_WEI, "vault");
    }

    /**
     * @notice Withdrawing more than the caller’s balance must revert with
     *         `InsufficientBalance(balance, needed)`.
     *
     * Flow & assertions
     * ─────────────────
     * • Alice has never deposited, so her balance is 0.
     * • She asks to withdraw 1 WQRL.
     * • Contract should revert with the typed error carrying:
     *     – `balance = 0`
     *     – `needed  = 1`
     */
    function testWithdrawInsufficientBalance() public {
        vm.prank(AL); // act as Alice
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.InsufficientBalance.selector,
                uint256(0), // current balance
                uint256(1) // requested amount
            )
        );
        w.withdraw(1); // triggers revert
    }

    /**
     * @notice Withdrawing zero tokens must revert with `ZeroAmount()`.
     *
     * Notes
     * ─────
     * • `ZeroAmount` carries **no parameters**, so the revert-data payload
     *   is exactly the 4-byte selector.  Passing that selector alone to
     *   `vm.expectRevert` is sufficient.
     */
    function testWithdrawZeroRevert() public {
        vm.prank(AL); // act as Alice
        vm.expectRevert(WrappedQRL.ZeroAmount.selector); // expect typed error
        w.withdraw(0); // triggers revert
    }

    /*──────────────────────────────────────────────────────────────────*
     *                       EVENT-EMISSION TESTS                       *
     *──────────────────────────────────────────────────────────────────*/

    /**
     * @notice A successful {withdraw} MUST emit
     *         `Withdrawn(caller, amount)`.
     *
     * Steps
     * ─────
     * 1. Alice wraps 2 QRL → gets 2 WQRL.
     * 2. Expect the `Withdrawn` event (indexed `account`, data `amount`).
     * 3. Call {withdraw}.  Forge verifies selector, topic, and data.
     */
    function testWithdrawEmitsWithdrawnEvent() public {
        /* 1. Mint 2 WQRL to Alice. */
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}();

        uint64 WITHDRAWN = 2 * ONE_WQRL;

        /* 2. Register the expectation.
         *    checkTopic1 = true  (indexed account)
         *    checkData   = true  (withdrawn amount)                       */
        vm.expectEmit(true, true, false, true);
        emit WrappedQRL.Withdrawn(AL, WITHDRAWN);

        /* 3. Perform the withdrawal. */
        vm.prank(AL);
        w.withdraw(WITHDRAWN);
    }

    /**
     * @notice Calling {approve} MUST emit
     *         `Approval(owner, spender, value)` with exact parameters.
     */
    function testApproveEmitsApprovalEvent() public {
        uint64 ALLOW = 5 * ONE_WQRL;

        vm.expectEmit(true, true, false, true);
        emit IZRC20.Approval(AL, BO, ALLOW);

        vm.prank(AL);
        w.approve(BO, ALLOW);
    }

    /**
     * @notice A simple {transfer} MUST emit
     *         `Transfer(from, to, value)`.
     */
    function testTransferEmitsTransferEvent() public {
        /* 1. Give Alice 3 WQRL. */
        vm.prank(AL);
        w.deposit{value: 3 * ONE_QRL_WEI}();

        uint64 SENT = 2 * ONE_WQRL;

        /* 2. Expect the ERC-20 Transfer event. */
        vm.expectEmit(true, true, false, true);
        emit IZRC20.Transfer(AL, BO, SENT);

        /* 3. Send the tokens. */
        vm.prank(AL);
        w.transfer(BO, SENT);
    }

    /*──────────────────────────────────────────────────────────────────*
     *                Transfers, allowances, batches                    *
     *──────────────────────────────────────────────────────────────────*/
    /// @notice Simple transfer moves balance & emits event.
    function testTransfer() public {
        // Alice gets 3 WQRL first
        vm.prank(AL);
        w.deposit{value: 3 * ONE_QRL_WEI}();

        vm.prank(AL);
        w.transfer(BO, 2 * ONE_WQRL);

        assertEq(w.balanceOf(AL), 1 * ONE_WQRL, "AL bal");
        assertEq(w.balanceOf(BO), 2 * ONE_WQRL, "BO bal");
    }

    function testTransferToZero() public {
        // Alice gets 3 WQRL first
        vm.prank(AL);
        w.deposit{value: 3 * ONE_QRL_WEI}();

        vm.prank(AL);
        vm.expectRevert();
        w.transfer(address(0), 2 * ONE_WQRL);
    }

    /// @notice transferBatch all-to-one path.
    function testTransferBatch() public {
        vm.prank(AL);
        w.deposit{value: 4 * ONE_QRL_WEI}(); // AL = 4

        address[] memory rcpt = new address[](3);
        uint64[] memory amt = new uint64[](3);
        rcpt[0] = BO;
        rcpt[1] = CA;
        rcpt[2] = BO;
        amt[0] = 1 * ONE_WQRL;
        amt[1] = 1 * ONE_WQRL;
        amt[2] = 2 * ONE_WQRL;

        vm.prank(AL);
        w.transferBatch(rcpt, amt);

        assertEq(w.balanceOf(AL), 0, "AL");
        assertEq(w.balanceOf(BO), 3 * ONE_WQRL, "BO");
        assertEq(w.balanceOf(CA), 1 * ONE_WQRL, "CA");
    }

    /*──────────────────────── transferBatch – all revert branches ─────────────────*/

    /**
     * Array-length mismatch → LengthMismatch(lenA, lenB)
     */
    function testTransferBatchLengthMismatchRevert() public {
        uint256 N_TO = 3;
        uint256 N_AMT = 2;

        address[] memory rcpt = new address[](N_TO);
        uint64[] memory amt = new uint64[](N_AMT); // deliberate mismatch

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.LengthMismatch.selector,
                uint256(N_TO),
                uint256(N_AMT)
            )
        );

        vm.prank(AL);
        w.transferBatch(rcpt, amt);
    }

    /**
     * Aggregate amount exceeds 2⁶⁴-1 → SumOverflow(attemptedSum)
     */
    function testTransferBatchSumOverflowRevert() public {
        uint256 N = 2;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        amt[0] = type(uint64).max;
        amt[1] = 1; // pushes sum over the cap

        uint256 attempted = uint256(type(uint64).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.SumOverflow.selector, attempted)
        );

        vm.prank(AL);
        w.transferBatch(rcpt, amt);
    }

    /**
     * Caller balance too small → InsufficientBalance(balance, needed)
     */
    function testTransferBatchInsufficientBalanceRevert() public {
        // 1 WQRL balance, but attempt to send 2 WQRL in batch
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // balance = 1

        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = BO;
        amt[0] = 2 * ONE_WQRL; // need 2

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.InsufficientBalance.selector,
                uint256(1 * ONE_WQRL), // balance
                uint256(2 * ONE_WQRL) // needed
            )
        );

        vm.prank(AL);
        w.transferBatch(rcpt, amt);
    }

    /**
     * Any recipient == address(0) → ZeroAddress()
     */
    function testTransferBatchZeroAddressRevert() public {
        // Fund Alice so the balance guard passes
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // balance = 1

        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = address(0); // invalid recipient
        amt[0] = ONE_WQRL;

        vm.expectRevert(WrappedQRL.ZeroAddress.selector); // selector-only
        vm.prank(AL);
        w.transferBatch(rcpt, amt);
    }

    /// @notice Approve max, transferFrom, check allowance tick-down.
    function testTransferFromAllowance() public {
        vm.prank(AL);
        w.deposit{value: 5 * ONE_QRL_WEI}();

        vm.prank(AL);
        w.approve(BO, type(uint64).max); // infinite

        vm.prank(BO);
        w.transferFrom(AL, CA, 4 * ONE_WQRL);

        assertEq(w.balanceOf(AL), 1 * ONE_WQRL, "AL");
        assertEq(w.balanceOf(CA), 4 * ONE_WQRL, "CA");
        assertEq(w.allowance(AL, BO), type(uint64).max, "allow unchanged");
    }

    /// @notice transferFromBatch aggregates allowance once.
    function testTransferFromBatch() public {
        vm.prank(AL);
        w.deposit{value: 5 * ONE_QRL_WEI}();

        vm.prank(AL);
        w.approve(BO, 5 * ONE_WQRL);

        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = CA;
        rcpt[1] = CA;
        amt[0] = 2 * ONE_WQRL;
        amt[1] = 3 * ONE_WQRL;

        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt);

        assertEq(w.balanceOf(CA), 5 * ONE_WQRL, "CA bal");
        assertEq(w.allowance(AL, BO), 0, "allow");
    }

    /*────────────────── transferBatch – event-emission tests ──────────────────*/

    /**
     * A batch with three legs must emit three `Transfer` events that mirror the
     * calldata order exactly.
     */
    function testTransferBatchEmitsTransferEvents() public {
        /* 1. Give Alice 4 WQRL so she can afford the batch. */
        vm.prank(AL);
        w.deposit{value: 4 * ONE_QRL_WEI}();

        /* 2. Build calldata using the requested array-allocation style. */
        uint256 N = 3;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = BO;
        rcpt[1] = CA;
        rcpt[2] = BO;

        amt[0] = 1 * ONE_WQRL;
        amt[1] = 1 * ONE_WQRL;
        amt[2] = 2 * ONE_WQRL;

        /* 3. Record logs, execute the batch. */
        vm.recordLogs();
        vm.prank(AL);
        w.transferBatch(rcpt, amt);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, N, "unexpected # events");

        /* 4. Verify each event’s topics and data payload. */
        bytes32 TRANSFER_SIG = keccak256("Transfer(address,address,uint64)");

        for (uint256 i; i < N; ++i) {
            Vm.Log memory log = logs[i];

            // Signature
            assertEq(log.topics[0], TRANSFER_SIG);

            // Indexed topics
            address from = address(uint160(uint256(log.topics[1])));
            address to = address(uint160(uint256(log.topics[2])));
            assertEq(from, AL, "topic1 mismatch");
            assertEq(to, rcpt[i], "topic2 mismatch");

            // Data payload
            uint64 value = abi.decode(log.data, (uint64));
            assertEq(value, amt[i], "data mismatch");
        }
    }

    /**
     * An empty batch (arrays of length zero) must emit **no** events.
     */
    function testTransferBatchEmptyArraysEmitNoEvents() public {
        /* Fund Alice so the balance guard passes. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();

        uint256 N = 0;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        vm.recordLogs();
        vm.prank(AL);
        bool ok = w.transferBatch(rcpt, amt);
        assertTrue(ok, "call failed");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "should emit no events");
    }

    /*──────────────────────────────────────────────────────────────────*
     *                        Re-entrancy guard                         *
     *──────────────────────────────────────────────────────────────────*/
    /// @notice Any nested call into `deposit` reverts via guard.
    function testReentrancyGuard() public {
        Reenterer evil = new Reenterer(w);

        // give the attacker 2 WQRL
        vm.deal(address(evil), 2 * ONE_QRL_WEI);
        evil.prime{value: 2 * ONE_QRL_WEI}();

        evil.arm();
        vm.expectRevert();
        evil.attack(1 * ONE_WQRL); // first withdraw triggers nested
    }

    /*──────────────────────────────────────────────────────────────────*
     *                       Cap enforcement                            *
     *──────────────────────────────────────────────────────────────────*/
    /// @notice Mint cap (2^64-1) is enforced.
    function testCapEnforced() public {
        // Fill supply to the cap exactly.
        uint64 room = type(uint64).max - w.totalSupply();
        vm.deal(AL, uint256(room) * SCALE);
        vm.prank(AL);
        w.deposit{value: uint256(room) * SCALE}(); // succeeds

        // +1 token must revert with "cap"
        vm.deal(AL, 1 * SCALE);
        vm.expectRevert();
        vm.prank(AL);
        w.deposit{value: 1 * SCALE}();
    }

    /*────────────────────── new / expanded tests ─────────────────────*/

    // 1. metadata + default-state getters
    function testMetadata() public {
        assertEq(w.name(), "Wrapped Quanta");
        assertEq(w.symbol(), "WQ");
        assertEq(uint8(w.decimals()), 9);
    }

    function testDefaultViews() public {
        assertEq(w.balanceOf(AL), 0);
        assertEq(w.allowance(AL, BO), 0);
    }

    // 2. receive() fallback
    function testDepositViaReceiveFunction() public {
        vm.prank(AL);
        (bool ok, ) = address(w).call{value: 2 * ONE_QRL_WEI}("");
        assertTrue(ok);
        assertEq(w.balanceOf(AL), 2 * ONE_WQRL);
    }

    // 3. approvals / allowance edge-paths
    function testApproveUpdatesAllowance() public {
        vm.prank(AL);
        w.approve(BO, 5 * ONE_WQRL);
        assertEq(w.allowance(AL, BO), 5 * ONE_WQRL);
    }

    function testTransferFromFiniteAllowance() public {
        vm.prank(AL);
        w.deposit{value: 4 * ONE_QRL_WEI}(); // AL = 4
        vm.prank(AL);
        w.approve(BO, 3 * ONE_WQRL); // finite allowance

        vm.prank(BO);
        w.transferFrom(AL, CA, 2 * ONE_WQRL); // spend 2

        assertEq(w.allowance(AL, BO), 1 * ONE_WQRL); // 3-2 = 1
        assertEq(w.balanceOf(CA), 2 * ONE_WQRL);
    }

    // 4. batch length / overflow guards
    function testTransferBatchLenMismatch() public {
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](3);
        vm.expectRevert();
        w.transferBatch(rcpt, amt);
    }

    function testTransferFromBatchLenMismatch() public {
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](3);
        vm.expectRevert();
        w.transferFromBatch(AL, rcpt, amt);
    }

    /*──────────────────── transferFromBatch – revert paths ───────────────────*/

    /**
     * to.length ≠ v.length → LengthMismatch(lenA, lenB)
     */
    function testTransferFromBatchLengthMismatchRevert() public {
        uint256 N_TO = 3;
        uint256 N_AMT = 2;

        address[] memory rcpt = new address[](N_TO);
        uint64[] memory amt = new uint64[](N_AMT); // mismatched length

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.LengthMismatch.selector,
                uint256(N_TO),
                uint256(N_AMT)
            )
        );

        vm.prank(BO); // caller is BO
        w.transferFromBatch(AL, rcpt, amt);
    }

    /**
     * Σ v[i] exceeds 2⁶⁴-1 → SumOverflow(attemptedSum)
     */
    function testTransferFromBatchSumOverflowRevert() public {
        uint256 N = 2;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = BO;
        rcpt[1] = BO;

        amt[0] = type(uint64).max;
        amt[1] = 1; // pushes sum over cap

        uint256 attempted = uint256(type(uint64).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.SumOverflow.selector, attempted)
        );

        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt);
    }

    /**
     * Allowance too small → InsufficientAllowance(allowance, need)
     */
    function testTransferFromBatchAllowanceInsufficientRevert() public {
        /* Fund & approve. AL balance is ample; allowance is only 1 WQRL. */
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL balance = 2
        vm.prank(AL);
        w.approve(BO, 1 * ONE_WQRL); // allowance = 1

        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = CA;
        amt[0] = 2 * ONE_WQRL; // need 2

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.InsufficientAllowance.selector,
                uint256(1 * ONE_WQRL), // allowance
                uint256(2 * ONE_WQRL) // need
            )
        );

        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt);
    }

    /**
     * Balance too small → InsufficientBalance(balance, need)
     * (Allowance is large enough, balance is not.)
     */
    function testTransferFromBatchInsufficientBalanceRevert() public {
        vm.prank(AL);
        w.deposit{value: 1 * ONE_QRL_WEI}(); // AL balance = 1
        vm.prank(AL);
        w.approve(BO, 2 * ONE_WQRL); // allowance sufficient

        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = CA;
        amt[0] = 2 * ONE_WQRL; // need 2 > balance 1

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.InsufficientBalance.selector,
                uint256(1 * ONE_WQRL), // balance
                uint256(2 * ONE_WQRL) // need
            )
        );

        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt);
    }

    /**
     * Any recipient == address(0) → ZeroAddress()
     * (Balance and allowance are both sufficient so we reach the loop guard.)
     */
    function testTransferFromBatchZeroAddressRevert() public {
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL balance = 2
        vm.prank(AL);
        w.approve(BO, 2 * ONE_WQRL); // allowance sufficient

        uint256 N = 2;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);

        rcpt[0] = address(0); // invalid recipient
        rcpt[1] = CA;
        amt[0] = 1 * ONE_WQRL;
        amt[1] = 1 * ONE_WQRL;

        vm.expectRevert(WrappedQRL.ZeroAddress.selector); // selector-only
        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt);
    }

    /*─────────────────────────  extra edge-case tests  ─────────────────────────*/

    // 1. transfer() → address(0) should revert with "to0"
    function testTransferToZeroRevert() public {
        vm.expectRevert();
        w.transfer(address(0), 1);
    }

    // 2. transfer() with insufficient balance reverts with "bal"
    function testTransferInsufficientBalanceRevert() public {
        vm.prank(BO); // 0-balance wallet tries to send
        vm.expectRevert();
        w.transfer(CA, 1); // any non-zero amount triggers revert
    }

    /**
     * @notice When the spender tries to move more than the current allowance,
     *         {transferFrom} MUST revert with
     *         `InsufficientAllowance(allowance, needed)`.
     *
     * Scenario
     * --------
     * • Alice holds 1 WQRL and gives Bob an allowance of 1 unit.
     * • Bob attempts to move 2 units to Carol.
     * • The call reverts, carrying:
     *     – `allowance = 1`
     *     – `needed    = 2`
     */
    function testTransferFromAllowanceInsufficientRevert() public {
        /* 1. Prime Alice with 1 WQRL. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // balance(AL) = 1

        /* 2. Set allowance = 1. */
        vm.prank(AL);
        w.approve(BO, 1); // cur allowance = 1

        /* 3. Expect the typed error, then trigger the overspend. */
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.InsufficientAllowance.selector,
                uint256(1), // allowance
                uint256(2) // needed
            )
        );
        vm.prank(BO);
        w.transferFrom(AL, CA, 2); // attempt to spend 2
    }

    // 4. Infinite allowance path (uint64.max) – balance moves, allowance unchanged
    function testTransferFromInfiniteAllowanceNoTickDown() public {
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL = 2 WQRL
        vm.prank(AL);
        w.approve(BO, type(uint64).max); // infinite

        vm.prank(BO);
        w.transferFrom(AL, CA, ONE_WQRL); // spend 1

        assertEq(w.balanceOf(AL), 1 * ONE_WQRL);
        assertEq(w.balanceOf(CA), 1 * ONE_WQRL);
        assertEq(w.allowance(AL, BO), type(uint64).max, "allow unchanged");
    }

    function testConstructorZeroMint() public {
        WrappedQRL blank = new WrappedQRL(); // deploy with no ether
        assertEq(blank.totalSupply(), 0, "supply");
        assertEq(address(blank).balance, 0, "vault");
    }

    /**
     * @notice If the underlying native-token transfer fails, {withdraw}
     *         MUST revert with `NativeTransferFailed(to, amount)`.
     *
     * Harness
     * ───────
     * • `_BadRecv` is a helper that reverts in its `receive()` function,
     *   forcing the low-level `call{value: …}` inside {withdraw} to fail.
     * • We fund the helper with exactly 1 QRL (18-dec) and let it
     *   wrap-then-withdraw that same amount.
     * • Forge must see the correct selector **and** both arguments.
     */
    function testWithdrawNativeSendRevert() public {
        _BadRecv bad = new _BadRecv(w); // malicious recipient
        vm.deal(address(bad), ONE_QRL_WEI); // seed 1 QRL

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.NativeTransferFailed.selector,
                address(bad), // `to`
                uint256(ONE_QRL_WEI) // `amount`
            )
        );

        bad.trigger{value: ONE_QRL_WEI}(); // wrap → withdraw → revert
    }

    // 3.  Allowance exact-spend path (cur == val, cur != uint64.max)
    function testTransferFromAllowanceExactSpend() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQRL
        vm.prank(AL);
        w.approve(BO, ONE_WQRL); // finite allowance = balance

        vm.prank(BO);
        w.transferFrom(AL, CA, ONE_WQRL); // spend it all

        assertEq(w.allowance(AL, BO), 0, "allow zeroed");
        assertEq(w.balanceOf(CA), ONE_WQRL);
    }

    /*──────────────────────────  FINAL GAP-FILLERS  ─────────────────────────*/

    // 1. transferBatch with **empty arrays** → loop body never runs
    function testTransferBatchEmptyLists() public {
        address[] memory rcpt = new address[](0);
        uint64[] memory amt = new uint64[](0);

        bool ok = w.transferBatch(rcpt, amt); // no-op, must succeed
        assertTrue(ok);
        // nothing should change
        assertEq(w.totalSupply(), 10 * ONE_WQRL);
        assertEq(w.balanceOf(address(this)), 10 * ONE_WQRL);
    }

    // 2. transferFromBatch with empty arrays – hits the same zero-iteration branch
    function testTransferFromBatchEmptyLists() public {
        address[] memory rcpt = new address[](0);
        uint64[] memory amt = new uint64[](0);

        // No allowance needed; should simply return true
        bool ok = w.transferFromBatch(AL, rcpt, amt);
        assertTrue(ok);
    }

    // 3. transfer of **zero tokens** (val == 0) – exercises _xfer without mutation
    function testTransferZeroValueNoEffect() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL gets 1 WQRL

        uint64 balBefore = w.balanceOf(AL);
        vm.prank(AL);
        bool ok = w.transfer(BO, 0); // zero-value transfer
        assertTrue(ok);

        assertEq(w.balanceOf(AL), balBefore, "AL unchanged");
        assertEq(w.balanceOf(BO), 0, "BO unchanged");
    }

    /*────────────────────────  FINAL COVERAGE PLUG-INS  ─────────────────────*/

    // 4.  Exact-spend branch (cur == val) *and* zero-value transfer branch
    function testAllowanceExactSpendAndZeroTransfer() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQRL
        vm.prank(AL);
        w.approve(BO, ONE_WQRL); // finite allowance == bal

        // (a) exact-spend: allowance ticks down to zero
        vm.prank(BO);
        w.transferFrom(AL, CA, ONE_WQRL);
        assertEq(w.allowance(AL, BO), 0, "allow zero");

        // (b) zero-value self-transfer exercises _xfer val==0 branch
        uint64 balCA = w.balanceOf(CA);
        vm.prank(CA);
        w.transfer(BO, 0); // should do nothing
        assertEq(w.balanceOf(CA), balCA, "no change");
    }

    /*────────────────────  lock() feature tests  ───────────────────*/

    /**
     * @notice While the caller is locked, any {transfer} must revert with
     *         `WalletLocked(unlockAt)`.
     *
     * Flow
     * ----
     * 1. Alice wraps 1 QRL (→ 1 WQRL balance).
     * 2. Alice locks herself for 60 seconds.
     * 3. Immediately attempts a transfer; contract should revert with
     *    `WalletLocked(unlockAt)` where `unlockAt` equals
     *    `block.timestamp + 60`.
     */
    function testLockBlocksTransfer() public {
        /* 1. Fund Alice. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL balance = 1 WQRL

        /* 2. Lock for 60 s. */
        vm.prank(AL);
        w.lock(60);

        /* Read the exact unlock timestamp to match the revert argument. */
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Expect the typed error and trigger the revert. */
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        w.transfer(BO, ONE_WQRL); // must revert
    }

    /**
     * @notice While the caller is locked, {withdraw} must revert with
     *         `WalletLocked(unlockAt)`.
     *
     * Sequence
     * --------
     * 1. Alice wraps 1 QRL (→ 1 WQRL balance).
     * 2. Alice locks herself for 120 s.
     * 3. She immediately tries to withdraw; the call must revert with the
     *    exact `WalletLocked` custom error, carrying her unlock timestamp.
     */
    function testLockBlocksWithdraw() public {
        /* 1. Mint 1 WQRL to Alice. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();

        /* 2. Lock for 120 s and fetch the resulting unlock timestamp. */
        vm.prank(AL);
        w.lock(120);
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Expect the typed error and attempt the withdrawal. */
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        w.withdraw(ONE_WQRL); // must revert
    }

    // 3.  Lock expires after duration → transfer succeeds.
    function testLockExpires() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(30); // 30 s lock

        vm.warp(block.timestamp + 31); // fast-forward past expiry
        vm.prank(AL);
        w.transfer(BO, ONE_WQRL); // no revert
        assertEq(w.balanceOf(BO), ONE_WQRL);
    }

    /**
     * @notice A second {lock} call that extends the window must keep the
     *         wallet frozen until the new deadline, reverting transfers
     *         with `WalletLocked(unlockAt)` right up until expiry.
     *
     * Flow
     * ----
     * 1. Alice locks for 40 s.
     * 2. After 20 s, she extends the lock by 60 s (new unlockAt = now + 60).
     * 3. At unlockAt − 1 s a transfer must revert with the custom error.
     * 4. One second after unlock, the transfer must succeed.
     */
    function testLockExtension() public {
        /* 1. Give Alice 1 WQRL and initiate a 40-second lock. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(40);

        /* 2. Advance 20 s, then extend by 60 s. */
        vm.warp(block.timestamp + 20);
        vm.prank(AL);
        w.lock(60); // extension

        /* Record the exact unlock timestamp for error-matching. */
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Jump to unlockAt − 1 s and expect the custom error. */
        vm.warp(uint256(unlockAt) - 1);
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        w.transfer(BO, ONE_WQRL); // must revert

        /* 4. Jump past unlock and verify transfer now succeeds. */
        vm.warp(block.timestamp + 2); // now > unlockAt
        vm.prank(AL);
        w.transfer(BO, ONE_WQRL); // should succeed
        assertEq(w.balanceOf(BO), ONE_WQRL);
    }

    /*────────────────────  lock() additional edge-cases  ───────────────────*/

    // A. zero-duration lock reverts (“dur0” branch)
    function testLockZeroDurationRevert() public {
        vm.expectRevert();
        w.lock(0);
    }

    // B. withdraw succeeds after lock has fully expired
    function testWithdrawAfterLockExpiry() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(5); // lock 5 s
        vm.warp(block.timestamp + 6); // past expiry
        vm.prank(AL);
        w.withdraw(ONE_WQRL); // should NOT revert
        assertEq(w.balanceOf(AL), 0);
    }

    /*────────────────────  allowance MAX in batch path  ───────────────────*/

    // C. transferFromBatch with allowance = type(uint64).max hits
    //    the _spendAllowance branch where `cur == uint64.max` (no tick-down).
    function testTransferFromBatchInfiniteAllowanceNoTickDownBatch() public {
        vm.prank(AL);
        w.deposit{value: 3 * ONE_QRL_WEI}(); // AL = 3 WQ
        vm.prank(AL);
        w.approve(BO, type(uint64).max); // infinite

        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = CA;
        rcpt[1] = CA;
        amt[0] = ONE_WQRL;
        amt[1] = ONE_WQRL;

        vm.prank(BO);
        w.transferFromBatch(AL, rcpt, amt); // spend 2

        assertEq(w.allowance(AL, BO), type(uint64).max, "unchanged");
        assertEq(w.balanceOf(CA), 2 * ONE_WQRL);
    }

    /*────────────────────  remaining-coverage tests  ───────────────────*/

    // 1.  unlocksAt getter: 0 when unlocked, > now when locked
    function testUnlocksAtGetter() public {
        // default = 0
        assertEq(w.unlocksAt(AL), 0);

        // after a lock it must return a future timestamp
        vm.prank(AL);
        w.lock(42); // 42-second lock
        uint64 t = w.unlocksAt(AL);
        assertGt(t, uint64(block.timestamp));
    }

    // 2.  lock success path (branch where duration > 0 and no prior lock)
    function testLockSetsTimestamp() public {
        vm.prank(AL);
        w.lock(15); // 15-second lock
        // reading back immediately should match
        assertEq(w.unlocksAt(AL), uint56(block.timestamp + 15));
    }

    // 3.  Approvals are allowed even while the wallet is locked
    function testApproveWhileLocked() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(120); // freeze for 2 minutes

        vm.prank(AL);
        w.approve(BO, ONE_WQRL); // should succeed
        assertEq(w.allowance(AL, BO), ONE_WQRL);
    }

    /**
     * @notice When the `from` address is still locked, a plain {transferFrom}
     *         MUST revert with `WalletLocked(unlockAt)`.
     *
     * Scenario
     * --------
     * • Alice wraps 1 WQRL and grants Bob an allowance for that amount.
     * • Alice locks herself for 45 s.
     * • Bob immediately tries to move the tokens to Carol.
     * • The call must revert with the custom error carrying Alice’s
     *   unlock timestamp.
     */
    function testTransferFromFailsWhenFromIsLocked() public {
        /* 1. Fund Alice and approve Bob. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // balance(AL) = 1 WQRL
        vm.prank(AL);
        w.approve(BO, ONE_WQRL); // allowance = 1 WQRL

        /* 2. Lock Alice for 45 s and fetch the unlock time. */
        vm.prank(AL);
        w.lock(45);
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Expect the typed error, then attempt the transfer as Bob. */
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        vm.prank(BO);
        w.transferFrom(AL, CA, ONE_WQRL); // must revert
    }

    /*─────────────────────────  COVERAGE GAP PLUG-INS  ─────────────────────────*/

    /* A. sender → sender transfer of a positive amount  
     • exercises _xfer path where `from == to`, proving the balance delta is net-zero. */
    function testSelfTransferNoEffect() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQ

        uint64 before = w.balanceOf(AL);
        vm.prank(AL);
        w.transfer(AL, ONE_WQRL); // self-send

        assertEq(w.balanceOf(AL), before, "no delta");
    }

    /**
     * @notice While the caller is locked, {transferBatch} must revert with
     *         `WalletLocked(unlockAt)`.
     *
     * Steps
     * -----
     * 1. Alice wraps 2 WQRL (so the balance guard isn’t triggered later).
     * 2. She locks herself for 100 seconds.
     * 3. She immediately tries a one-leg batch transfer; the call must revert
     *    with the custom `WalletLocked` error carrying her unlock timestamp.
     */
    function testTransferBatchCallerLockedRevert() public {
        /* 1. Fund Alice with 2 WQRL. */
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}();

        /* 2. Activate a 100-second lock and read back the unlock timestamp. */
        vm.prank(AL);
        w.lock(100);
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Prepare a minimal batch (arrays allocated via new address[](N)). */
        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);
        rcpt[0] = BO;
        amt[0] = ONE_WQRL;

        /* 4. Expect the typed error and attempt the call. */
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        w.transferBatch(rcpt, amt); // must revert
    }

    /* C. infinite-allowance, non-zero self-transfer via transferFrom  
     • covers _spendAllowance branch (cur == uint64.max AND v > 0) that was still untouched. */
    function testTransferFromSelfInfiniteAllowanceNoTickDown() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQ
        vm.prank(AL);
        w.approve(BO, type(uint64).max); // infinite

        vm.prank(BO);
        w.transferFrom(AL, AL, ONE_WQRL); // move to self

        // balance unchanged, allowance unchanged
        assertEq(w.balanceOf(AL), ONE_WQRL);
        assertEq(w.allowance(AL, BO), type(uint64).max);
    }

    /*──────────  REPLACE the two zero-value tests with log-agnostic versions  ─────────*/

    /* D. finite allowance, value == 0 – no state change, allowance untouched */
    function testTransferFromZeroValueNoEffect() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.approve(BO, 5 * ONE_WQRL); // finite allowance

        vm.prank(BO);
        bool ok = w.transferFrom(AL, CA, 0); // zero-value
        assertTrue(ok);

        // nothing changed
        assertEq(w.balanceOf(AL), ONE_WQRL);
        assertEq(w.balanceOf(CA), 0);
        assertEq(w.allowance(AL, BO), 5 * ONE_WQRL);
    }

    /* E. infinite allowance, value == 0 – likewise no state change */
    function testTransferFromZeroValueInfiniteAllowanceNoEffect() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.approve(BO, type(uint64).max); // infinite

        vm.prank(BO);
        bool ok = w.transferFrom(AL, CA, 0);
        assertTrue(ok);

        assertEq(w.balanceOf(AL), ONE_WQRL);
        assertEq(w.balanceOf(CA), 0);
        assertEq(w.allowance(AL, BO), type(uint64).max);
    }

    /*────────────────────  FINAL micro-coverage plugs  ───────────────────*/

    /// F. caller == `from`, allowance entry is the default **0**, value == 0.
    ///    _spendAllowance must allow this, touch storage once, and emit Approval.
    function testTransferFromSelfZeroWithoutPriorApproval() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL gets 1 WQ

        vm.recordLogs();
        vm.prank(AL); // caller == from
        bool ok = w.transferFrom(AL, CA, 0); // spend 0
        assertTrue(ok);

        // state unchanged
        assertEq(w.balanceOf(AL), ONE_WQRL);
        assertEq(w.balanceOf(CA), 0);
        assertEq(w.allowance(AL, AL), 0);

        // one Approval(0) + one Transfer(0) event expected
        assertEq(vm.getRecordedLogs().length, 2);
    }

    /// G. third-party spender, **no** prior allowance, value == 0.
    ///    Checks `_spendAllowance` path where `cur == 0`, `v == 0`,
    ///    so it must succeed and emit Approval(0).
    function testTransferFromZeroBySpenderWithoutAllowance() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL funds

        vm.recordLogs();
        vm.prank(BO); // BO has *no* allowance
        bool ok = w.transferFrom(AL, CA, 0); // spend 0
        assertTrue(ok);

        // nothing changed; allowance entry now explicitly 0
        assertEq(w.balanceOf(AL), ONE_WQRL);
        assertEq(w.balanceOf(CA), 0);
        assertEq(w.allowance(AL, BO), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "Approval + Transfer");
    }

    /**
     * @notice When the `from` address is still locked, {transferFromBatch}
     *         MUST revert with `WalletLocked(unlockAt)`.
     *
     * Steps
     * -----
     * 1. Alice wraps 2 WQRL and gives Bob an allowance for all of it.
     * 2. Alice locks herself for 90 s.
     * 3. Bob immediately tries a batch transfer; the call must revert with
     *    the custom `WalletLocked` error that carries Alice’s unlock timestamp.
     */
    function testTransferFromBatchFromLockedRevert() public {
        /* 1. Fund Alice (AL) and set allowance for Bob (BO). */
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL balance = 2 WQRL
        vm.prank(AL);
        w.approve(BO, 2 * ONE_WQRL); // full allowance

        /* 2. Lock Alice for 90 s and capture the unlock time. */
        vm.prank(AL);
        w.lock(90);
        uint64 unlockAt = w.unlocksAt(AL);

        /* 3. Prepare a one-leg batch using the required allocation style. */
        uint256 N = 1;
        address[] memory rcpt = new address[](N);
        uint64[] memory amt = new uint64[](N);
        rcpt[0] = CA;
        amt[0] = ONE_WQRL;

        /* 4. Expect the custom error and invoke the call as Bob. */
        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.WalletLocked.selector, unlockAt)
        );
        w.transferFromBatch(AL, rcpt, amt); // must revert
    }

    /// @notice `theme()` returns the hard-coded URL.
    function testThemeMusic() public view {
        string memory expected = "https://www.youtube.com/watch?v=pJvduG0E628";
        assertEq(w.theme(), expected);
    }

    /**
     * @notice Calling {lock} with a zero-second duration must revert
     *         with the custom error `DurationZero(0)`.
     *
     * Forge quirk
     * ───────────
     * • Passing only the selector is **not** enough because the revert
     *   includes an encoded parameter (uint32(0)).  We therefore encode
     *   the selector **and** the argument.
     */
    function testLockDurationZeroRevert() public {
        vm.prank(AL);

        // 4-byte selector + one uint32(0) argument
        vm.expectRevert(
            abi.encodeWithSelector(WrappedQRL.DurationZero.selector, uint32(0))
        );

        w.lock(0);
    }

    /**
     * @notice A second {lock} that would shorten the current freeze
     *         window must revert with `LockShorter(newUntil, curUntil)`.
     *
     * Implementation notes
     * ────────────────────
     * • We compute `newUntil` and `currentUntil` exactly the way the
     *   contract does, then feed both into `expectRevert` to force an
     *   exact-match on selector **and** parameters.
     */
    function testLockShorterRevert() public {
        /* 1. Prime the account with a balance and a 120-second lock. */
        vm.prank(AL);
        w.deposit{value: 1 ether}();
        vm.prank(AL);
        w.lock(120);

        /* 2. Advance 30 seconds so 90 s remain. */
        vm.warp(block.timestamp + 30);

        /* 3. Prepare expected arguments. */
        uint64 currentUntil = w.unlocksAt(AL); // original expiry
        uint64 newUntil = uint64(block.timestamp + 60); // attempt

        vm.prank(AL);

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.LockShorter.selector,
                newUntil,
                currentUntil
            )
        );

        /* 4. This call *must* revert. */
        w.lock(60);
    }

    /*──────────────────────────────────────────────────────────────────*
     *                  AccountLocked ­– event coverage                 *
     *──────────────────────────────────────────────────────────────────*/

    /**
     * @notice A first-time call to {lock} MUST emit
     *         `AccountLocked(caller, block.timestamp + duration)`.
     *
     * Intent & reasoning
     * ───────────────────
     * • Uses `vm.expectEmit` so the test is agnostic to the
     *   event ordering and Log index.
     * • Checks the indexed `wallet` topic **and** the `unlockAt`
     *   data payload for an exact match.
     */
    function testLockEmitsEventFreshLock() public {
        uint32 DUR = 90; // seconds

        /* 1. Pre-compute the expected unlock timestamp BEFORE the call.   */
        uint64 expectedUnlock = uint64(block.timestamp + DUR);

        /* 2. Register the expectation.                                   *
         * Args:  checkTopic1, checkTopic2, checkTopic3, checkData         *
         *   – Topic0 = event signature  (always checked by Forge)         *
         *   – Topic1 = indexed wallet  (we care ⇒ true)                   *
         *   – Topic2 = none (false)                                       *
         *   – checkData = payload (unlockAt)  (we care ⇒ true)            */
        vm.expectEmit(true, true, false, true);
        emit WrappedQRL.AccountLocked(AL, expectedUnlock);

        /* 3. Call → should succeed and fire the event.                   */
        vm.prank(AL);
        w.lock(DUR);

        /* 4. Sanity-check storage matches the event.                     */
        assertEq(w.unlocksAt(AL), expectedUnlock);
    }

    /**
     * @notice A *second* {lock} that extends the freeze window MUST emit
     *         `AccountLocked(caller, newUnlockAt)`, where `newUnlockAt`
     *         is later than the prior deadline.
     */
    function testLockEmitsEventOnExtension() public {
        /* 1. Deposit once so Alice has something to lock. */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();

        /* 2. First lock – 120 s. */
        vm.prank(AL);
        w.lock(120);

        /* 3. Warp 40 s forward → 80 s remain. */
        vm.warp(block.timestamp + 40);

        /* 4. Prepare extension: +90 s from *now*. */
        uint32 EXT = 90;
        uint64 expectedUnlock = uint64(block.timestamp + EXT);

        vm.expectEmit(true, true, false, true);
        emit WrappedQRL.AccountLocked(AL, expectedUnlock);

        /* 5. Second lock – extends window. */
        vm.prank(AL);
        w.lock(EXT);

        /* 6. Assert new deadline matches the event payload. */
        assertEq(w.unlocksAt(AL), expectedUnlock);
    }

    function testConstructorRefundsDust() public {
        uint256 WEI_PER_WQ = 1e9;
        uint256 dust = 11;
        uint256 sendValue = WEI_PER_WQ + dust;

        address DEPLOYER = address(0xDe1);
        vm.deal(DEPLOYER, sendValue);
        uint256 before = DEPLOYER.balance;

        vm.prank(DEPLOYER); // ← EO-A deployer
        WrappedQRL fresh = new WrappedQRL{value: sendValue}();

        assertEq(fresh.balanceOf(DEPLOYER), 1, "minted WQ");
        assertEq(fresh.totalSupply(), 1, "supply");
        assertEq(address(fresh).balance, WEI_PER_WQ, "vault");
        assertEq(DEPLOYER.balance, before - WEI_PER_WQ, "net ETH");
    }

    /*──────────────────────── _checkCap – revert coverage ─────────────────────*/

    /**
     * @notice When totalSupply is already at the 64-bit cap, any additional
     *         mint (via {deposit}) MUST revert with
     *         `CapExceeded(totalSupply, 1)`.
     *
     * Steps
     * -----
     * 1. Fill the supply to exactly `2⁶⁴-1` tokens.
     * 2. Attempt to mint one more token.
     * 3. Expect `CapExceeded(MAX_BAL, 1)`.
     */
    function testCapExceededRevertByOneToken() public {
        /* 1. Fill the cap. */
        uint64 room = type(uint64).max - w.totalSupply();
        vm.deal(AL, uint256(room) * SCALE);
        vm.prank(AL);
        w.deposit{value: uint256(room) * SCALE}(); // succeeds

        /* 2. Attempt to mint one more token. */
        vm.deal(AL, SCALE); // 1 token worth
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.CapExceeded.selector,
                uint256(type(uint64).max), // current supply
                uint256(1) // mintAttempt
            )
        );
        vm.prank(AL);
        w.deposit{value: SCALE}(); // must revert
    }

    /**
     * @notice A single oversized {deposit} that would push supply past the
     *         cap MUST revert with `CapExceeded(totalSupply, mintAmount)`.
     *
     * Scenario
     * --------
     * • Current supply is 10 WQRL (from constructor).
     * • Alice tries to deposit `MAX_BAL` wei worth of tokens in one call.
     * • The mint amount itself exceeds the remaining head-room, so the call
     *   reverts and encodes the attempted mint size.
     */
    function testCapExceededRevertLargeOvershoot() public {
        /* 1. Compute an oversize mint: current supply = 10 WQRL. */
        uint64 mintAmt = type(uint64).max; // 2⁶⁴-1 tokens
        uint64 curSupply = w.totalSupply(); // 10
        require(curSupply < mintAmt, "setup failed");

        /* 2. Fund Alice and attempt the deposit that overshoots the cap. */
        vm.deal(AL, uint256(mintAmt) * SCALE);
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.CapExceeded.selector,
                uint256(curSupply), // supply before call
                uint256(mintAmt) // attempted mint
            )
        );
        vm.prank(AL);
        w.deposit{value: uint256(mintAmt) * SCALE}(); // must revert
    }

    /*────────────────────── _checkCap – total-supply guard ──────────────────────*/

    /**
     * @notice When a deposit would push `totalSupply` past `2⁶⁴-1`, the call
     *         MUST revert with `CapExceeded(totalSupply, mintAmount)`.
     *
     * Strategy
     * --------
     * 1. Bring the global supply to `MAX_BAL – 5` tokens (well below the
     *    per-account limit).
     * 2. Attempt to mint 10 additional tokens in a single deposit.
     * 3. Expect `CapExceeded(MAX_BAL – 5, 10)`.
     *
     * Invariants
     * ----------
     * • No single account ever holds more than `2⁶⁴-1`, so the
     *   per-account overflow guard cannot fire first.
     */
    function testCapExceededTotalSupplyRevert() public {
        /* 1. Fill the supply to MAX_BAL − 5. */
        uint64 current = w.totalSupply(); // constructor minted 10
        uint64 room = type(uint64).max - current; // head-room to the cap
        uint64 leave = 5; // tokens we *won't* fill
        uint64 mint1 = room - leave; // bring supply to MAX_BAL-5

        vm.deal(AL, uint256(mint1) * SCALE); // fund Alice
        vm.prank(AL);
        w.deposit{value: uint256(mint1) * SCALE}(); // succeeds

        /* Sanity-check supply is now MAX_BAL-5. */
        assertEq(w.totalSupply(), type(uint64).max - leave, "setup failed");

        /* 2. Attempt to mint 10 more tokens — will exceed the cap by 5. */
        uint64 mint2 = 10;
        vm.deal(AL, uint256(mint2) * SCALE); // fund for the overshoot

        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedQRL.CapExceeded.selector,
                uint256(type(uint64).max - leave), // totalSupply before call
                uint256(mint2) // attempted mint
            )
        );

        vm.prank(AL);
        w.deposit{value: uint256(mint2) * SCALE}(); // must revert
    }
}
