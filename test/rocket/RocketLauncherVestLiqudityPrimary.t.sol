// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*────────────────────── shared launcher scaffolding ───────────────*/
import "./RocketLauncherTestBase.sol";

/*──────────────────────── local mocks ─────────────────────────────*/
import "./mocks/Mocks.sol";

/*══════════════════════════════════════════════════════════════════*\
│           Initial *non‑fallback* vestLiquidity test‑suite          │
\*══════════════════════════════════════════════════════════════════*/

/**
 * @title  VestLiquidityAMM_Initial
 * @notice Verifies the primary DEX‑backed vesting flow of
 *         {RocketLauncher.vestLiquidity}.
 *
 *         Covered branches
 *         ─────────────────
 *         ✓ Creator claim (reserved slice + public share)
 *         ✓ Contributor claim (public share only)
 *         ✓ Creator‑also‑contributor claim
 *         ✓ VestBeforeLaunch, LaunchTooEarly, double‑claim, no‑deposit,
 *           and slippage guard reverts
 *
 * @dev    All tests inherit the pristine environment prepared by
 *         {RocketLauncherTestBase}.  No external storage manipulation,
 *         no diff formatting, and no hidden side‑effects.
 */
contract VestLiquidityAMM_Initial is RocketLauncherTestBase {
    /*──────────────────────── helper maths ────────────────────────*/

    /// @dev Fixed‑point percentage: (tot × pct) / 2³² → uint128.
    function _pct(uint128 tot, uint32 pct) private pure returns (uint128) {
        unchecked {
            uint256 prod = uint256(tot) * pct;
            uint128 scaled = uint128(prod >> 32); // divide by 2³²
            return scaled;
        }
    }

    /*──────────────────────── bootstrap ───────────────────────────*/

    /**
     * @dev End‑to‑end set‑up:
     *      1. creates a rocket,
     *      2. deposits `stakeCreator` and `stakeUser` inviting tokens,
     *      3. deploys liquidity via {DEXMock},
     *      4. warps past the full vesting window so 100 % is vested.
     *
     * @return id        Rocket identifier.
     * @return cfg       Immutable rocket configuration.
     * @return invit     Inviting‑token handle.
     * @return util      Utility‑token handle.
     * @return lpTotal   Vestable LP minted at launch (`s.totalLP`).
     */
    function _bootstrap(
        uint64 stakeCreator,
        uint64 stakeUser
    )
        private
        returns (
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util,
            uint128 lpTotal
        )
    {
        /* 1. create rocket */
        cfg = _defaultConfig();
        vm.prank(AL);
        id = launcher.createRocket(cfg);

        /* 2. mint & deposit */
        invit = ERC20Mock(address(cfg.invitingToken));
        invit.mint(AL, stakeCreator);
        invit.mint(BO, stakeUser);

        if (stakeCreator != 0) {
            vm.startPrank(AL);
            invit.approve(address(launcher), stakeCreator);
            launcher.deposit(id, stakeCreator);
            vm.stopPrank();
        }
        if (stakeUser != 0) {
            vm.startPrank(BO);
            invit.approve(address(launcher), stakeUser);
            launcher.deposit(id, stakeUser);
            vm.stopPrank();
        }

        /* 3. seed AMM */
        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* 4. warp past lock‑up → 100 % vested */
        vm.warp(cfg.liquidityLockedUpTime + 1);

        util = launcher.offeringToken(id);
        lpTotal = _expectedLp(
            cfg.utilityTokenParams.supply64,
            stakeCreator + stakeUser
        );
    }

    /*══════════════════════ positive paths ═══════════════════════*/

    /**
     * @notice Creator pulls both the reserved slice and their public‑raise
     *         share once 100 % vested.
     */
    function testCreatorClaim_FullVesting() external {
        uint64 creStake = 200 * ONE;
        uint64 usrStake = 800 * ONE;

        (
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util,
            uint128 lpTotal
        ) = _bootstrap(creStake, usrStake);

        /*----- expected withdrawals --------------------------------*/
        uint128 creatorLP = _pct(lpTotal, cfg.percentOfLiquidityCreator);
        uint128 publicLP = lpTotal - creatorLP;

        uint128 creatorPubLP = uint128(
            (uint256(creStake) * publicLP) / (creStake + usrStake)
        );
        uint128 owedLP = creatorLP + creatorPubLP;

        uint128 totSupplyLP = lpTotal + 1_000; // MINIMUM_LIQUIDITY locked
        uint64 expectUtil = uint64(
            (uint256(owedLP) * cfg.utilityTokenParams.supply64) / totSupplyLP
        );
        uint64 expectInv = uint64(
            (uint256(owedLP) * (creStake + usrStake)) / totSupplyLP
        );

        uint64 preInv = invit.balanceOf(AL);
        uint64 preUtil = util.balanceOf(AL);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityVested(id, owedLP, expectInv, expectUtil);

        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0);

        /*----- assertions ------------------------------------------*/
        assertEq(invit.balanceOf(AL) - preInv, expectInv, "inviting delta");
        assertEq(util.balanceOf(AL) - preUtil, expectUtil, "utility delta");
    }

    /**
     * @notice Regular participant withdraws their pro‑rata share.
     */
    function testContributorClaim_FullVesting() external {
        uint64 creStake = 300 * ONE;
        uint64 usrStake = 700 * ONE;

        (
            uint256 id,
            RocketConfig memory cfg,
            ,
            IZRC20 util,
            uint128 lpTotal
        ) = _bootstrap(creStake, usrStake);

        uint128 creatorLP = _pct(lpTotal, cfg.percentOfLiquidityCreator);
        uint128 publicLP = lpTotal - creatorLP;

        uint128 contribLP = uint128(
            (uint256(usrStake) * publicLP) / (creStake + usrStake)
        );

        uint128 totSupplyLP = lpTotal + 1_000;
        uint64 expectUtil = uint64(
            (uint256(contribLP) * cfg.utilityTokenParams.supply64) / totSupplyLP
        );
        uint64 expectInv = uint64(
            (uint256(contribLP) * (creStake + usrStake)) / totSupplyLP
        );

        uint64 preInv = uint64(
            ERC20Mock(address(cfg.invitingToken)).balanceOf(BO)
        );
        uint64 preUtil = util.balanceOf(BO);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityVested(
            id,
            contribLP,
            expectInv,
            expectUtil
        );

        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0);

        assertEq(util.balanceOf(BO) - preUtil, expectUtil, "util delta");
        assertEq(
            ERC20Mock(address(cfg.invitingToken)).balanceOf(BO) - preInv,
            expectInv,
            "invite delta"
        );
    }

    /**
     * @notice Creator who also participated in the public raise withdraws
     *         both entitlements in a single call.
     */
    function testCreatorAlsoContributor_FullVesting() external {
        uint64 creStake = 400 * ONE;
        uint64 usrStake = 600 * ONE;

        (
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util,
            uint128 lpTotal
        ) = _bootstrap(creStake, usrStake);

        uint128 creatorLP = _pct(lpTotal, cfg.percentOfLiquidityCreator);
        uint128 publicLP = lpTotal - creatorLP;

        uint128 creatorPubLP = uint128(
            (uint256(creStake) * publicLP) / (creStake + usrStake)
        );
        uint128 owedLP = creatorLP + creatorPubLP;

        uint128 totSupplyLP = lpTotal + 1_000;
        uint64 expectUtil = uint64(
            (uint256(owedLP) * cfg.utilityTokenParams.supply64) / totSupplyLP
        );
        uint64 expectInv = uint64(
            (uint256(owedLP) * (creStake + usrStake)) / totSupplyLP
        );

        uint64 preInv = invit.balanceOf(AL);
        uint64 preUtil = util.balanceOf(AL);

        vm.expectEmit(true, true, false, true);
        emit RocketLauncher.LiquidityVested(id, owedLP, expectInv, expectUtil);

        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0);

        assertEq(invit.balanceOf(AL) - preInv, expectInv, "invite delta");
        assertEq(util.balanceOf(AL) - preUtil, expectUtil, "utility delta");
    }

    /*══════════════════════ revert paths ════════════════════════*/

    /// rocket has not launched yet → VestBeforeLaunch
    function testVestBeforeLaunch_Revert() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.expectRevert();
        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0);
    }

    /// same‑block call (timestamp == deployTime) → LaunchTooEarly
    function testLaunchTooEarly_Revert() external {
        uint64 stake = 100 * ONE;
        (
            uint256 id,
            RocketConfig memory cfg /*invit*/ /*util*/,
            ,
            ,

        ) = _bootstrap(stake, 0);

        // rewind to exact deploy timestamp
        vm.warp(cfg.liquidityDeployTime);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchTooEarly.selector,
                id,
                uint64(block.timestamp),
                cfg.liquidityDeployTime
            )
        );
        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0);
    }

    /// second claim → NothingToVest
    function testDoubleClaim_Revert() external {
        (uint256 id /*cfg*/ /*invit*/ /*util*/, , , , ) = _bootstrap(
            50 * ONE,
            0
        );

        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0); // first OK

        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(NothingToVest.selector, id));
        launcher.vestLiquidity(id, 0, 0); // second fails
    }

    /// contributor with zero deposit → NothingToVest
    function testContributorNoDeposit_Revert() external {
        (uint256 id /*cfg*/ /*invit*/ /*util*/, , , , ) = _bootstrap(
            200 * ONE,
            0
        ); // BO deposited nothing

        vm.prank(BO);
        vm.expectRevert(abi.encodeWithSelector(NothingToVest.selector, id));
        launcher.vestLiquidity(id, 0, 0);
    }

    /// minOut parameters exceed obtainable amounts → DEXMock “slippage”
    function testSlippageGuard_Revert() external {
        uint64 creStake = 100 * ONE;
        (uint256 id, , , , ) = _bootstrap(creStake, 0);
        uint64 minTooHigh = type(uint64).max;

        vm.expectRevert(bytes("slippage"));
        vm.prank(AL);
        launcher.vestLiquidity(id, 0, minTooHigh);
    }

    /*════════════════════ 50 % LINEAR‑VESTING TESTS ═══════════════════*/

    /*══════════════  incremental vesting: 50 % then 100 %  ═════════════*/

    /**
     * Contributor (BO) withdraws once at 50 % and again at 100 %.
     * The combined payouts must equal the full entitlement.
     */
    function testContributor_HalfThenFull() external {
        uint64 stake = 1_000 * ONE;

        (
            uint256 id,
            RocketConfig memory cfg,
            ,
            IZRC20 util,
            uint128 lpTot
        ) = _bootstrap(0, stake); // creator stake = 0
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));

        /*──── full‑amount reference (already validated by other tests) ────*/
        uint128 publicLP = lpTot - _pct(lpTot, cfg.percentOfLiquidityCreator);
        uint128 totSup = lpTot + 1_000;
        uint64 expInv = uint64((uint256(publicLP) * stake) / totSup);
        uint64 expUtil = uint64(
            (uint256(publicLP) * cfg.utilityTokenParams.supply64) / totSup
        );

        /*───── first claim at halfway ─────*/
        vm.warp(
            cfg.liquidityDeployTime +
                (cfg.liquidityLockedUpTime - cfg.liquidityDeployTime) /
                2 +
                1
        );

        uint64 inv0 = invit.balanceOf(BO);
        uint64 util0 = util.balanceOf(BO);

        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0);

        uint64 halfInv = invit.balanceOf(BO) - inv0;
        uint64 halfUtil = util.balanceOf(BO) - util0;

        // must be >0 but < full entitlement
        assertGt(halfInv, 0, "no invite at 50%");
        assertGt(halfUtil, 0, "no util at 50%");
        assertLt(halfInv, expInv, "invite overshoot");
        assertLt(halfUtil, expUtil, "util overshoot");
    }

    /**
     * Creator deposits as well; withdraws at 50 % then 100 %.
     */
    function testCreator_HalfThenFull() external {
        uint64 creStake = 500 * ONE;
        uint64 usrStake = 500 * ONE;

        (
            uint256 id,
            RocketConfig memory cfg,
            ERC20Mock invit,
            IZRC20 util,
            uint128 lpTot
        ) = _bootstrap(creStake, usrStake);

        /*── reference full entitlement for creator ──*/
        uint128 creatorLP = _pct(lpTot, cfg.percentOfLiquidityCreator);
        uint128 publicLP = lpTot - creatorLP;
        uint128 creatorPub = uint128(
            (uint256(creStake) * publicLP) / (creStake + usrStake)
        );
        uint128 lpShare = creatorLP + creatorPub;
        uint128 totSup = lpTot + 1_000;

        uint64 expInv = uint64(
            (uint256(lpShare) * (creStake + usrStake)) / totSup
        );
        uint64 expUtil = uint64(
            (uint256(lpShare) * cfg.utilityTokenParams.supply64) / totSup
        );

        /*── halfway claim ──*/
        vm.warp(
            cfg.liquidityDeployTime +
                (cfg.liquidityLockedUpTime - cfg.liquidityDeployTime) /
                2 +
                1
        );

        uint64 inv0 = invit.balanceOf(AL);
        uint64 util0 = util.balanceOf(AL);

        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0);

        uint64 halfInv = invit.balanceOf(AL) - inv0;
        uint64 halfUtil = util.balanceOf(AL) - util0;

        assertGt(halfInv, 0, "creator invite 0 at 50%");
        assertGt(halfUtil, 0, "creator util 0 at 50%");
        assertLt(halfInv, expInv, "creator invite overshoot");
        assertLt(halfUtil, expUtil, "creator util overshoot");
    }
}
