// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/***********************************************************************************************
 * VestLiquidity_NoDex.t.sol                                                                   *
 * ------------------------------------------------------------------------------------------- *
 * Unit‑tests for the *fallback* branch of {RocketLauncher.vestLiquidity}: the execution path   *
 * taken when **no DEX is configured** (`address(dex) == 0`).  This suite validates every      *
 * meaningful branch, side‑effect, and revert condition – with granular, line‑level comments    *
 * explaining each assumption and invariant so future auditors (human *or* AI) understand the   *
 * exact intent.                                                                                *
 *                                                                                             *
 * Covered scenarios                                                                            *
 * ──────────────────────────────────────────────────────────────────────────────────────────── *
 *   1. Launch‑gate enforcement – call before `liquidityDeployTime` → string revert "not launched".
 *   2. Creator happy‑path – first claim transfers *all* inviting tokens plus the creator’s      *
 *      fixed‑point utility slice; second call reverts `NothingToClaim`.
 *   3. Contributor claim – pro‑rata utility token distribution; mapping zeroed; follow‑up call  *
 *      reverts `NothingToClaim`.
 *                                                                                             *
 * NOTE: We instantiate a **fresh** RocketLauncher with `dex == address(0)` so that execution    *
 *       naturally falls into the no‑DEX branch without any additional mocking.                 *
 ***********************************************************************************************/

import "lib/forge-std/src/Test.sol";
import {UTDMock} from "./RocketLaunchCore.t.sol";
import "../src/_launch.sol"; // ← path to RocketLauncher + structs/interfaces

/*─────────────────────────────────────────────────────────────────────────────*
│                         Local 64‑bit ERC‑20 mock                             │
*──────────────────────────────────────────────────────────────────────────────*/

/**
 * @title  ERC20Mock64_ND
 * @notice Minimal IZRC‑20‑compatible token with 64‑bit balances and allowance.
 *         Duplicated here under a *new* name to avoid the symbol‑collision
 *         with the ERC20Mock defined in the core harness.
 */
contract ERC20Mock64_ND is IZRC20 {
    /* token metadata */
    string private _name;
    string private _symbol;
    uint8 private _dec;
    uint64 private _tot;

    /* storage */
    mapping(address => uint64) private _bal;
    mapping(address => mapping(address => uint64)) private _allow;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _dec = d;
    }

    /*──────────── mint (tests only) ───────────*/
    function mint(address to, uint64 amt) external {
        _bal[to] += amt;
        _tot += amt;
        emit Transfer(address(0), to, amt);
    }

    /*──────────── IZRC20 views ────────────────*/
    function name() external view returns (string memory) {
        return _name;
    }
    function symbol() external view returns (string memory) {
        return _symbol;
    }
    function decimals() external view returns (uint8) {
        return _dec;
    }
    function totalSupply() external view returns (uint64) {
        return _tot;
    }
    function balanceOf(address a) external view returns (uint64) {
        return _bal[a];
    }
    function allowance(address o, address s) external view returns (uint64) {
        return _allow[o][s];
    }

    /*──────────── IZRC20 actions ──────────────*/
    function approve(address s, uint64 v) external returns (bool) {
        _allow[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint64 v) external returns (bool) {
        _xfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(
        address f,
        address t,
        uint64 v
    ) external returns (bool) {
        uint64 cur = _allow[f][msg.sender];
        require(cur >= v, "allow");
        if (cur != type(uint64).max) _allow[f][msg.sender] = cur - v;
        _xfer(f, t, v);
        return true;
    }

    /* internal helper */
    function _xfer(address f, address t, uint64 v) private {
        require(_bal[f] >= v, "bal");
        _bal[f] -= v;
        _bal[t] += v;
        emit Transfer(f, t, v);
    }

    /* unused batch functions – stubbed */
    function transferBatch(
        address[] calldata,
        uint64[] calldata
    ) external pure override returns (bool) {
        return false;
    }
    function transferFromBatch(
        address,
        address[] calldata,
        uint64[] calldata
    ) external pure override returns (bool) {
        return false;
    }
}

/*─────────────────────────────────────────────────────────────────────────────*
│                           Test contract                                     │
*──────────────────────────────────────────────────────────────────────────────*/

contract VestLiquidity_NoDex_Test is Test {
    /* test actors */
    address internal constant AL = address(0xA11); // creator
    address internal constant BO = address(0xB0B); // contributor

    /* scalar constants */
    uint64 internal constant ONE = 1e9; // 9‑dec "1"
    uint64 internal constant SUPPLY64 = 1_000_000 * ONE; // utility total supply
    uint32 internal constant LOCKTIME = 1 hours;

    /* system under test */
    RocketLauncher internal launcher;
    UTDMock internal utd;

    /*────────────── set‑up ──────────────*/
    /**
     * @notice Deploys a fresh RocketLauncher with *no* DEX, primes ETH balances.
     */
    function setUp() public {
        vm.deal(AL, 100 ether);
        vm.deal(BO, 100 ether);

        utd = new UTDMock(); // simple factory that mints supply to root owner
        launcher = new RocketLauncher(
            IDEX(address(0)),
            IUTD(address(utd)),
            "ipfs://no-dex-theme"
        );
    }

    /*────────── helper: canonical RocketConfig ─────────*/
    function _defaultConfig()
        internal
        returns (RocketConfig memory cfg, ERC20Mock64_ND inviting)
    {
        inviting = new ERC20Mock64_ND("Invite", "INV", 9);
        inviting.mint(AL, SUPPLY64); // seed creator with plenty of tokens

        UtilityTokenParams memory p = UtilityTokenParams({
            name: "Utility",
            symbol: "UTK",
            supply64: SUPPLY64,
            decimals: 9,
            lockTime: LOCKTIME,
            theme: "ipfs://utk-theme"
        });

        cfg = RocketConfig({
            offeringCreator: AL,
            invitingToken: inviting,
            utilityTokenParams: p,
            percentOfLiquidityBurned: 0,
            percentOfLiquidityCreator: uint32(type(uint32).max >> 2), // 25 %
            liquidityLockedUpTime: uint64(block.timestamp + 30 days),
            liquidityDeployTime: uint64(block.timestamp + 1 days)
        });
    }

    /*────────── math helper (copy of library function) ─────────*/
    function _pct64(uint64 amt, uint32 pct) internal pure returns (uint64) {
        return uint64((uint256(amt) * pct) >> 32);
    }

    /*════════════════════════════════════════════════════════════*
     * 1. Launch‑gate enforcement                                 *
     *════════════════════════════════════════════════════════════*/

    /**
     * @dev Calling vestLiquidity before `liquidityDeployTime` must revert with
     *      the string "not launched" (identical to production code path).
     */
    function testVestLiquidity_NoDex_GateNotOpen() external {
        (RocketConfig memory cfg, ) = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // Warp *just* before deploy‑time gate.
        vm.warp(cfg.liquidityDeployTime - 1);

        vm.expectRevert(bytes("not launched"));
        launcher.vestLiquidity(id, 0, 0);
    }

    /*════════════════════════════════════════════════════════════*
     * 2. Creator first‑claim happy‑path + second‑claim revert    *
     *════════════════════════════════════════════════════════════*/

    /**
     * @notice Creator withdraws entire inviting‑token raise plus reserved
     *         utility slice.  After the call:
     *           • Creator has the full raise (INV) and slice (UTK).
     *           • Launcher’s internal pools are zero (it doesn’t warehouse
     *             balances until contributors start claiming).
     *           • `creatorUtilityClaimed` equals the slice amount.
     */
    function testVestLiquidity_NoDex_CreatorFirstClaim() external {
        (RocketConfig memory cfg, ERC20Mock64_ND invit) = _defaultConfig();

        // ─── rocket creation ───
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);
        IZRC20 util = launcher.offeringToken(id);

        // ─── deposits ───
        uint64 creatorStake = 80 * ONE;
        uint64 contribStake = 120 * ONE;

        vm.startPrank(AL);
        invit.approve(address(launcher), creatorStake);
        launcher.deposit(id, creatorStake);
        vm.stopPrank();

        invit.mint(BO, contribStake);
        vm.startPrank(BO);
        invit.approve(address(launcher), contribStake);
        launcher.deposit(id, contribStake);
        vm.stopPrank();

        // ─── creator claim ───
        vm.warp(cfg.liquidityDeployTime + 1);
        uint64 preInv = invit.balanceOf(AL);
        uint64 preUtil = util.balanceOf(AL);

        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0);

        // ─── assertions ───
        uint64 fullSupply = cfg.utilityTokenParams.supply64;
        uint64 creatorSlice = _pct64(fullSupply, cfg.percentOfLiquidityCreator);
        uint64 totalRaise = creatorStake + contribStake;

        assertEq(
            invit.balanceOf(AL) - preInv,
            totalRaise,
            "inviting raise returned"
        );
        assertEq(
            util.balanceOf(AL) - preUtil,
            creatorSlice,
            "creator utility slice"
        );

        // Launcher no longer tracks pools until contributors claim
        assertEq(launcher.poolInvite(id), 0, "poolInvite zero");
        assertEq(launcher.poolUtility(id), 0, "poolUtility zero");
    }

    /**
     * @dev A *second* creator call must revert `NothingToClaim` once everything
     *      has already been pulled.
     */
    function testVestLiquidity_NoDex_CreatorSecondClaimReverts() external {
        // reuse previous helper
        (RocketConfig memory cfg, ERC20Mock64_ND invit) = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // Deposit some invite tokens so raise ≠ 0
        uint64 stake = 50 * ONE;
        vm.startPrank(AL);
        invit.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        vm.prank(AL);
        launcher.vestLiquidity(id, 0, 0); // first pull – succeeds

        // second call – expect revert
        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector, id));
        launcher.vestLiquidity(id, 0, 0);
    }

    /*════════════════════════════════════════════════════════════*
     * 3. Contributor path – claim + double‑claim guard           *
     *════════════════════════════════════════════════════════════*/

    /**
     * @notice Contributor pulls their pro‑rata utility share.
     */
    function testVestLiquidity_NoDex_ContributorClaim() external {
        (RocketConfig memory cfg, ERC20Mock64_ND invit) = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);
        IZRC20 util = launcher.offeringToken(id);

        // Stakes: creator 40 INV, contributor 60 INV
        uint64 cStake = 40 * ONE;
        uint64 pStake = 60 * ONE;

        // Creator deposit
        vm.startPrank(AL);
        invit.approve(address(launcher), cStake);
        launcher.deposit(id, cStake);
        vm.stopPrank();

        // Contributor deposit
        invit.mint(BO, pStake);
        vm.startPrank(BO);
        invit.approve(address(launcher), pStake);
        launcher.deposit(id, pStake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 2);

        // Pre‑balance snapshot
        uint64 preUtil = util.balanceOf(BO);

        // Contributor claims
        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0);

        /* expected utility payout */
        uint64 creatorSlice = _pct64(
            cfg.utilityTokenParams.supply64,
            cfg.percentOfLiquidityCreator
        );
        uint64 publicSupply = cfg.utilityTokenParams.supply64 - creatorSlice;
        uint64 expected = uint64(
            (uint256(pStake) * publicSupply) / (cStake + pStake)
        );

        assertEq(util.balanceOf(BO) - preUtil, expected, "pro-rata util share");
        assertEq(launcher.deposited(id, BO), 0, "mapping zeroed after claim");
    }

    /**
     * @dev Second contributor call must revert `NothingToClaim`.
     */
    function testVestLiquidity_NoDex_ContributorSecondClaimReverts() external {
        (RocketConfig memory cfg, ERC20Mock64_ND invit) = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        uint64 stake = 10 * ONE;
        invit.mint(BO, stake);
        vm.startPrank(BO);
        invit.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        vm.prank(BO);
        launcher.vestLiquidity(id, 0, 0); // first pull

        vm.prank(BO);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector, id));
        launcher.vestLiquidity(id, 0, 0); // second pull – revert
    }
}
