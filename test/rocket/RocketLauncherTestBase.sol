// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*────────────────────── System‑Under‑Test ──────────────────────────*/
import {RocketLauncher, RocketLauncherDeployer} from
    "../../src/_launch.sol";

/*══════════════════════════════════════════════════════════════════*\
│                  Lightweight local mock‑contracts                 │
\*══════════════════════════════════════════════════════════════════*/

import "./mocks/Mocks.sol";

/**
 * @title  RocketLauncherTestBase
 * @notice Shared test scaffolding for *all* RocketLauncher test‑suites.
 *
 *         • Deploys a fresh launcher through the factory.
 *         • Exposes canonical constants and helper utilities.
 *         • Meant to be inherited by every per‑function test contract
 *           (CreateRocketTest, DepositTest, DeployLiquidityTest, ...).
 *
 * @dev    **DO NOT put actual test cases in here.**  Keep this contract
 *         strictly as a base‑class so that every concrete test starts
 *         with exactly the same pristine environment.
 */
abstract contract RocketLauncherTestBase is Test {
    /*─────────────────────── actor aliases ───────────────────────*/
    address internal constant AL = address(0xA11); // offering‑creator
    address internal constant BO = address(0xB0B); // generic participant
    address internal constant CA = address(0xCa7); // spare

    /*──────────────────────── modules & SUT ──────────────────────*/
    DEXMock            internal dex;
    UTDMock            internal utd;
    RocketLauncher     internal launcher;
    RocketLauncherDeployer internal factory;

    /*───────────────────────── constants ─────────────────────────*/
    uint64  internal constant ONE      = 1e9;              // 9‑dec “1”
    uint64  internal constant SUPPLY64 = 1_000_000 * ONE;  // 1 M utility
    uint32  internal constant LOCKTIME = 1 hours;

    using stdStorage for StdStorage;
    StdStorage private _ss;

    /*──────────────────────── common setup ───────────────────────*/
    function setUp() public virtual {
        // 1. Fuel test actors with ETH
        vm.deal(AL, 100 ether);
        vm.deal(BO, 100 ether);
        vm.deal(CA, 100 ether);

        // 2. Deploy mocks
        dex     = new DEXMock();
        utd     = new UTDMock();
        factory = new RocketLauncherDeployer();

        // 3. Spawn a fresh launcher through the factory
        address   addr          = factory.create(dex, utd);
        launcher                 = RocketLauncher(addr);

        // 4. Sanity‑check provenance
        assertTrue(factory.verify(addr), "factory failed to vouch launcher");
    }

    /*──────────────────────── helper: √(a×b) ─────────────────────*/
    function _expectedLp(uint256 a, uint256 b)
        internal
        pure
        returns (uint128)
    {
        uint256 MIN_LIQ = 1_000; // same as DEXMock
        uint256 rootK = _sqrt(a * b);
        uint256 lp    = rootK - MIN_LIQ;
        require(rootK > MIN_LIQ, "init liquidity too small");
        return uint128(lp);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z         = y;
        uint256 k = (x + 1) >> 1;
        while (k < z) {
            z = k;
            k = (x / k + k) >> 1;
        }
    }

    /*────────────────── helper: canonical RocketConfig ───────────*/
    function _defaultConfig() internal returns (RocketConfig memory cfg) {
        ERC20Mock inviting = new ERC20Mock("Invite", "INV", 9);
        inviting.mint(AL, SUPPLY64);

        UtilityTokenParams memory p = UtilityTokenParams({
            name:      "Utility",
            symbol:    "UTK",
            supply64:  SUPPLY64,
            decimals:  9,
            extra: abi.encode(LOCKTIME, "ipfs://token-theme")
        });

        cfg = RocketConfig({
            offeringCreator:           AL,
            invitingToken:             inviting,
            utilityTokenParams:        p,
            percentOfLiquidityBurned:  0,
            percentOfLiquidityCreator: uint32(type(uint32).max >> 2), // 25 %
            liquidityLockedUpTime:     uint64(block.timestamp + 30 days),
            liquidityDeployTime:       uint64(block.timestamp +  1 days),
            invitingTokenSweetener: 0,
            liquidityDeploymentData: ""
        });
    }

}
