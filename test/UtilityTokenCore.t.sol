// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────── Forge & SUT imports ───────────────────────*/
import "lib/forge-std/src/Test.sol";
import "../src/_utility.sol"; // ← adjust path if needed

/*────────────────────────── Helpers & constants ─────────────────────*/
uint256 constant ONE_TOKEN = 1e9; // 1 unit assuming 9‑dec token
uint64 constant SUPPLY64 = 1_000_000 * 1e9; // 1 M tokens (64‑bit safe)
uint32 constant LOCK_TIME = 1 hours; // 3600‑second epoch windows

address constant AL = address(0xA11); // Alice
address constant BO = address(0xB0B); // Bob
address constant CA = address(0xCa7); // Carol

/*──────────────────────────── Test suite ────────────────────────────*/
/**
 * @title StandardUtilityTokenTest (skeleton)
 * @notice Boiler‑plate Foundry test harness for the 64‑bit IZRC‑20 token with
 *         epoch‑based locking.  All behavioural tests are TODO.
 */
contract StandardUtilityTokenTest is Test {
    /* solhint-disable var-name-mixedcase */
    StandardUtilityToken private SUT; // system under test

    /*──────── set‑up ────────*/
    function setUp() public {
        // Deploy token and prime test actors with Ether for tx gas if needed.
        SUT = new StandardUtilityToken(
            "Utility",
            "UTK",
            SUPPLY64,
            9,
            LOCK_TIME,
            address(this),
            "google.com"
        );

        vm.deal(AL, 100 ether);
        vm.deal(BO, 100 ether);
        vm.deal(CA, 100 ether);

        // Transfer initial balances to test actors for convenience.
        SUT.transfer(AL, 100_000 * 1e9);
        SUT.transfer(BO, 100_000 * 1e9);
        SUT.transfer(CA, 100_000 * 1e9);
    }

    /*───────────────────────────── Unit tests ─────────────────────────────*/

    /*────────────────── constructor event tests ──────────────────*/

    /**
     * @notice Deploying the token **must** emit a single ERC-20 `Transfer`
     *         signalling the mint of the fixed supply.
     * @dev    • The constructor credits `root`’s balance but emits the
     *           event with `to = msg.sender` (the deployer).
     *         • We expect the event *before* the `new` statement so that
     *           Foundry matches it during contract creation.
     *         • Post-deploy, we sanity-check the recipient’s balance.
     */
    function testConstructorEmitsInitialTransfer() public {
        /* 1️⃣  Expect the Transfer event exactly once. */
        vm.expectEmit(
            true /* indexed from */,
            true /* indexed to */,
            false,
            true
        );
        emit IZRC20.Transfer(address(0), address(1), SUPPLY64);

        /* 2️⃣  Deploy a fresh token (constructor will fire the event). */
        StandardUtilityToken tok = new StandardUtilityToken(
            "Ctor-Event",
            "CTOR",
            SUPPLY64,
            9,
            LOCK_TIME,
            address(1), // root == deployer for simple parity
            "ipfs://theme-banner"
        );

        /* 3️⃣  Sanity-check that the deployer received the supply. */
        assertEq(tok.balanceOf(address(1)), SUPPLY64, "mint balance mismatch");
    }

    /*────────────────── theme() tests ──────────────────*/

    /**
     * @notice `theme()` must return the exact hard-coded YouTube URL.
     * @dev    Ensures future refactors don’t accidentally change or remove it.
     *         • Deploy a fresh factory.
     *         • Call `theme()` and compare against the literal string.
     *         • Uses `assertEq(string,string)` from forge-std.
     */
    function testThemeReturnsExpectedURL() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        string memory expected = "https://www.youtube.com/watch?v=kpnW68Q8ltc";

        assertEq(dep.theme(), expected, "theme URL mismatch");
    }

    /*───────────────────────────── setLocker tests ─────────────────────────────*/

    /// @notice Caller (holder) can approve a locker; mapping toggles to true.
    function testSetLockerApprove() public {
        vm.prank(AL); // holder = AL
        SUT.setLocker(BO, true); // approve BO as locker

        bool ok = SUT.isLocker(AL, BO); // query via public helper
        assertTrue(ok, "locker flag not set");
    }

    /// @notice Caller can subsequently revoke the same locker.
    function testSetLockerRevoke() public {
        vm.startPrank(AL);
        SUT.setLocker(BO, true); // approve first
        SUT.setLocker(BO, false); // revoke
        vm.stopPrank();

        assertFalse(SUT.isLocker(AL, BO), "locker flag should be false");
    }

    /// @notice Zero address as locker should revert with `ZeroAddress(addr)`.
    function testSetLockerZeroAddressRevert() public {
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.setLocker(address(0), true);
    }

    /// @notice A third‑party caller sets a locker for themselves – must not
    ///         affect another holder’s registry.
    function testSetLockerIsolationBetweenHolders() public {
        // Deployer (root) approves BO as its locker
        SUT.setLocker(BO, true);
        assertTrue(SUT.isLocker(address(this), BO));

        // AL’s registry remains untouched (false)
        assertFalse(SUT.isLocker(AL, BO));
    }

    /// @notice Event emission sanity: LockerSet(holder, locker, approved).
    function testSetLockerEventEmitted() public {
        vm.prank(AL);

        // Expect event with indexed params holder & locker
        vm.expectEmit(true, true, false, true);
        emit LockerSet(AL, BO, true);

        SUT.setLocker(BO, true);
    }

    /*───────────────────────────── isLocker tests ─────────────────────────────*/

    /// @notice `isLocker` returns false by default for arbitrary pairs.
    function testIsLockerDefaultFalse() public view {
        assertFalse(SUT.isLocker(AL, BO), "default should be false");
    }

    /// @notice `isLocker` flips to true immediately after approval.
    function testIsLockerAfterApprove() public {
        vm.prank(AL);
        SUT.setLocker(BO, true);
        assertTrue(
            SUT.isLocker(AL, BO),
            "should be true after setLocker(true)"
        );
    }

    /// @notice After revocation, `isLocker` reverts to false.
    function testIsLockerAfterRevoke() public {
        vm.startPrank(AL);
        SUT.setLocker(BO, true);
        SUT.setLocker(BO, false);
        vm.stopPrank();
        assertFalse(
            SUT.isLocker(AL, BO),
            "should be false after setLocker(false)"
        );
    }

    /*──────────────────────────── lock() tests ───────────────────────────*/

    // 1. Happy-path: authorised locker locks 10 tokens; view & event work.
    /// @notice Authorised locker locks 10 tokens; event and view both update.
    function testLockHappyPath() public {
        _approveLocker(); // AL → BO approved once

        uint64 lockAmt = 10 * uint64(ONE_TOKEN);
        uint64 epoch = uint64(block.timestamp / LOCK_TIME);

        // Expect the TokensLocked event (indexed holder & locker)
        vm.expectEmit(true, true, false, true);
        emit TokensLocked(AL, BO, lockAmt, epoch);

        // Single prank that performs the state-changing call
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        // Post-conditions
        assertEq(SUT.balanceOfLocked(AL), lockAmt, "locked amount incorrect");
    }

    // 2. Locker not authorised → UnauthorizedLocker(holder, caller) revert.
    function testLockUnauthorizedRevert() public {
        uint64 amt = 1 * uint64(ONE_TOKEN);
        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(UnauthorizedLocker.selector, AL, BO)
        );
        SUT.lock(AL, amt);
    }

    // 3. Attempt to lock more than the current unlocked balance → InsufficientUnlocked.
    function testLockInsufficientUnlockedRevert() public {
        _approveLocker();

        // current unlocked = total – current locked (0)
        uint64 unlocked = uint64(SUT.balanceOf(AL) - SUT.balanceOfLocked(AL));
        uint64 attempt = unlocked + 1; // one token too many

        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientUnlocked.selector,
                unlocked,
                attempt
            )
        );
        SUT.lock(AL, attempt);
    }

    // 4. Lock expires automatically at the next epoch boundary.
    function testLockExpiresWithNewEpoch() public {
        _approveLocker();
        uint64 lockAmt = 5 * uint64(ONE_TOKEN);

        vm.prank(BO);
        SUT.lock(AL, lockAmt);
        assertEq(SUT.balanceOfLocked(AL), lockAmt);

        // Move past the epoch window + 1 second.
        vm.warp(block.timestamp + LOCK_TIME + 1);
        assertEq(SUT.balanceOfLocked(AL), 0, "lock should have expired");
    }

    /// @notice Locking again after a full epoch rollover must:
    ///         • zero-out the stale `locked` counter,
    ///         • emit a fresh TokensLocked event with the **new** epoch value, and
    ///         • reflect the new amount in {balanceOfLocked}.
    function testLockResetsOnNewEpoch() public {
        /* 1.  AL designates BO as an authorised locker. */
        vm.prank(AL);
        SUT.setLocker(BO, true);

        /* 2.  BO locks 10 000 UTK in the **current** epoch window. */
        uint64 firstLock = 10_000 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.lock(AL, firstLock);
        assertEq(SUT.balanceOfLocked(AL), firstLock, "initial lock set");

        /* 3.  Fast-forward past the whole epoch so the window expires. */
        vm.warp(block.timestamp + uint256(LOCK_TIME) + 1);
        assertEq(SUT.balanceOfLocked(AL), 0, "lock should auto-expire");

        /* 4.  Lock again – hits the `epoch != acc.window` branch and resets. */
        uint64 secondLock = 5_000 * uint64(ONE_TOKEN);
        uint64 newEpoch = uint64(block.timestamp / LOCK_TIME);

        vm.expectEmit(true, true, false, true);
        emit TokensLocked(AL, BO, secondLock, newEpoch);

        vm.prank(BO);
        SUT.lock(AL, secondLock);

        /* 5.  Only the new amount is considered locked. */
        assertEq(SUT.balanceOfLocked(AL), secondLock, "new lock recorded");
    }

    /*──────────────────────────── viewer tests ───────────────────────────*/

    /* totalSupply is fixed and never changes */
    function testTotalSupplyConstant() public {
        assertEq(SUT.totalSupply(), SUPPLY64, "initial supply mismatch");

        // Transfer some tokens around – supply must remain constant
        vm.prank(AL);
        SUT.transfer(BO, 5 * uint64(ONE_TOKEN));
        assertEq(SUT.totalSupply(), SUPPLY64, "supply mutated unexpectedly");
    }

    /* balanceOf tracks transfers */
    function testBalanceOfReflectsTransfer() public {
        uint64 sendAmt = 3 * uint64(ONE_TOKEN);

        uint64 balAL = SUT.balanceOf(AL);
        uint64 balBO = SUT.balanceOf(BO);

        vm.prank(AL);
        SUT.transfer(BO, sendAmt);

        assertEq(SUT.balanceOf(AL), balAL - sendAmt, "AL balance mismatch");
        assertEq(SUT.balanceOf(BO), balBO + sendAmt, "BO balance mismatch");
    }

    /* balanceOfLocked defaults to zero */
    function testBalanceOfLockedDefaultZero() public view {
        assertEq(SUT.balanceOfLocked(AL), 0, "should start unlocked");
    }

    /* balanceOfLocked returns the live locked amount within current window */
    function testBalanceOfLockedCurrentEpoch() public {
        _approveLocker();

        uint64 lockAmt = 7 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        assertEq(SUT.balanceOfLocked(AL), lockAmt, "locked amt incorrect");
    }

    /* balanceOfLocked resets to zero when epoch advances */
    function testBalanceOfLockedExpiresNextEpoch() public {
        _approveLocker();

        uint64 lockAmt = 4 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        // fast-forward one full epoch + 1 second
        vm.warp(block.timestamp + LOCK_TIME + 1);
        assertEq(SUT.balanceOfLocked(AL), 0, "lock should have expired");
    }

    /* allowance: default 0 then updates via approve */
    function testAllowanceDefaultAndAfterApprove() public {
        assertEq(SUT.allowance(AL, BO), 0, "default allowance");

        uint64 allowAmt = 2 * uint64(ONE_TOKEN);
        vm.prank(AL);
        SUT.approve(BO, allowAmt);

        assertEq(SUT.allowance(AL, BO), allowAmt, "allowance not set");
    }

    /* name / symbol / decimals metadata */
    function testMetadataGetters() public view {
        assertEq(SUT.name(), "Utility");
        assertEq(SUT.symbol(), "UTK");
        assertEq(SUT.decimals(), 9);
    }

    /*───────────────────────────── approve() tests ─────────────────────────────*/

    /// @notice Approving a non-zero spender sets the allowance and returns `true`.
    function testApproveSetsAllowance() public {
        uint64 allowAmt = 5 * uint64(ONE_TOKEN);

        vm.prank(AL);
        bool ok = SUT.approve(BO, allowAmt);

        assertTrue(ok, "approve should return true");
        assertEq(SUT.allowance(AL, BO), allowAmt, "allowance not recorded");
    }

    /// @notice Calling approve a second time overwrites the previous value.
    function testApproveOverwritesAllowance() public {
        uint64 firstAmt = 2 * uint64(ONE_TOKEN);
        uint64 secondAmt = 7 * uint64(ONE_TOKEN);

        vm.startPrank(AL);
        SUT.approve(BO, firstAmt);
        SUT.approve(BO, secondAmt); // overwrite
        vm.stopPrank();

        assertEq(SUT.allowance(AL, BO), secondAmt, "allowance not overwritten");
    }

    /// @notice Approving the zero address as spender must revert with ZeroAddress.
    function testApproveZeroAddressRevert() public {
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.approve(address(0), 1);
    }

    /// @notice Approval emits the correct event.
    function testApproveEventEmitted() public {
        uint64 amt = 3 * uint64(ONE_TOKEN);

        vm.prank(AL);
        vm.expectEmit(true, true, false, true);
        emit IZRC20.Approval(AL, BO, amt);

        SUT.approve(BO, amt);
    }

    /// @notice Approving `uint64.max` gives an “infinite” allowance.
    function testApproveInfiniteAllowance() public {
        vm.prank(AL);
        SUT.approve(BO, type(uint64).max);
        assertEq(SUT.allowance(AL, BO), type(uint64).max, "infinite not set");
    }

    /*────────────────────────────── transfer() tests ─────────────────────────────*/

    /// @notice Happy path: AL → BO moves tokens, returns true, emits event.
    function testTransferHappyPath() public {
        uint64 amt = 10_000 * uint64(ONE_TOKEN);

        vm.prank(AL);
        vm.expectEmit(true, true, false, true); // indexed from & to
        emit IZRC20.Transfer(AL, BO, amt);

        bool ok = SUT.transfer(BO, amt);
        assertTrue(ok, "transfer() must return true");

        assertEq(SUT.balanceOf(AL), 90_000 * ONE_TOKEN, "AL balance");
        assertEq(SUT.balanceOf(BO), 110_000 * ONE_TOKEN, "BO balance");
    }

    /// @notice Zero-address recipient should revert with `ZeroAddress`.
    function testTransferZeroAddressRevert() public {
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.transfer(address(0), 1);
    }

    /// @notice Transfer fails when the caller tries to move more than the
    ///         current unlocked balance, emitting an InsufficientUnlocked error
    ///         that we match on *selector + args*.
    function testTransferInsufficientUnlockedRevert() public {
        /* ── 1.  Give Alice a predictable 10 000-token balance ───────────── */
        uint64 targetBal = 10_000 * 1e9; // 10 000 UTK (9-dec)
        uint64 curBal = SUT.balanceOf(AL);
        if (curBal > targetBal) {
            vm.prank(AL);
            SUT.transfer(address(this), curBal - targetBal); // drain surplus
        } else if (curBal < targetBal) {
            // top-up from root if we ever change the fixture
            SUT.transfer(AL, targetBal - curBal);
        }

        /* ── 2.  Alice designates Bob as her locker and Bob locks 5 000 ──── */
        uint64 lockAmt = 5_000 * 1e9; // 5 000 UTK
        vm.prank(AL);
        SUT.setLocker(BO, true);

        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        /* ── 3.  Alice now tries to transfer 6 000 UTK (only 5 000 unlocked) */
        uint64 xferAmt = 6_000 * 1e9; // 6 000 UTK
        uint64 unlocked = targetBal - lockAmt; // = 5 000 UTK

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientUnlocked.selector,
                unlocked,
                xferAmt
            )
        );
        SUT.transfer(BO, xferAmt);
    }

    /// @notice After the epoch window expires, previously locked tokens become free.
    function testTransferSucceedsAfterEpochExpiry() public {
        uint64 lockAmt = 80_000 * uint64(ONE_TOKEN);
        uint64 sendAmt = 75_000 * uint64(ONE_TOKEN);

        /* Approve & lock */
        vm.prank(AL);
        SUT.setLocker(BO, true);
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        /* Jump one full epoch forward so locks lapse */
        vm.warp(block.timestamp + LOCK_TIME + 1);

        vm.prank(AL);
        bool ok = SUT.transfer(CA, sendAmt);
        assertTrue(ok);

        assertEq(
            SUT.balanceOf(CA),
            100_000 * ONE_TOKEN + sendAmt,
            "CA balance"
        );
    }

    /// @notice Self-transfer of non-zero tokens leaves net balance unchanged but emits Transfer.
    function testTransferSelfNoEffect() public {
        uint64 amt = 1_234 * uint64(ONE_TOKEN);

        vm.prank(AL);
        vm.expectEmit(true, true, false, true);
        emit IZRC20.Transfer(AL, AL, amt);

        SUT.transfer(AL, amt);
        assertEq(
            SUT.balanceOf(AL),
            100_000 * ONE_TOKEN,
            "balance should be unchanged"
        );
    }

    /// @notice Zero-value transfer is a no-op that still returns true and emits an event.
    function testTransferZeroValue() public {
        vm.prank(AL);
        vm.expectEmit(true, true, false, true);
        emit IZRC20.Transfer(AL, BO, 0);

        bool ok = SUT.transfer(BO, 0);
        assertTrue(ok);

        // all balances unchanged
        assertEq(SUT.balanceOf(AL), 100_000 * ONE_TOKEN);
        assertEq(SUT.balanceOf(BO), 100_000 * ONE_TOKEN);
    }

    /*──────────────────────── transferFrom() tests ─────────────────*/

    /// @notice Happy‑path: allowance decreases, balances move, Transfer+Approval events.
    function testTransferFromHappyPath() public {
        uint64 allowanceAmt = 10_000 * uint64(ONE_TOKEN);
        uint64 spend = 6_000 * uint64(ONE_TOKEN);

        // AL approves BO
        vm.prank(AL);
        SUT.approve(BO, allowanceAmt);

        // Expect events: Approval tick‑down & Transfer
        vm.recordLogs();
        vm.prank(BO);
        bool ok = SUT.transferFrom(AL, CA, spend);
        assertTrue(ok);

        // Post‑conditions
        assertEq(SUT.balanceOf(AL), 94_000 * ONE_TOKEN);
        assertEq(SUT.balanceOf(CA), 106_000 * ONE_TOKEN);
        assertEq(SUT.allowance(AL, BO), allowanceAmt - spend);

        // Check that both events were emitted (order: Approval, Transfer)
        Vm.Log[] memory ev = vm.getRecordedLogs();
        assertEq(ev.length, 2);
    }

    /// @notice Insufficient allowance should revert with `InsufficientAllowance`.
    function testTransferFromInsufficientAllowanceRevert() public {
        vm.prank(AL);
        SUT.approve(BO, 1 * uint64(ONE_TOKEN));

        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientAllowance.selector,
                1 * ONE_TOKEN,
                2 * ONE_TOKEN
            )
        );
        SUT.transferFrom(AL, CA, 2 * uint64(ONE_TOKEN));
    }

    /// @notice Infinite allowance sentinel (`uint64.max`) must not tick down.
    function testTransferFromInfiniteAllowanceNoTickDown() public {
        vm.prank(AL);
        SUT.approve(BO, type(uint64).max);

        uint64 spend = 4_000 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.transferFrom(AL, CA, spend);

        assertEq(SUT.allowance(AL, BO), type(uint64).max);
    }

    /// @notice Transfer attempts that exceed unlocked balance revert.
    function testTransferFromInsufficientUnlockedRevert() public {
        // AL sets BO as locker and BO locks most of AL’s balance
        vm.startPrank(AL);
        SUT.setLocker(BO, true);
        vm.stopPrank();

        uint64 lockAmt = 99_000 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        // AL approves BO full balance
        vm.prank(AL);
        SUT.approve(BO, 100_000 * uint64(ONE_TOKEN));

        vm.prank(BO);
        uint64 spend = 6_000 * uint64(ONE_TOKEN); // > unlocked (~1k)
        vm.expectRevert();
        SUT.transferFrom(AL, CA, spend);
    }

    /// @notice Zero destination address should revert with `ZeroAddress`.
    function testTransferFromZeroAddressRevert() public {
        vm.prank(AL);
        SUT.approve(BO, 1_000 * uint64(ONE_TOKEN));

        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.transferFrom(AL, address(0), 1);
    }

    /*──────────────────────── transferBatch() tests ─────────────────*/

    /// Happy‑path batch transfer: balances, totals, and events.
    function testTransferBatchHappyPath() public {
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        rcpt[1] = CA;
        amt[0] = 2_000 * uint64(ONE_TOKEN);
        amt[1] = 3_000 * uint64(ONE_TOKEN);

        vm.prank(AL);
        // Expect two Transfer events (AL→BO and AL→CA) in sequence.
        vm.expectEmit(true, true, false, true);
        emit IZRC20.Transfer(AL, BO, amt[0]);
        emit IZRC20.Transfer(AL, CA, amt[1]);

        bool ok = SUT.transferBatch(rcpt, amt);
        assertTrue(ok);

        assertEq(SUT.balanceOf(AL), 95_000 * ONE_TOKEN, "AL bal");
        assertEq(SUT.balanceOf(BO), 102_000 * ONE_TOKEN, "BO bal");
        assertEq(SUT.balanceOf(CA), 103_000 * ONE_TOKEN, "CA bal");
    }

    /// Mismatched array lengths must revert with `LengthMismatch`.
    function testTransferBatchLengthMismatchRevert() public {
        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        amt[0] = 1;
        amt[1] = 1;

        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, 1, 2));
        SUT.transferBatch(rcpt, amt);
    }

    /// Aggregate sum > uint64.max triggers `SumOverflow` before any state change.
    function testTransferBatchSumOverflowRevert() public {
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        rcpt[1] = CA;
        amt[0] = type(uint64).max;
        amt[1] = 1; // max + 1 → overflow

        uint256 overflowSum = uint256(type(uint64).max) + 1;
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(SumOverflow.selector, overflowSum)
        );
        SUT.transferBatch(rcpt, amt);
    }

    /// Any zero‑address recipient should revert with `ZeroAddress`.
    function testTransferBatchZeroAddressRevert() public {
        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = address(0);
        amt[0] = 1;

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.transferBatch(rcpt, amt);
    }

    /// Sender tries to spend more than their unlocked balance → `InsufficientUnlocked`.
    function testTransferBatchInsufficientUnlockedRevert() public {
        // AL approves BO as locker and BO locks most of AL’s balance
        vm.startPrank(AL);
        SUT.setLocker(BO, true);
        vm.stopPrank();

        uint64 lockAmt = 99_000 * uint64(ONE_TOKEN);
        vm.prank(BO);
        SUT.lock(AL, lockAmt);

        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = CA;
        amt[0] = 6_000 * uint64(ONE_TOKEN); // > unlocked (~1k)

        uint64 unlocked = 1_000 * uint64(ONE_TOKEN);
        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientUnlocked.selector,
                unlocked,
                amt[0]
            )
        );
        SUT.transferBatch(rcpt, amt);
    }

    /// Verify that exactly N Transfer events (one per leg) are emitted.
    function testTransferBatchEventCount() public {
        address[] memory rcpt = new address[](3);
        uint64[] memory amt = new uint64[](3);
        rcpt[0] = BO;
        amt[0] = 1_000 * uint64(ONE_TOKEN);
        rcpt[1] = CA;
        amt[1] = 1_000 * uint64(ONE_TOKEN);
        rcpt[2] = BO;
        amt[2] = 2_000 * uint64(ONE_TOKEN);

        vm.recordLogs();
        vm.prank(AL);
        SUT.transferBatch(rcpt, amt);

        Vm.Log[] memory ev = vm.getRecordedLogs();
        assertEq(ev.length, 3, "expected 3 Transfer events");
    }

    /*──────────────────────── transferFromBatch() tests ─────────────────*/

    /// Happy‑path: spender moves funds for `from` via batch; allowance ticks down and events fired.
    function testTransferFromBatchHappyPath() public {
        // Prepare recipients & amounts
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        rcpt[1] = CA;
        amt[0] = 2_000 * uint64(ONE_TOKEN);
        amt[1] = 3_000 * uint64(ONE_TOKEN);
        uint64 spend = amt[0] + amt[1];

        // AL approves BO
        vm.prank(AL);
        SUT.approve(BO, spend);

        // Expect: Approval tick‑down then two Transfer events
        vm.recordLogs();
        vm.prank(BO);
        bool ok = SUT.transferFromBatch(AL, rcpt, amt);
        assertTrue(ok);

        // Allowance consumed
        assertEq(SUT.allowance(AL, BO), 0);
        // Balances updated
        assertEq(SUT.balanceOf(AL), 95_000 * ONE_TOKEN);
        assertEq(SUT.balanceOf(BO), 102_000 * ONE_TOKEN);
        assertEq(SUT.balanceOf(CA), 103_000 * ONE_TOKEN);

        // Event count = 1 Approval + 2 Transfer
        Vm.Log[] memory ev = vm.getRecordedLogs();
        assertEq(ev.length, 3, "expected 3 events total");
    }

    /// Length mismatch should revert with `LengthMismatch`.
    function testTransferFromBatchLengthMismatchRevert() public {
        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = CA;
        amt[0] = 1;
        amt[1] = 1;

        vm.prank(BO);
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector, 1, 2));
        SUT.transferFromBatch(AL, rcpt, amt);
    }

    /// Sum overflow should revert with `SumOverflow`.
    function testTransferFromBatchSumOverflowRevert() public {
        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        rcpt[1] = CA;
        amt[0] = type(uint64).max;
        amt[1] = 1;
        uint256 overflowSum = uint256(type(uint64).max) + 1;

        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(SumOverflow.selector, overflowSum)
        );
        SUT.transferFromBatch(AL, rcpt, amt);
    }

    /// @notice Zero-address recipient should revert with `ZeroAddress`.
    function testTransferFromBatchZeroAddressRevert() public {
        // ── 1. Give BO just enough allowance to pass the allowance check
        vm.prank(AL);
        SUT.approve(BO, 1 * uint64(ONE_TOKEN));

        // ── 2. Build calldata with a single zero-address recipient
        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = address(0);
        amt[0] = 1 * uint64(ONE_TOKEN);

        // ── 3. Expect the ZeroAddress revert (reaches _credited() branch)
        vm.prank(BO);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        SUT.transferFromBatch(AL, rcpt, amt);
    }

    /// Insufficient allowance triggers revert.
    function testTransferFromBatchInsufficientAllowanceRevert() public {
        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = CA;
        amt[0] = 2_000 * uint64(ONE_TOKEN);

        vm.prank(BO);
        vm.expectRevert(); // generic check – selector includes current/needed
        SUT.transferFromBatch(AL, rcpt, amt);
    }

    /// Spending more than unlocked balance reverts with `InsufficientUnlocked`.
    function testTransferFromBatchInsufficientUnlockedRevert() public {
        // Lock AL’s funds
        vm.startPrank(AL);
        SUT.setLocker(BO, true);
        vm.stopPrank();
        vm.prank(BO);
        SUT.lock(AL, 99_000 * uint64(ONE_TOKEN)); // leave ~1k unlocked

        // AL grants large allowance to BO
        vm.prank(AL);
        SUT.approve(BO, 10_000 * uint64(ONE_TOKEN));

        address[] memory rcpt = new address[](1);
        uint64[] memory amt = new uint64[](1);
        rcpt[0] = CA;
        amt[0] = 6_000 * uint64(ONE_TOKEN); // > unlocked

        vm.prank(BO);
        vm.expectRevert();
        SUT.transferFromBatch(AL, rcpt, amt);
    }

    /// Infinite allowance sentinel – allowance must remain max after spend.
    function testTransferFromBatchInfiniteAllowanceNoTickDown() public {
        // AL grants infinite allowance to BO
        vm.prank(AL);
        SUT.approve(BO, type(uint64).max);

        address[] memory rcpt = new address[](2);
        uint64[] memory amt = new uint64[](2);
        rcpt[0] = BO;
        amt[0] = 1_000 * uint64(ONE_TOKEN);
        rcpt[1] = CA;
        amt[1] = 1_000 * uint64(ONE_TOKEN);

        vm.prank(BO);
        SUT.transferFromBatch(AL, rcpt, amt);

        assertEq(
            SUT.allowance(AL, BO),
            type(uint64).max,
            "allow should remain max"
        );
    }

    /// Verify Transfer event count equals array length.
    function testTransferFromBatchEventCountMatchesLength() public {
        address[] memory rcpt = new address[](3);
        uint64[] memory amt = new uint64[](3);
        rcpt[0] = BO;
        amt[0] = 500 * uint64(ONE_TOKEN);
        rcpt[1] = CA;
        amt[1] = 500 * uint64(ONE_TOKEN);
        rcpt[2] = BO;
        amt[2] = 500 * uint64(ONE_TOKEN);
        uint64 spend = amt[0] + amt[1] + amt[2];

        vm.prank(AL);
        SUT.approve(BO, spend);

        vm.recordLogs();
        vm.prank(BO);
        SUT.transferFromBatch(AL, rcpt, amt);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // 1 Approval + 3 Transfer events
        assertEq(logs.length, 4, "expected 4 events");
    }

    /*────────────────── UtilityTokenDeployer tests ──────────────────*/

    function testDeployerCreatesTokenHappyPath() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        string memory name_ = "Utility-Spawn";
        string memory symbol_ = "USPN";
        uint64 supply64 = 500_000 * uint64(ONE_TOKEN);
        uint8 decs = 9;
        address root = AL; // recipient of full supply

        // Deploy via factory
        address tokAddr = dep.create(
            name_,
            symbol_,
            supply64,
            decs,
            LOCK_TIME,
            root,
            bytes("google.com")
        );
        assertTrue(tokAddr != address(0), "factory returned zero address");

        // Sanity-check the freshly-minted token
        StandardUtilityToken tok = StandardUtilityToken(tokAddr);
        assertEq(tok.name(), name_);
        assertEq(tok.symbol(), symbol_);
        assertEq(tok.decimals(), decs);
        assertEq(tok.totalSupply(), supply64);
        assertEq(tok.balanceOf(root), supply64);
    }

    function testDeployerZeroRootRevert() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        dep.create("X", "X", 1, 9, LOCK_TIME, address(0), bytes("google.com"));
    }

    function testDeployerLockTimeZeroRevert() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        vm.expectRevert(abi.encodeWithSelector(LockTimeZero.selector));
        dep.create("X", "X", 1, 9, 0, AL, bytes("google.com")); // lockTime_ == 0 bubbles up
    }

    function testCreateEmitsDeployedEvent() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        // We only care that the *event* is emitted, not the exact address,
        // so we ignore the (indexed) topic value and just match the signature.
        vm.expectEmit(false /* topic1 */, false, false, true /* data */);
        emit Deployed(address(0)); // placeholder; topic value ignored

        address token = dep.create(
            "Utility",
            "UTK",
            1_000_000,
            9,
            1 hours,
            address(this),
            bytes("google.com")
        );

        assertTrue(token != address(0), "token addr is zero");
    }

    /*────────────────── theme (deployed token) tests ──────────────────*/

    /**
     * @notice The factory must pass the `theme_` string through to the
     *         new token so that its `theme()` getter returns the same value.
     * @dev    • Deploy a token via the factory with a distinctive theme URL.
     *         • Cast the returned address to StandardUtilityToken.
     *         • Assert that `theme()` equals the original string.
     */
    function testDeployerTokenThemePropagates() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        string
            memory themeStr = "https://ipfs.example.org/ipfs/QmThemeBannerHash";

        // Deploy via factory
        address tokAddr = dep.create(
            "Theme-Coin",
            "THM",
            10_000 * uint64(ONE_TOKEN),
            9,
            LOCK_TIME,
            AL, // root holder
            bytes(themeStr) // ← theme argument under test
        );

        // Verify the getter on the deployed token
        StandardUtilityToken tok = StandardUtilityToken(tokAddr);
        assertEq(tok.theme(), themeStr, "deployed token theme mismatch");
    }

    /*────────────────── verify() tests ──────────────────*/

    /// @notice After a token is created via the factory, `verify` must
    ///         return true for its address.
    function testVerifyReturnsTrueForDeployedToken() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        // Deploy a fresh token
        address token = dep.create(
            "Verify-Me",
            "VM",
            123_456 * uint64(ONE_TOKEN),
            9,
            LOCK_TIME,
            AL, // root / initial holder,
            bytes("google.com")
        );
        assertTrue(token != address(0), "token should not be zero");

        // The factory should now recognise the address
        bool ok = dep.verify(token);
        assertTrue(ok, "verify() should return true for deployed token");
    }

    /// @notice Any arbitrary or random address that was *not* produced by
    ///         the factory must cause `verify` to return false.
    function testVerifyReturnsFalseForUnknownAddress() public {
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        // Use an address that can never be a Create2 result from the factory
        address bogus = address(0xDEAD_BEEF);

        bool ok = dep.verify(bogus);
        assertFalse(ok, "verify() should be false for non-factory addresses");
    }

    /**
     * @notice `authority()` must equal the transaction origin that deployed
     *         the token (EOA or contract).  We prank so both msg.sender and
     *         tx.origin are AL for the full depth of the call-stack.
     */
    function testAuthorityCapturesTxOrigin() public {
        /* 1. fresh factory */
        UtilityTokenDeployer dep = new UtilityTokenDeployer();

        /* 2. single-call prank → sets msg.sender *and* tx.origin to AL */
        vm.prank(AL, AL);
        address tokAddr = dep.create(
            "Auth-Coin",
            "AUTH",
            10_000 * uint64(ONE_TOKEN),
            9,
            LOCK_TIME,
            AL, // root holder
            bytes("auth.test")
        );

        /* 3. check the immutable field */
        assertEq(
            StandardUtilityToken(tokAddr).authority(),
            AL,
            "authority should record tx.origin"
        );
    }

    /*───────────────── helpers ─────────────────*/

    /**
     * @dev Approve BO as AL’s locker once.  Used by several tests.
     */
    function _approveLocker() internal {
        vm.prank(AL);
        SUT.setLocker(BO, true);
    }
}
