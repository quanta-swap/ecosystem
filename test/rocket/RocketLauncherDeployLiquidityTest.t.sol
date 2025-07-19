// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────── Forge stdlib ──────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*──────── shared launcher scaffolding & local mocks ────────────*/
import "./RocketLauncherTestBase.sol";
import "./mocks/Mocks.sol";

/*════════════════════════════════════════════════════════════════*\
│       Auxiliary mocks used ONLY by this deploy‑liquidity suite    │
\*════════════════════════════════════════════════════════════════*/

/**
 * @title  ERC20BadApprove
 * @notice `approve` never succeeds ⇒ `safeApprove` returns false so the
 *         launcher flags the rocket as **faulted** in step 1.
 */
contract ERC20BadApprove is ERC20Mock {
    constructor() ERC20Mock("BadApprove", "BAD", 9) {}

    function approve(address, uint64) public pure override returns (bool) {
        return false; // sabotage
    }
}

/**
 * @title  UTDMockBadApprove
 * @notice Factory that mints an `ERC20BadApprove`.  Used to trigger the
 *         “approval failure ⇒ Faulted” branch in `deployLiquidity`.
 */
contract UTDMockBadApprove is IUTD {
    function create(
        string calldata n,
        string calldata s,
        uint64 sup,
        uint8 dec,
        uint32,
        address root,
        string calldata
    ) external override returns (address) {
        ERC20BadApprove tok = new ERC20BadApprove();
        if (sup > 0) tok.mint(root, sup);
        return address(tok);
    }
}

/*════════════════════════════════════════════════════════════════*\
│                 deployLiquidity() behaviour tests                │
\*════════════════════════════════════════════════════════════════*/
contract RocketLauncherDeployLiquidityTest is RocketLauncherTestBase {
    /*──────────────────────── helpers ───────────────────────*/

    /// creator deposits `stake` and time‑warps past deploy‑time
    function _prepLaunch(
        uint64 stake
    ) internal returns (uint256 id, RocketConfig memory cfg) {
        cfg = _defaultConfig();
        vm.prank(AL);
        id = launcher.createRocket(cfg);

        // deposit stake so launch can proceed
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
    }

    /*──────────────────────── positive path ─────────────────*/

    function testDeployLiquidity_Succeeds() external {
        (uint256 id, RocketConfig memory cfg) = _prepLaunch(100 * ONE);

        vm.recordLogs();
        launcher.deployLiquidity(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        /* event & state sanity */
        bytes32 sig = keccak256("LiquidityDeployed(uint256,uint256)");
        bool seen;
        uint256 lpState = launcher.totalLP(id);

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                assertEq(uint256(logs[i].topics[1]), id, "id mismatch");
                uint128 lpEvent = abi.decode(logs[i].data, (uint128));
                assertEq(lpEvent, lpState, "event/state LP mismatch");
                seen = true;
                break;
            }
        }
        assertTrue(seen, "LiquidityDeployed not emitted");
        assertFalse(launcher.isFaulted(id), "should NOT be faulted");
    }

    /*──────────────────────── revert paths ─────────────────*/

    function testDeployLiquidity_Revert_LaunchTooEarly() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchTooEarly.selector,
                id,
                uint64(block.timestamp),
                cfg.liquidityDeployTime
            )
        );
        launcher.deployLiquidity(id);
    }

    function testDeployLiquidity_Revert_ZeroLiquidity_NoDeposit() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.warp(cfg.liquidityDeployTime + 1);
        vm.expectRevert(ZeroLiquidity.selector);
        launcher.deployLiquidity(id);
    }

    function testDeployLiquidity_Revert_AlreadyLaunched() external {
        (uint256 id, RocketConfig memory cfg) = _prepLaunch(50 * ONE);
        launcher.deployLiquidity(id); // first launch

        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector, id));
        launcher.deployLiquidity(id); // second call
    }

    /*───────────────── approval failure ⇒ Faulted ─────────────*/

    function testDeployLiquidity_FaultsOnApproveFailure() external {
        /* fresh launcher whose UTD mints ERC20BadApprove */
        UTDMockBadApprove bad = new UTDMockBadApprove();
        RocketLauncher badL = new RocketLauncher(dex, bad, "x");

        /* rocket & deposit */
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = badL.createRocket(cfg);

        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(badL), 10 * ONE);
        badL.deposit(id, 10 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);

        vm.expectEmit(true /*check topic1*/, false, false, false);
        emit RocketLauncher.Faulted(id);
        badL.deployLiquidity(id);

        assertTrue(badL.isFaulted(id), "fault flag");
        assertEq(badL.totalLP(id), 0, "no LP recorded");
    }

    /*────────────── DEX init‑revert ⇒ Faulted (new) ───────────*/

    function testDeployLiquidity_FaultsOnDEXRevert() external {
        /* tiny legs so rootK ≤ MINIMUM_LIQUIDITY ⇒ DEXMock revert */
        RocketConfig memory cfg = _defaultConfig();
        cfg.utilityTokenParams.supply64 = 1; // utility 1 wei

        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // deposit exactly 1 wei invite
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        invit.mint(AL, 1);
        vm.prank(AL);
        invit.approve(address(launcher), 1);
        vm.prank(AL);
        launcher.deposit(id, 1);

        vm.warp(cfg.liquidityDeployTime + 1);

        vm.expectEmit(true, false, false, false);
        emit RocketLauncher.Faulted(id);
        launcher.deployLiquidity(id);

        assertTrue(launcher.isFaulted(id), "fault flag not set");
        assertEq(launcher.totalLP(id), 0, "LP should remain zero");

        /* subsequent attempts revert with RocketFaulted */
        vm.expectRevert(abi.encodeWithSelector(RocketFaulted.selector, id));
        launcher.deployLiquidity(id);
    }
}
