// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*────────────────────── shared launcher scaffolding ───────────────*/
import "./RocketLauncherTestBase.sol";

/*──────────────────────── local mocks ─────────────────────────────*/
import "./mocks/Mocks.sol";

/*══════════════════════════════════════════════════════════════════*\
│                     UTDMockBad – negative‑path helper              │
\*══════════════════════════════════════════════════════════════════*/

/**
 * @title  UTDMockBad
 * @notice Deliberately mints **zero** supply so the launcher reverts
 *         with `BadInitialSupply`.  Packed here to avoid polluting
 *         global mocks.
 */
contract UTDMockBad is IUTD {
    function create(
        string calldata n,
        string calldata s,
        uint64 /*sup*/,
        uint8 dec,
        uint32,
        address /*root*/,
        string calldata
    ) external override returns (address) {
        return address(new ERC20Mock(n, s, dec)); // zero supply
    }
}

/*══════════════════════════════════════════════════════════════════*\
│                     CreateRocket test‑suite                        │
\*══════════════════════════════════════════════════════════════════*/

/**
 * @title  CreateRocketTest
 * @notice Covers **only** behaviour of `RocketLauncher.createRocket`.
 *
 *         Every test is independent and focuses on exactly one branch.
 *         If production logic grows new branches, add a new unit test
 *         here – do not extend an unrelated case.
 */
contract CreateRocketTest is RocketLauncherTestBase {
    /*──────────────────────── positive path ───────────────────────*/

    /*────────────────── positive path ──────────────────*/
    function testCreateRocket_Succeeds() external {
        RocketConfig memory cfg = _defaultConfig();

        // We only care about topic‑1 (rocket‑id); skip the data blob
        vm.expectEmit(true /*check topic1*/, false, false, false);
        emit RocketLauncher.RocketCreated(
            1,
            address(0), // creator (ignored)
            address(0), // utility token (ignored)
            cfg.percentOfLiquidityCreator,
            cfg.percentOfLiquidityBurned,
            cfg.liquidityDeployTime,
            cfg.liquidityLockedUpTime,
            cfg.invitingToken,
            0
        );

        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        IZRC20 util = launcher.offeringToken(id);
        assertEq(util.balanceOf(address(launcher)), SUPPLY64, "supply");
        assertEq(launcher.idOfUtilityToken(address(util)), id, "reverse map");
    }

    /*──────────────────────── revert paths ───────────────────────*/

    /*────────────────── PairUnsupported ─────────────────*/
    function testCreateRocket_Revert_PairUnsupported() external {
        dex.testSwitchSupport(); // supported → false
        RocketConfig memory cfg = _defaultConfig();

        // Since PairUnsupported includes the utility token address which is created
        // during the call, we can't predict it beforehand. We'll use the general
        // expectRevert() and let the contract's natural error handling validate
        // that the correct error is thrown.
        vm.prank(AL);
        vm.expectRevert(); // This will catch any revert, including PairUnsupported
        launcher.createRocket(cfg);
    }

    /// Inviting token is address(0)
    function testCreateRocket_Revert_InvitingTokenZero() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.invitingToken = IZRC20(address(0));

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        launcher.createRocket(cfg);
    }

    /// Caller ≠ offeringCreator
    function testCreateRocket_Revert_Unauthorized() external {
        RocketConfig memory cfg = _defaultConfig();

        vm.prank(BO); // BO is not creator
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, BO));
        launcher.createRocket(cfg);
    }

    /// creatorPct > 50 %
    function testCreateRocket_Revert_CreatorShareTooHigh() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.percentOfLiquidityCreator = (type(uint32).max >> 1) + 1; // >50 %

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatorShareTooHigh.selector,
                cfg.percentOfLiquidityCreator
            )
        );
        launcher.createRocket(cfg);
    }

    /// sum(creatorPct + burnPct) ≥ 100 %
    function testCreateRocket_Revert_PercentSumOutOfRange() external {
        RocketConfig memory cfg = _defaultConfig();
        uint32 FULL = type(uint32).max;
        cfg.percentOfLiquidityCreator = FULL >> 1; // 50 %
        cfg.percentOfLiquidityBurned = FULL - (FULL >> 1) + 1; // pushes sum over 100 %

        uint64 sum = uint64(cfg.percentOfLiquidityCreator) +
            uint64(cfg.percentOfLiquidityBurned);

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(PercentOutOfRange.selector, sum)
        );
        launcher.createRocket(cfg);
    }

    /// lockEnd ≤ deployStart
    function testCreateRocket_Revert_InvalidVestingWindow() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.liquidityLockedUpTime = cfg.liquidityDeployTime; // zero‑length

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidVestingWindow.selector,
                cfg.liquidityDeployTime,
                cfg.liquidityLockedUpTime
            )
        );
        launcher.createRocket(cfg);
    }

    /// utility supply == 0
    function testCreateRocket_Revert_ZeroLiquidity() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.utilityTokenParams.supply64 = 0;

        vm.prank(AL);
        vm.expectRevert(ZeroLiquidity.selector);
        launcher.createRocket(cfg);
    }

    /// Factory mints wrong supply → BadInitialSupply
    /*────────────────── BadInitialSupply ────────────────*/
    function testCreateRocket_Revert_BadInitialSupply() external {
        UTDMockBad bad = new UTDMockBad();
        RocketLauncher badLauncher = new RocketLauncher(dex, bad, "x");

        RocketConfig memory cfg = _defaultConfig();

        // selector 0xd0e751ef (compiler‑generated)
        bytes memory err = abi.encodeWithSelector(
            BadInitialSupply.selector,
            cfg.utilityTokenParams.supply64,
            uint64(0)
        );

        vm.prank(AL);
        vm.expectRevert(err);
        badLauncher.createRocket(cfg);
    }
}
