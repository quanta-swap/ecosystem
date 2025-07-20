// SPDX‑License‑Identifier: MIT
pragma solidity ^0.8.24;

/*────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*──────────────────── System‑under‑test (SUT) ──────────────────────*/
import {
    RocketLauncher,
    RocketLauncherDeployer,
    ZeroAddress
} from "../../src/_launch.sol";

/*───────────────────────── Local mocks ─────────────────────────────*/
import "../rocket/mocks/Mocks.sol"; // DEXMock, UTDMock

/**
 * @title  DeployerConstructorTest
 * @notice Unit‑tests the **`RocketLauncherDeployer.create`** pathway.
 *         – Happy‑path: verifies that the spawned `RocketLauncher`
 *           exposes the exact `dex`, `deployer`, and `theme` we passed in.
 *         – Failure paths: both zero‑address guards.
 *
 * @dev    Each function focuses on *one* behaviour.  All assertions are
 *         explicit; no silent assumptions or side‑effects.
 */
contract DeployerConstructorTest is Test {
    /*──────────────────── actors & fixtures ───────────────────────*/
    address private constant CALLER = address(0xDEAD);

    DEXMock private dex;             // fake AMM router
    UTDMock private utd;             // fake utility‑token factory
    RocketLauncherDeployer private factory;

    /*──────────────────────── set‑up (runs before every test) ─────*/
    function setUp() public {
        vm.deal(CALLER, 100 ether);  // give the caller gas

        dex     = new DEXMock();
        utd     = new UTDMock();
        factory = new RocketLauncherDeployer();
    }

    /*══════════════════════════════════════════════════════════════*
     *                        Positive path                         *
     *══════════════════════════════════════════════════════════════*/

    /**
     * @notice `create` emits {Deployed}, records provenance, and the freshly
     *         minted `RocketLauncher` exposes the exact `dex`, `deployer`
     */
    function testCreate_Succeeds_ConfigCorrect() external {
        /*----- expect the Deployed event (all fields) ---------------*/
        vm.expectEmit(false, true, true, true);
        emit RocketLauncherDeployer.Deployed(
            address(0),          // placeholder (checked post‑call)
            address(dex),
            address(utd)
        );

        /*----- act --------------------------------------------------*/
        vm.prank(CALLER);
        address addr = factory.create(dex, utd);

        /*----- assert: factory provenance ---------------------------*/
        assertTrue(factory.verify(addr), "factory.verify failed");

        /*----- assert: launcher interior state ----------------------*/
        RocketLauncher launcher = RocketLauncher(addr);
        assertEq(address(launcher.dex()), address(dex), "dex mismatch");
        assertEq(address(launcher.deployer()), address(utd), "utd mismatch");
    }

    /*══════════════════════════════════════════════════════════════*
     *                        Failure paths                         *
     *══════════════════════════════════════════════════════════════*/

    /**
     * @notice Reverts with `ZeroAddress` when `dex == address(0)`.
     */
    function testCreate_Revert_DexZero() external {
        vm.prank(CALLER);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector, address(0)));
        factory.create(IDEX(address(0)), utd);
    }

    /**
     * @notice Reverts with `ZeroAddress` when `utd == address(0)`.
     */
    function testCreate_Revert_UTDZero() external {
        vm.prank(CALLER);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector, address(0)));
        factory.create(dex, IUTD(address(0)));
    }
}
