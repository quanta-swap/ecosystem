// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*───────── Forge stdlib ─────────*/
import "lib/forge-std/src/Test.sol";

/*──────── shared scaffolding ─────*/
import "./RocketLauncherTestBase.sol";
import "./mocks/Mocks.sol";

/**
 * @title  RocketLauncherVestFallbackTest
 * @notice Exercises the fallback branch of `vestLiquidity`
 *         (no‑DEX or faulted‑rocket).
 */
contract RocketLauncherVestFallbackTest is RocketLauncherTestBase {
    /*────────────────── helpers ──────────────────*/

    /// Stand‑alone launcher **without a DEX**, deposits stakes, warps time.
    function _bootstrapNoDex(
        uint64 stakeCreator,
        uint64 stakeUser
    )
        internal
        returns (
            RocketLauncher ndL,
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util
        )
    {
        /* 1. launcher with dex == 0x0 */
        ndL = new RocketLauncher(IDEX(address(0)), new UTDMock());

        /* 2. rocket config & creation */
        cfg = _defaultConfig();
        vm.prank(AL);
        id = ndL.createRocket(cfg);

        /* 3. mint invite tokens */
        invit = ERC20Mock(address(cfg.invitingToken));
        invit.mint(AL, stakeCreator);
        invit.mint(BO, stakeUser);

        /* 4. creator deposit (if any) */
        if (stakeCreator > 0) {
            vm.startPrank(AL);
            invit.approve(address(ndL), stakeCreator);
            ndL.deposit(id, stakeCreator);
            vm.stopPrank();
        }

        /* 5. contributor deposit (if any) */
        if (stakeUser > 0) {
            vm.startPrank(BO);
            invit.approve(address(ndL), stakeUser);
            ndL.deposit(id, stakeUser);
            vm.stopPrank();
        }

        /* 6. move past deploy‑time so vesting can occur */
        vm.warp(cfg.liquidityDeployTime + 1);

        util = ndL.offeringToken(id);
    }

    /// copy of contract’s internal helper
    function _pct64(uint64 amt, uint32 pct) internal pure returns (uint64) {
        return uint64((uint256(amt) * pct) >> 32);
    }

    /*────────────────── happy paths ─────────────────*/

    function testCreatorClaim_NoDex() external {
        uint64 creStake = 200 * ONE;
        uint64 usrStake = 800 * ONE;

        (
            RocketLauncher ndL,
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util
        ) = _bootstrapNoDex(creStake, usrStake);

        /*───── expected payouts ────*/
        uint64 full = cfg.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(full, cfg.percentOfLiquidityCreator);
        uint64 publicSupply = full - creatorSlice;
        uint64 raise = creStake + usrStake;
        uint64 creatorPub = uint64((uint256(creStake) * publicSupply) / raise);
        uint64 expectUtil = creatorSlice + creatorPub;

        /*───── observe pre‑balances ────*/
        uint64 preInv = invit.balanceOf(AL);
        uint64 preUtil = util.balanceOf(AL);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityClaimed(id, AL, raise, expectUtil);

        vm.prank(AL);
        ndL.vestLiquidity(id, 0, 0);

        /*───── check deltas ────*/
        assertEq(
            invit.balanceOf(AL) - preInv,
            raise,
            "creator invite delta mismatch"
        );
        assertEq(
            util.balanceOf(AL) - preUtil,
            expectUtil,
            "creator util delta mismatch"
        );
    }

    function testContributorClaim_NoDex() external {
        uint64 creStake = 300 * ONE;
        uint64 usrStake = 700 * ONE;

        (
            RocketLauncher ndL,
            uint256 id,
            RocketConfig memory cfg,
            ,
            IZRC20 util
        ) = _bootstrapNoDex(creStake, usrStake);

        uint64 full = cfg.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(full, cfg.percentOfLiquidityCreator);
        uint64 expectedUtil = uint64(
            (uint256(usrStake) * (full - creatorSlice)) / (creStake + usrStake)
        );

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityClaimed(id, BO, 0, expectedUtil);

        vm.prank(BO);
        ndL.vestLiquidity(id, 0, 0);

        assertEq(
            util.balanceOf(BO),
            expectedUtil,
            "contributor util allocation wrong"
        );
        assertEq(ndL.deposited(id, BO), 0, "_deposited not cleared");
    }

    /*────────────────── revert paths ─────────────────*/

    function testDoubleClaim_Revert() external {
        (
            RocketLauncher ndL,
            uint256 id /*invit*/ /*util*/,
            ,
            ,

        ) = _bootstrapNoDex(100 * ONE, 0); // only creator stake

        vm.prank(AL);
        ndL.vestLiquidity(id, 0, 0); // first claim OK

        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector, id));
        ndL.vestLiquidity(id, 0, 0); // second should fail
    }

    function testContributorNoDeposit_Revert() external {
        (
            RocketLauncher ndL,
            uint256 id /*invit*/ /*util*/,
            ,
            ,

        ) = _bootstrapNoDex(500 * ONE, 0); // BO deposited nothing

        vm.prank(BO);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector, id));
        ndL.vestLiquidity(id, 0, 0);
    }

    /*──────── fallback after faulted rocket ────────*/

    function testFallbackAfterFault() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.utilityTokenParams.supply64 = 1; // force AMM sqrt < MIN_LIQUIDITY

        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* BO deposits 1 invite */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        invit.mint(BO, 1);
        vm.startPrank(BO);
        invit.approve(address(launcher), 1);
        launcher.deposit(id, 1);
        vm.stopPrank();

        /* launch → fault */
        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);
        assertTrue(launcher.isFaulted(id), "rocket not faulted");

        uint64 balBefore = launcher.offeringToken(id).balanceOf(BO);

        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0);

        assertGt(
            launcher.offeringToken(id).balanceOf(BO),
            balBefore,
            "util not received in fault fallback"
        );
    }

    /// Creator has a reserved slice *and* also contributes to the public raise
    function testCreatorContributorClaim_NoDex() external {
        uint64 creStake = 400 * ONE; // creator’s deposit
        uint64 usrStake = 600 * ONE; // contributor deposit

        (
            RocketLauncher ndL,
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util
        ) = _bootstrapNoDex(creStake, usrStake);

        /*───── expected payouts ────*/
        uint64 full = cfg.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(full, cfg.percentOfLiquidityCreator);
        uint64 publicSlice = full - creatorSlice;
        uint64 creatorPub = uint64(
            (uint256(creStake) * publicSlice) / (creStake + usrStake)
        );
        uint64 expectInvite = creStake + usrStake; // entire raise
        uint64 expectUtil = creatorSlice + creatorPub; // private + public

        /*───── observe pre‑balances ────*/
        uint64 preInv = invit.balanceOf(AL);
        uint64 preUtil = util.balanceOf(AL);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityClaimed(id, AL, expectInvite, expectUtil);

        vm.prank(AL);
        ndL.vestLiquidity(id, 0, 0);

        /*───── check deltas ────*/
        assertEq(
            invit.balanceOf(AL) - preInv,
            expectInvite,
            "invite delta mismatch"
        );
        assertEq(
            util.balanceOf(AL) - preUtil,
            expectUtil,
            "utility delta mismatch"
        );
    }
}
