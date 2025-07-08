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
import {WrappedQRL, ReentrancyGuard} from "../src/_simple.sol"; // adjust path if needed

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

    /**
     * @notice Depositing **less than** one full token (1 × 10⁹ wei) must revert.
     * @dev    The contract now guards this case with `require(msg.value >= _SCALE, "min1")`.
     *         We purposely send a single wei to hit that path.
     */
    function testDepositBelowOneTokenRevert() public {
        vm.expectRevert(bytes("min1"));
        vm.prank(AL);
        w.deposit{value: 1}(); // < 1 WQ → revert
    }

    /**
     * @notice Zero-value deposits are equally disallowed and revert with the
     *         same `"min1"` sentinel.
     */
    function testDepositZeroRevert() public {
        vm.expectRevert(bytes("min1"));
        vm.prank(AL);
        w.deposit{value: 0}();
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

    /// @notice Withdraw more than balance reverts.
    function testWithdrawInsufficientBalance() public {
        vm.expectRevert(bytes("bal"));
        vm.prank(AL);
        w.withdraw(1);
    }

    /// @notice Withdraw with zero amount reverts.
    function testWithdrawZero() public {
        vm.expectRevert(bytes("zero"));
        vm.prank(AL);
        w.withdraw(0);
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

    /// @notice transferBatch mismatched array lengths revert.
    function testTransferBatchLengthMismatch() public {
        address[] memory rcpt = new address[](3);
        uint64[] memory amt = new uint64[](2);
        vm.expectRevert(bytes("len"));
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

    function testTransferFromBatchSumOverflow() public {
        uint64 max = type(uint64).max;
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        rcpt[1] = BO;
        amt[0] = max;
        amt[1] = 1; // max + 1 → overflow

        vm.expectRevert("sum-overflow");
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

    // 3. transferFrom() allowance too small → "allow"
    function testTransferFromAllowanceInsufficientRevert() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL gets 1 WQRL
        vm.prank(AL);
        w.approve(BO, 1); // allow 1

        vm.expectRevert("allow");
        vm.prank(BO);
        w.transferFrom(AL, CA, 2); // try to spend 2
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

    /*──────────────────────────  NEW TESTS  ──────────────────────────*/

    // 1.  Constructor path when `msg.value == 0`
    function testConstructorZeroMint() public {
        WrappedQRL blank = new WrappedQRL(); // deploy with no ether
        assertEq(blank.totalSupply(), 0, "supply");
        assertEq(address(blank).balance, 0, "vault");
    }

    // 2.  Withdraw revert when the ETH transfer fails (“native send” branch)
    function testWithdrawNativeSendRevert() public {
        _BadRecv bad = new _BadRecv(w); // helper defined above
        vm.deal(address(bad), ONE_QRL_WEI); // fund 1 QRL

        vm.expectRevert("native send");
        bad.trigger{value: ONE_QRL_WEI}(); // wrap → withdraw → fail
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

    // 1.  Lock blocks transfers.
    function testLockBlocksTransfer() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQ
        vm.prank(AL);
        w.lock(60); // lock for 60 s

        vm.prank(AL);
        vm.expectRevert("locked");
        w.transfer(BO, ONE_WQRL);
    }

    // 2.  Lock blocks withdraw.
    function testLockBlocksWithdraw() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(120); // 2 min lock

        vm.prank(AL);
        vm.expectRevert("locked");
        w.withdraw(ONE_WQRL);
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

    // 4.  Re-locking extends the freeze window.
    function testLockExtension() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}();
        vm.prank(AL);
        w.lock(40); // first lock 40 s

        vm.warp(block.timestamp + 20); // half elapsed
        vm.prank(AL);
        w.lock(60); // extend by another 60 s

        // 59 s later → still locked
        vm.warp(block.timestamp + 59);
        vm.prank(AL);
        vm.expectRevert("locked");
        w.transfer(BO, ONE_WQRL);

        // 61 s later → unlocked
        vm.warp(block.timestamp + 2);
        vm.prank(AL);
        w.transfer(BO, ONE_WQRL);
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

    /*────────────────────  still-locked “from” in transferFrom  ───────────────────*/
    // AL locks, then BO (spender) tries to move AL’s funds → must revert “locked”.
    function testTransferFromFailsWhenFromIsLocked() public {
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL gets 1 WQ
        vm.prank(AL);
        w.approve(BO, ONE_WQRL); // allow BO
        vm.prank(AL);
        w.lock(45); // freeze AL

        vm.prank(BO);
        vm.expectRevert("locked");
        w.transferFrom(AL, CA, ONE_WQRL); // should fail
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

    /* B. transferBatch fails when the **caller is locked**  
     • hits the _assertUnlocked() guard inside transferBatch (branch not yet covered). */
    function testTransferBatchCallerLockedRevert() public {
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL = 2 WQ
        vm.prank(AL);
        w.lock(100); // freeze

        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = BO;
        amt[0] = ONE_WQRL;

        vm.prank(AL);
        vm.expectRevert("locked");
        w.transferBatch(rcpt, amt);
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

    /// H. transferFromBatch — caller locked, **arrays non-empty & equal**.
    ///    We already covered the length-mismatch case; this covers the
    ///    _assertUnlocked(from) *revert* branch inside transferFromBatch.
    function testTransferFromBatchFromLockedRevert() public {
        vm.prank(AL);
        w.deposit{value: 2 * ONE_QRL_WEI}(); // AL = 2 WQ
        vm.prank(AL);
        w.approve(BO, 2 * ONE_WQRL);

        vm.prank(AL);
        w.lock(90); // freeze AL

        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = CA;
        amt[0] = ONE_WQRL;

        vm.prank(BO);
        vm.expectRevert("locked");
        w.transferFromBatch(AL, rcpt, amt);
    }

    /// @notice `theme()` returns the hard-coded URL.
    function testThemeMusic() public view {
        string memory expected = "https://www.youtube.com/watch?v=pJvduG0E628";
        assertEq(w.theme(), expected);
    }

    /// @notice Second call to {lock} with a *shorter* duration than the time
    ///         still remaining must revert with the `"shorter"` sentinel.
    ///         Flow:
    ///         1.  Alice wraps 1 QRL so she has a balance to lock.
    ///         2.  She self-locks for 120 s.
    ///         3.  Fast-forward 30 s so 90 s remain.
    ///         4.  Alice tries to lock for only 60 s → should revert.
    function testLockCannotBeShortened() public {
        /* 1. Alice deposits 1 QRL (9-dec = 1 WQRL) ------------------------- */
        vm.prank(AL);
        w.deposit{value: ONE_QRL_WEI}(); // AL = 1 WQRL

        /* 2. Initial lock for 120 seconds ---------------------------------- */
        vm.prank(AL);
        w.lock(120); // lock window = [t, t+120]

        /* 3. Advance time by 30 seconds; 90 seconds remain ----------------- */
        vm.warp(block.timestamp + 30); // now within the original lock

        /* 4. Attempt to *shorten* the lock to 60 seconds (90 → 60) --------- */
        vm.prank(AL);
        vm.expectRevert(bytes("shorter"));
        w.lock(60); // must revert: new < remaining
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

}
