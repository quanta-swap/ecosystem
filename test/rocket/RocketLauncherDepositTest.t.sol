// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*──────── shared scaffolding & lightweight mocks (no hacks) ───────*/
import "./RocketLauncherTestBase.sol"; // from previous step

/**
 * @title  DepositTest
 * @notice Unit‑tests the public `deposit` entry‑point.  Every branch that can
 *         be reached **without artificial storage hacks** is explicitly covered.
 *
 *         Covered paths
 *         ─────────────
 *         ✓ Happy‑path single deposit (event + state)
 *         ✓ Multiple deposits aggregate correctly
 *         ✓ ZeroDeposit             → custom error
 *         ✓ UnknownRocket           → custom error
 *         ✓ AlreadyLaunched         → custom error (after a real launch)
 *
 * @dev    Overflow branches (`SumOverflow`) require pre‑existing values that
 *         cross the 2⁶⁴ boundary.  Achieving that without manipulating storage
 *         would exceed the ERC‑20’s 64‑bit supply cap, so they are *not* part
 *         of this harness per the “no storage hacks” directive.
 */
contract DepositTest is RocketLauncherTestBase {
    /*──────────────────────── helper: create + mint ───────────────────*/
    /**
     * @dev Deploys a new rocket and returns its ID and inviting token.
     *      Mints `mintAmt` tokens to `who` and pre‑approves the launcher.
     */
    function _setupRocket(
        address who,
        uint64 mintAmt
    ) private returns (uint256 id, ERC20Mock invit) {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        id = launcher.createRocket(cfg);

        invit = ERC20Mock(address(cfg.invitingToken));
        invit.mint(who, mintAmt);
        vm.prank(who);
        invit.approve(address(launcher), mintAmt);
    }

    /*══════════════════════ positive paths ═══════════════════════════*/

    /**
     * @notice Single 50 INV deposit from the creator.
     */
    function testDeposit_Succeeds_Single() external {
        uint64 amt = 50 * ONE;
        (uint256 id, ERC20Mock invit) = _setupRocket(AL, amt);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.Deposited(id, AL, amt);

        vm.prank(AL);
        launcher.deposit(id, amt);

        assertEq(invit.balanceOf(address(launcher)), amt, "launcher bal");
        assertEq(launcher.deposited(id, AL), amt, "per-user");
        assertEq(launcher.totalInviteContributed(id), amt, "aggregate");
    }

    /**
     * @notice Two deposits (creator then participant) aggregate correctly.
     */
    function testDeposit_Succeeds_Multiple() external {
        uint64 cAmt = 40 * ONE;
        uint64 pAmt = 60 * ONE;
        uint64 total = cAmt + pAmt;

        /* creator deposit */
        (uint256 id, ERC20Mock invit) = _setupRocket(AL, cAmt);
        vm.prank(AL);
        launcher.deposit(id, cAmt);

        /* participant deposit */
        invit.mint(BO, pAmt);
        vm.startPrank(BO);
        invit.approve(address(launcher), pAmt);
        launcher.deposit(id, pAmt);
        vm.stopPrank();

        /* tallies */
        assertEq(launcher.deposited(id, AL), cAmt, "creator tally");
        assertEq(launcher.deposited(id, BO), pAmt, "participant tally");
        assertEq(launcher.totalInviteContributed(id), total, "aggregate");
    }

    /*══════════════════════ revert paths ════════════════════════════*/

    /// amount == 0
    function testDeposit_Revert_ZeroDeposit() external {
        (uint256 id, ) = _setupRocket(AL, 0);
        vm.prank(AL);
        vm.expectRevert(ZeroDeposit.selector);
        launcher.deposit(id, 0);
    }

    /// unmapped rocket ID
    function testDeposit_Revert_UnknownRocket() external {
        vm.expectRevert(abi.encodeWithSelector(UnknownRocket.selector, 999));
        launcher.deposit(999, 1);
    }

    /// depositing after liquidity deployment
    function testDeposit_Revert_AlreadyLaunched() external {
        uint64 stake = 30 * ONE;

        /* prepare rocket + deposit so launch can proceed */
        (uint256 id, ERC20Mock invit) = _setupRocket(AL, stake);
        vm.prank(AL);
        launcher.deposit(id, stake);

        /* launch */
        RocketConfig memory cfg = _defaultConfig();
        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* BO attempts late deposit */
        invit.mint(BO, stake);
        vm.startPrank(BO);
        invit.approve(address(launcher), stake);
        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector, id));
        launcher.deposit(id, stake);
        vm.stopPrank();
    }
}
