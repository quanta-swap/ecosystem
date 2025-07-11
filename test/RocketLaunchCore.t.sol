// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────── Forge stdlib ───────────────────────────*/
import "lib/forge-std/src/Test.sol";

/*────────────────────── System-under-test (SUT) ──────────────────────*/
import "../src/_launch.sol"; // adjust path if needed

/*══════════════════════════════════════════════════════════════════════*\
│                       Local lightweight mock-contracts                │
\*══════════════════════════════════════════════════════════════════════*/

/**
 * @title  ERC20Mock (64-bit balances)
 * @notice Basic minting ERC-20 that satisfies the `IZRC20` interface used by
 *         RocketLauncher.  It stores balances in `uint64` to match IZRC-20.
 */
contract ERC20Mock is IZRC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint64 private _tot;

    mapping(address => uint64) private _bal;
    mapping(address => mapping(address => uint64)) private _allow;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    /*────────── external mint helper (tests only) ─────────*/
    function mint(address to, uint64 amt) external {
        _bal[to] += amt;
        _tot += amt;
        emit IZRC20.Transfer(address(0), to, amt);
    }

    /*────────── IZRC20 view ─────────*/
    function name() external view returns (string memory) {
        return _name;
    }
    function symbol() external view returns (string memory) {
        return _symbol;
    }
    function decimals() external view returns (uint8) {
        return _decimals;
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

    /*────────── IZRC20 actions ─────────*/
    function approve(address s, uint64 v) external returns (bool) {
        _allow[msg.sender][s] = v;
        emit IZRC20.Approval(msg.sender, s, v);
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
        require(cur >= v, "allowance");
        if (cur != type(uint64).max) _allow[f][msg.sender] = cur - v;
        _xfer(f, t, v);
        return true;
    }

    /*────────── internal helper ─────────*/
    function _xfer(address f, address t, uint64 v) private {
        require(_bal[f] >= v, "bal");
        _bal[f] -= v;
        _bal[t] += v;
        emit IZRC20.Transfer(f, t, v);
    }
}

/** DEX that lets the test choose the next (utilOut, inviteOut) pair and
 *  returns a *large* LP supply (1 000) so we can vest twice.            */
contract DEXMockOverflow is IDEX {
    uint128 private constant LP_SUPPLY = 1_000;
    uint64 public nextUtilOut;
    uint64 public nextInviteOut;

    function setNext(uint64 util, uint64 invite) external {
        nextUtilOut = util;
        nextInviteOut = invite;
    }

    function initializeLiquidity(
        address,
        address,
        uint256,
        uint256,
        address
    ) external pure override returns (uint128) {
        return LP_SUPPLY; // totalLP == 1 000
    }

    function withdrawLiquidity(
        address,
        address,
        uint128,
        address,
        uint64,
        uint64
    ) external view override returns (uint64 amountA, uint64 amountB) {
        amountA = nextUtilOut; // utilOut
        amountB = nextInviteOut; // inviteOut
    }
}

/*──────────────────── helper: bad UTD that mints nothing ──────────────────*/
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
        // Deliberately return a fresh token with **zero** supply,
        // so RocketLauncher’s post-factory sanity check fails.
        ERC20Mock tok = new ERC20Mock(n, s, dec);
        return address(tok);
    }
}

/**
 * @title  DEXMock
 * @notice Pretends to be a DEX router.  LP tokens are represented as an
 *         incrementing uint128 counter; no real swaps or pools exist.
 */
/**
 * @title  DEXMock (Uniswap V2 maths)
 * @notice Minimal in-memory simulation of a single-pair AMM.
 *         • `initializeLiquidity` mints LP = √(A·B) − MIN_LIQ.
 *         • `withdrawLiquidity` burns LP and returns tokens pro-rata.
 *         • The contract never *transfers* ERC-20 balances; tests fetch
 *           the returned (utilOut, inviteOut) directly from the call.
 *
 *         Good enough for RocketLauncher unit / fuzz tests without
 *         introducing a full Uniswap deployment.
 */
contract DEXMock is IDEX {
    /*════════════════════════════════════════════════════════════*/
    /*                     storage & constants                    */
    /*════════════════════════════════════════════════════════════*/

    struct Pair {
        uint112 reserveA;
        uint112 reserveB;
        uint128 totalSupply; // LP supply
    }

    /// single-pair state keyed by the hash of the (tokenA, tokenB) tuple
    mapping(bytes32 => Pair) private _pairs;

    uint256 private constant MINIMUM_LIQUIDITY = 1_000; // same as UniV2

    /*════════════════════════════════════════════════════════════*/
    /*                     helper: sqrt(uint256)                  */
    /*════════════════════════════════════════════════════════════*/

    function _sqrt(uint256 y) private pure returns (uint128 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = uint128(y);
        uint128 k = uint128((x + 1) >> 1);
        while (k < z) {
            z = k;
            k = uint128((x / k + k) >> 1);
        }
    }

    /*════════════════════════════════════════════════════════════*/
    /*                       IDEX interface                       */
    /*════════════════════════════════════════════════════════════*/

    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address /*to*/
    ) external override returns (uint128 liquidity) {
        require(amountA > 0 && amountB > 0, "Zero amounts");

        // always store using (tokenA,tokenB) *as passed* – RocketLauncher
        //   keeps them consistent, so we don’t bother with sorting here.
        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        Pair storage p = _pairs[key];
        require(p.totalSupply == 0, "Already initialized");

        uint256 rootK = _sqrt(amountA * amountB);
        require(rootK > MINIMUM_LIQUIDITY, "Insufficient liquidity");

        liquidity = uint128(rootK - MINIMUM_LIQUIDITY);
        p.reserveA = uint112(amountA);
        p.reserveB = uint112(amountB);
        p.totalSupply = liquidity + uint128(MINIMUM_LIQUIDITY); // lock the min
    }

    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint128 lp,
        address /*to*/,
        uint64 minA,
        uint64 minB
    ) external override returns (uint64 amountA, uint64 amountB) {
        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        Pair storage p = _pairs[key];
        require(lp != 0 && lp <= p.totalSupply, "Bad LP");

        // pro-rata share of reserves (standard V2 burn maths)
        amountA = uint64((uint256(lp) * p.reserveA) / p.totalSupply);
        amountB = uint64((uint256(lp) * p.reserveB) / p.totalSupply);

        require(amountA >= minA && amountB >= minB, "Slippage");

        // update reserves and LP supply
        p.reserveA -= uint112(amountA);
        p.reserveB -= uint112(amountB);
        p.totalSupply -= lp;
    }
}

/**
 * @title  UTDMock
 * @notice Tiny utility-token factory that mints a fresh `ERC20Mock` each call.
 */
contract UTDMock is IUTD {
    function create(
        string calldata n,
        string calldata s,
        uint64 sup,
        uint8 dec,
        uint32,
        address root,
        string calldata
    ) external override returns (address) {
        ERC20Mock tok = new ERC20Mock(n, s, dec);
        if (sup > 0) tok.mint(root, uint64(sup));
        return address(tok);
    }
}

/*══════════════════════════════════════════════════════════════════════*\
│                         Test harness (no tests yet)                   │
\*══════════════════════════════════════════════════════════════════════*/

/**
 * @title  RocketLauncherTestHarness
 * @notice Provides common set-up, test accounts, and helper routines.
 *         Concrete test contracts can inherit from this and start writing
 *         `function testXxx() external { ... }` cases.
 *
 * @dev    NO ACTUAL TESTS INCLUDED – this is just scaffolding.
 */
contract RocketLauncherTestHarness is Test {
    /*──────────────────── static actors ───────────────────*/
    address internal constant AL = address(0xA11);
    address internal constant BO = address(0xB0B);
    address internal constant CA = address(0xCa7);

    /*──────────────────── mocks & SUT ─────────────────────*/
    DEXMock internal dex;
    UTDMock internal utd;
    RocketLauncherDeployer internal factory;
    RocketLauncher internal launcher;

    /*──────────────────── constants ───────────────────────*/
    uint64 internal constant ONE = 1e9; // 9-dec “1”
    uint64 internal constant SUPPLY64 = 1_000_000 * ONE;
    uint32 internal constant LOCK_TIME = 1 hours;

    using stdStorage for StdStorage;
    StdStorage private ss;

    /*──────────────────── set-up routine ──────────────────*/
    /**
     * @notice Deploy mocks, factory, and a fresh RocketLauncher with a
     *         hard-coded theme URI.  Prime test addresses with Ether.
     */
    function setUp() public virtual {
        /* prime ETH balances */
        vm.deal(AL, 100 ether);
        vm.deal(BO, 100 ether);
        vm.deal(CA, 100 ether);

        /* deploy mocks */
        dex = new DEXMock();
        utd = new UTDMock();
        factory = new RocketLauncherDeployer();

        /* use factory to spawn launcher so provenance works */
        string memory themeURI = "ipfs://placeholder-theme";
        address launcherAddr = factory.create(dex, utd, themeURI);
        launcher = RocketLauncher(launcherAddr);

        /* Sanity: factory should recognise the launcher */
        assertTrue(factory.verify(launcherAddr), "factory verify failed");
    }

    /*──────────────────────── new math helpers ────────────────────────*/

    /**
     * @dev Returns √(a × b) – MINIMUM_LIQUIDITY, the exact amount of LP that
     *      `DEXMock.initializeLiquidity` now mints.
     */
    function _expectedLp(uint256 a, uint256 b) internal pure returns (uint128) {
        uint256 minLiq = 1_000; // same constant as in DEXMock
        uint256 k = a * b;
        uint256 root = _sqrt(k);
        require(root > minLiq, "insuf liq");
        return uint128(root - minLiq);
    }

    /* Babylonic sqrt for uint256 –   identical to the one inside DEXMock */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = y;
        uint256 k = (x + 1) >> 1;
        while (k < z) {
            z = k;
            k = (x / k + k) >> 1;
        }
    }

    /*──────────────────── helper: build RocketConfig ──────────────────*/
    /**
     * @dev Returns a canonical `RocketConfig` with a freshly-minted inviting
     *      token and standard parameters.  Tests can mutate as needed.
     */
    function _defaultConfig() internal returns (RocketConfig memory cfg) {
        ERC20Mock inviting = new ERC20Mock("Invite", "INV", 9);
        inviting.mint(AL, SUPPLY64);

        UtilityTokenParams memory p = UtilityTokenParams({
            name: "Utility",
            symbol: "UTK",
            supply64: SUPPLY64,
            decimals: 9,
            lockTime: LOCK_TIME,
            root: address(launcher),
            theme: "ipfs://token-theme"
        });

        cfg = RocketConfig({
            offeringCreator: AL,
            invitingToken: inviting,
            utilityTokenParams: p,
            percentOfLiquidityBurned: 0,
            percentOfLiquidityCreator: uint32(type(uint32).max >> 2), // 25 %
            liquidityLockedUpTime: uint64(block.timestamp + 30 days),
            liquidityDeployTime: uint64(block.timestamp + 1 days)
        });
    }

    /*══════════════════════════════════════════════════════════════════*\
    │                       createRocket() tests                         │
    \*══════════════════════════════════════════════════════════════════*/

    /**
     * @notice Happy-path: AL (the declared creator) deploys a rocket.
     *         Verifies event emission, id return, counter increment, and that
     *         the freshly-minted utility token is recognised by the launcher.
     */
    function testCreateRocket_Succeeds() external {
        RocketConfig memory cfg = _defaultConfig(); // canonical cfg
        vm.prank(AL); // AL == creator

        /* Expect the `RocketCreated` event with the correct rocket-ID (1).  
           We ignore the token address in `data`, because we cannot know it
           until after the call returns. */
        vm.expectEmit(true /*topic1:id*/, false, false, false);
        emit RocketLauncher.RocketCreated(1, AL, address(0));

        uint256 id = launcher.createRocket(cfg); // ====> CALL

        /* ───── post-conditions ───── */
        assertEq(id, 1, "return id");
        assertEq(launcher.rocketCount(), 1, "rocketCount");

        // The launcher must recognise the freshly-minted utility token.
        IZRC20 util = launcher.offeringToken(1);
        assertEq(launcher.idOfUtilityToken(address(util)), 1, "reverse lookup");
        assertEq(
            util.balanceOf(address(launcher)),
            SUPPLY64,
            "launcher util bal"
        );
    }

    /**
     * @notice Reverts with ZeroAddress when the inviting token is zero.
     */
    function testCreateRocket_Revert_InvitingTokenZeroAddr() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.invitingToken = IZRC20(address(0)); // break it

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(ZeroAddress.selector, address(0))
        );
        launcher.createRocket(cfg); // ====> REVERT
    }

    /**
     * @notice Reverts with Unauthorized when msg.sender ≠ offeringCreator.
     */
    function testCreateRocket_Revert_UnauthorizedCaller() external {
        RocketConfig memory cfg = _defaultConfig(); // creator = AL

        vm.prank(BO); // BO ≠ creator
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, BO));
        launcher.createRocket(cfg); // ====> REVERT
    }

    /**
     * @notice Reverts with CreatorShareTooHigh when creatorPct > 50 %.
     */
    function testCreateRocket_Revert_CreatorShareTooHigh() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.percentOfLiquidityCreator = (type(uint32).max >> 1) + 1; // >50 %

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreatorShareTooHigh.selector,
                cfg.percentOfLiquidityCreator
            )
        );
        launcher.createRocket(cfg); // ====> REVERT
    }

    /**
     * @notice Reverts with PercentOutOfRange when
     *         burnPct + creatorPct  > 100 %.
     *
     * @dev    We keep `creatorPct` at the maximum *allowed* value (50 %)
     *         so we pass the earlier CreatorShareTooHigh check, then set
     *         `burnPct` large enough that their sum exceeds 2³²-1.
     *
     *         FULL        = 2³²-1  = 4 294 967 295 (100 %)
     *         creatorPct  = FULL >> 1              (50 %)  = 2 147 483 647
     *         burnPct     = FULL − creatorPct + 1  (≈50 % + 1) = 2 147 483 649
     *         sum         = FULL + 1              = 4 294 967 296  → overflow
     */
    function testCreateRocket_Revert_PercentSumOutOfRange() external {
        RocketConfig memory cfg = _defaultConfig();

        uint32 FULL = type(uint32).max;
        uint32 creatorPct = FULL >> 1; // 50 %
        uint32 burnPct = FULL - creatorPct + 1; // push sum over 100 %

        cfg.percentOfLiquidityCreator = creatorPct;
        cfg.percentOfLiquidityBurned = burnPct;

        uint64 sum = uint64(creatorPct) + uint64(burnPct); // expected arg

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(PercentOutOfRange.selector, sum)
        );
        launcher.createRocket(cfg); // ====> REVERT
    }

    /**
     * @notice Reverts with InvalidVestingWindow when lockEnd ≤ deployStart.
     */
    function testCreateRocket_Revert_InvalidVestingWindow() external {
        RocketConfig memory cfg = _defaultConfig();
        // Force an impossible window: end == start
        cfg.liquidityLockedUpTime = cfg.liquidityDeployTime;

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidVestingWindow.selector,
                cfg.liquidityDeployTime,
                cfg.liquidityLockedUpTime
            )
        );
        launcher.createRocket(cfg); // ====> REVERT
    }

    /*══════════════════════════════════════════════════════════════════*\
    │                           deposit() tests                         │
    \*══════════════════════════════════════════════════════════════════*/

    /**
     * @notice Reverts when `amount == 0`.
     */
    function testDeposit_Revert_ZeroDeposit() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.prank(AL);
        vm.expectRevert(ZeroDeposit.selector);
        launcher.deposit(id, 0);
    }

    /**
     * @notice Reverts with UnknownRocket when the ID is unmapped.
     */
    function testDeposit_Revert_UnknownRocket() external {
        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(UnknownRocket.selector, 999));
        launcher.deposit(999, 1);
    }

    /**
     * @notice Reverts with AlreadyLaunched after liquidity deployment.
     */
    function testDeposit_Revert_AlreadyLaunched() external {
        /*──────── set-up ────────*/
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));
        uint64 first = 100 * ONE;

        /* AL approves + deposits so the launch can proceed */
        vm.startPrank(AL);
        inviting.approve(address(launcher), first);
        launcher.deposit(id, first);
        vm.stopPrank();

        /* warp past deploy-time and launch */
        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* BO tries to deposit after launch – must revert */
        inviting.mint(BO, 10 * ONE);
        vm.startPrank(BO);
        inviting.approve(address(launcher), 10 * ONE);
        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector, id));
        launcher.deposit(id, 10 * ONE);
        vm.stopPrank();
    }

    /**
     * @notice Happy-path: AL deposits 50 INV – verifies event emission,
     *         per-user and aggregate tallies, and launcher balance.
     *
     * @dev    Uses vm.recordLogs() + vm.getRecordedLogs() so we can assert
     *         the Deposited event without relying on expectEmit overloads
     *         that may not exist in older Forge builds.
     */
    function testDeposit_Succeeds_Accumulates() external {
        /*────────────────── set-up a fresh rocket ──────────────────*/
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));
        uint64 amt = 50 * ONE;

        /*────────────────── record all logs during deposit ─────────*/
        vm.recordLogs();
        vm.startPrank(AL);
        inviting.approve(address(launcher), amt);
        launcher.deposit(id, amt);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        /*────────────────── locate & check Deposited event ─────────*/
        bytes32 sig = keccak256("Deposited(uint256,address,uint64)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                // topics: [sig, id]; non-indexed fields are in data
                assertEq(uint256(logs[i].topics[1]), id, "rocketId");

                (address fromAddr, uint64 deposited) = abi.decode(
                    logs[i].data,
                    (address, uint64)
                );
                assertEq(fromAddr, AL, "event sender");
                assertEq(deposited, amt, "event amount");
                found = true;
                break;
            }
        }
        require(found, "Deposited event not found");

        /*────────────────── state post-conditions ──────────────────*/
        assertEq(
            inviting.balanceOf(address(launcher)),
            amt,
            "launcher INV balance"
        );
        assertEq(launcher.totalInviteContributed(id), amt, "aggregate tally");
        assertEq(launcher.deposited(id, AL), amt, "per-user tally");
    }

    /**
     * @notice Creator contributes 75 %, another user 25 %; both tallies correct.
     */
    function testDeposit_CreatorCanExceedHalf() external {
        /*──────────────────── launch the rocket ────────────────────*/
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));
        uint64 creatorAmt = 75 * ONE;
        uint64 otherAmt = 25 * ONE;

        /*──────────────────── creator deposit ──────────────────────*/
        vm.startPrank(AL);
        inviting.approve(address(launcher), creatorAmt);
        launcher.deposit(id, creatorAmt);
        vm.stopPrank();

        /*──────────────────── BO deposit ───────────────────────────*/
        inviting.mint(BO, otherAmt);
        vm.startPrank(BO);
        inviting.approve(address(launcher), otherAmt);
        launcher.deposit(id, otherAmt);
        vm.stopPrank();

        /*──────────────────── assertions ───────────────────────────*/
        uint64 total = creatorAmt + otherAmt;
        assertEq(
            launcher.totalInviteContributed(id),
            total,
            "total contributions"
        );
        assertEq(launcher.deposited(id, AL), creatorAmt, "creator tally");
        assertEq(launcher.deposited(id, BO), otherAmt, "other tally");
    }

    /**
     * @notice Creator has the maximum 50 % liquidity credit but may still
     *         contribute more inviting tokens.  After two creator deposits
     *         and a larger public deposit, the creator’s share of total
     *         contributions is < 50 %.
     *
     * Layout:
     *   - creatorPct  = 50 %
     *   - AL deposits 40  INV
     *   - BO deposits 120 INV
     *   - AL deposits 10  INV  (second deposit – must succeed)
     *
     * Totals:
     *   creator = 50  INV
     *   public  = 120 INV
     *   total   = 170 INV
     *   creator share = 29.4 %  (< 50 %)
     */
    function testDeposit_CreatorCredit50_ButStakeUnderHalf() external {
        /*──────── configure a 50 % creator credit ─────────────────────*/
        RocketConfig memory cfg = _defaultConfig();
        cfg.percentOfLiquidityCreator = uint32(type(uint32).max >> 1); // 50 %

        /*──────── create rocket ───────────────────────────────────────*/
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));

        /* amounts (in 9-dec “whole” units) */
        uint64 c1 = 40 * ONE; // first creator deposit
        uint64 p = 120 * ONE; // public deposit (BO)
        uint64 c2 = 10 * ONE; // second creator deposit

        /*──────── first creator deposit ───────────────────────────────*/
        vm.startPrank(AL);
        inviting.approve(address(launcher), c1 + c2);
        launcher.deposit(id, c1);
        vm.stopPrank();

        /*──────── public deposit ──────────────────────────────────────*/
        inviting.mint(BO, p);
        vm.startPrank(BO);
        inviting.approve(address(launcher), p);
        launcher.deposit(id, p);
        vm.stopPrank();

        /*──────── second creator deposit – must succeed ───────────────*/
        vm.startPrank(AL);
        launcher.deposit(id, c2);
        vm.stopPrank();

        /*──────── assertions ──────────────────────────────────────────*/
        uint64 creatorTotal = c1 + c2;
        uint64 total = creatorTotal + p;

        // Per-user and aggregate tallies via public helpers.
        assertEq(
            launcher.deposited(id, AL),
            creatorTotal,
            "creator deposited tally"
        );
        assertEq(launcher.deposited(id, BO), p, "public deposited tally");
        assertEq(launcher.totalInviteContributed(id), total, "aggregate tally");

        // Creator’s share of contributions strictly < 50 %.
        // (2 * creatorTotal) < total  ⇒  creatorTotal / total  < 0.5
        assertLt(uint256(creatorTotal) * 2, uint256(total), "creator < 50 %");
    }

    /*══════════════════════════════════════════════════════════════════*\
│                    deployLiquidity()   tests                       │
\*══════════════════════════════════════════════════════════════════*/

    /*-------------------------------------------------------------*
 |  1. LaunchTooEarly – deploy called before deploy-time gate   |
 *-------------------------------------------------------------*/
    function testDeployLiquidity_Revert_LaunchTooEarly() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // Warp to JUST before deploy-time
        vm.warp(cfg.liquidityDeployTime - 1);

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

    /*-------------------------------------------------------------*
 |  2. ZeroLiquidity – no deposits supplied                    |
 *-------------------------------------------------------------*/
    function testDeployLiquidity_Revert_ZeroLiquidity_NoDeposit() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.warp(cfg.liquidityDeployTime + 1); // past gate, still zero deposits
        vm.expectRevert(ZeroLiquidity.selector);
        launcher.deployLiquidity(id);
    }

    /*-------------------------------------------------------------*
 |  3. ZeroLiquidity – utility-token supply is zero            |
 *-------------------------------------------------------------*/
    function testDeployLiquidity_Revert_ZeroLiquidity_NoSupply() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.utilityTokenParams.supply64 = 0; // break supply

        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // Creator makes a non-zero deposit so only supply==0 path triggers
        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        inviting.approve(address(launcher), 10 * ONE);
        launcher.deposit(id, 10 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        vm.expectRevert(ZeroLiquidity.selector);
        launcher.deployLiquidity(id);
    }

    /*-------------------------------------------------------------*
 |  4. AlreadyLaunched – second call should revert             |
 *-------------------------------------------------------------*/
    function testDeployLiquidity_Revert_AlreadyLaunched() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        // deposit a stake so launch may proceed
        ERC20Mock inviting = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        inviting.approve(address(launcher), 20 * ONE);
        launcher.deposit(id, 20 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id); // first launch

        vm.expectRevert(abi.encodeWithSelector(AlreadyLaunched.selector, id));
        launcher.deployLiquidity(id); // second call
    }

    /**
     * @notice Happy-path: liquidity deployed, LP minted & event fired.
     */
    function testDeployLiquidity_Succeeds() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit 100 INV so launch succeeds */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        uint64 stake = 100 * ONE;
        vm.startPrank(AL);
        invit.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);

        /* record event & call */
        vm.recordLogs();
        launcher.deployLiquidity(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        /* expected LP per Uniswap-math */
        uint128 expLp = _expectedLp(cfg.utilityTokenParams.supply64, stake);

        bytes32 sig = keccak256("LiquidityDeployed(uint256,uint128)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                assertEq(uint256(logs[i].topics[1]), id, "rocketId");
                uint128 lpMinted = abi.decode(logs[i].data, (uint128));
                assertEq(lpMinted, expLp, "LP minted");
                seen = true;
                break;
            }
        }
        require(seen, "LiquidityDeployed missing");

        /* contract state mirrors event */
        assertEq(launcher.totalLP(id), expLp, "stored totalLP");
        assertEq(launcher.poolInvite(id), 0, "poolInvite");
        assertEq(launcher.poolUtility(id), 0, "poolUtility");
    }

    /*══════════════════════════════════════════════════════════════════*\
    │                      vestLiquidity()   tests                      │
    \*══════════════════════════════════════════════════════════════════*/

    /**
     * @notice Revert: vest called before `deployLiquidity`.
     */
    function testVestLiquidity_Revert_BeforeLaunch() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        vm.warp(cfg.liquidityDeployTime + 5);

        // ↳ expect VestBeforeLaunch(id)
        vm.expectRevert(abi.encodeWithSelector(VestBeforeLaunch.selector, id));
        launcher.vestLiquidity(id, 0, 0); // ← new minima args
    }

    /**
     * @notice Revert: vest at timestamp ≤ deployTime (gate not open yet).
     */
    function testVestLiquidity_Revert_LaunchTooEarly() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit to allow launch                                                     */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 10 * ONE);
        launcher.deposit(id, 10 * ONE);
        vm.stopPrank();

        /* launch exactly at deployTime                                                */
        vm.warp(cfg.liquidityDeployTime);
        launcher.deployLiquidity(id);

        /* vest in same block – should revert LaunchTooEarly                           */
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchTooEarly.selector,
                id,
                uint64(block.timestamp),
                cfg.liquidityDeployTime
            )
        );
        launcher.vestLiquidity(id, 0, 0);
    }

    function testVestLiquidity_Revert_NothingToVest() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit & launch */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 20 * ONE);
        launcher.deposit(id, 20 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* pull everything once */
        vm.warp(cfg.liquidityLockedUpTime + 2);
        vm.prank(AL); // ← caller must be AL
        launcher.vestLiquidity(id, 0, 0);

        /* second pull must revert */
        vm.prank(AL);
        vm.expectRevert(abi.encodeWithSelector(NothingToVest.selector, id));
        launcher.vestLiquidity(id, 0, 0);
    }

    function testVestLiquidity_Succeeds_Full() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 30 * ONE);
        launcher.deposit(id, 30 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        vm.warp(cfg.liquidityLockedUpTime + 1);

        vm.prank(AL); // ← impersonate AL
        launcher.vestLiquidity(id, 0, 0);

        assertEq(launcher.lpPulled(id), launcher.totalLP(id), "full pull");
    }

    /*══════════════════════════════════════════════════════════════════*\
    │                         viewer helpers tests                       │
    \*══════════════════════════════════════════════════════════════════*/

    /**
     * @notice Unknown rocket IDs always return zero values.
     */
    function testView_UnknownRocket_ReturnsZero() external view {
        uint256 ghost = 999;
        assertEq(launcher.totalInviteContributed(ghost), 0, "totalInvite");
        assertEq(launcher.totalLP(ghost), 0, "totalLP");
        assertEq(launcher.lpPulled(ghost), 0, "lpPulled");
        assertEq(launcher.poolInvite(ghost), 0, "poolInvite");
        assertEq(launcher.poolUtility(ghost), 0, "poolUtility");
        assertEq(launcher.deposited(ghost, AL), 0, "deposited");
        assertEq(launcher.claimedLP(ghost, AL), 0, "claimedLP");
    }

    /**
     * @notice totalInviteContributed & deposited track per-user / aggregate.
     */
    function testView_TotalInviteContributed_And_Deposited() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inv = ERC20Mock(address(cfg.invitingToken));
        inv.mint(BO, 40 * ONE); // BO needs tokens

        vm.startPrank(AL);
        inv.approve(address(launcher), 60 * ONE);
        launcher.deposit(id, 60 * ONE); // creator 60
        vm.stopPrank();

        vm.startPrank(BO);
        inv.approve(address(launcher), 40 * ONE);
        launcher.deposit(id, 40 * ONE); // public 40
        vm.stopPrank();

        assertEq(launcher.totalInviteContributed(id), 100 * ONE, "aggregate");
        assertEq(launcher.deposited(id, AL), 60 * ONE, "creator");
        assertEq(launcher.deposited(id, BO), 40 * ONE, "public");
    }

    /**
     * @notice totalLP is zero pre-launch then equals expected LP after launch.
     */
    function testView_TotalLP_BeforeAfterLaunch() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit so launch can happen */
        ERC20Mock inv = ERC20Mock(address(cfg.invitingToken));
        uint64 stake = 10 * ONE;
        vm.startPrank(AL);
        inv.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        assertEq(launcher.totalLP(id), 0, "pre-launch totalLP");

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        uint128 expLp = _expectedLp(cfg.utilityTokenParams.supply64, stake);
        assertEq(launcher.totalLP(id), expLp, "post-launch totalLP");
    }

    /*══════════════════════════════════════════════════════════════════*\
    │                       view helpers   tests                        │
    \*══════════════════════════════════════════════════════════════════*/

    function testView_LpPulled_AfterFullVest() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit & launch */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 15 * ONE);
        launcher.deposit(id, 15 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        vm.warp(cfg.liquidityLockedUpTime + 1);
        vm.prank(AL); // ← AL vests
        launcher.vestLiquidity(id, 0, 0);

        assertEq(
            launcher.lpPulled(id),
            launcher.totalLP(id),
            "lpPulled == totalLP after full vest"
        );
    }

    /**
     * @notice Mid-window vesting pulls only the vested fraction and updates
     *         `lpPulled` accordingly.
     *
     *         Assumes DEXMock returns exactly one LP token; therefore half-window
     *         still yields the entire 1 LP after integer truncation, mirroring
     *         realistic small-supply behaviour.
     */
    function testView_LpPulled_AfterHalfVest() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit & launch */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 12 * ONE);
        launcher.deposit(id, 12 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* halfway through vesting window */
        uint64 mid = (cfg.liquidityDeployTime + cfg.liquidityLockedUpTime) >> 1;
        vm.warp(mid);

        vm.prank(AL); // ← AL vests
        launcher.vestLiquidity(id, 0, 0);

        assertGt(launcher.lpPulled(id), 0, "some vested");
        assertLt(launcher.lpPulled(id), launcher.totalLP(id), "not all vested");
    }

    /**
     * @notice idOfUtilityToken & verify map token ⇄ rocketID.
     */
    function testView_IdOfUtilityToken_And_Verify() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        IZRC20 util = launcher.offeringToken(id);

        assertEq(launcher.idOfUtilityToken(address(util)), id, "id lookup");
        assertTrue(launcher.verify(address(util)), "verify true");

        // random token – should be false / 0
        ERC20Mock bogus = new ERC20Mock("Bogus", "BOG", 9);
        assertEq(launcher.idOfUtilityToken(address(bogus)), 0, "unknown id");
        assertFalse(launcher.verify(address(bogus)), "verify false");
    }

    /**
     * @notice With the caller-centric vesting path the launcher never
     *         warehouses tokens, so `poolInvite` and `poolUtility`
     *         stay zero before and after vesting.
     */
    function testView_Pools_ZeroWithMockDex() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        /* deposit & launch */
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), 12 * ONE);
        launcher.deposit(id, 12 * ONE);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);
        launcher.deployLiquidity(id);

        /* vest everything */
        vm.warp(cfg.liquidityLockedUpTime + 1);
        vm.prank(AL); // ← AL vests
        launcher.vestLiquidity(id, 0, 0);

        assertEq(launcher.poolInvite(id), 0, "invite pool stays zero");
        assertEq(launcher.poolUtility(id), 0, "utility pool stays zero");
    }

    /*-------------------------------------------------------------*
    |  hit line 263 – factory did not mint full supply            |
    *-------------------------------------------------------------*/
    function testCreateRocket_Revert_FactoryDidNotMint() external {
        /* fresh launcher with the “bad” factory */
        UTDMockBad bad = new UTDMockBad();
        RocketLauncher badL = new RocketLauncher(
            IDEX(address(dex)),
            IUTD(address(bad)),
            "x"
        );

        RocketConfig memory cfg = _defaultConfig();
        cfg.utilityTokenParams.supply64 = SUPPLY64; // non-zero

        vm.prank(AL);
        vm.expectRevert(
            abi.encodeWithSelector(Unauthorized.selector, address(bad))
        );
        badL.createRocket(cfg);
    }

    /*-------------------------------------------------------------*
    | 1. per-user SumOverflow (line 292)                          |
    *-------------------------------------------------------------*/
    function testDeposit_Revert_SumOverflow_PerUser() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inv = ERC20Mock(address(cfg.invitingToken));

        /* seed mapping so stdstore can locate the slot */
        inv.mint(AL, 2);
        vm.startPrank(AL);
        inv.approve(address(launcher), 1);
        launcher.deposit(id, 1); // deposited[id][AL] == 1
        vm.stopPrank();

        /* overwrite deposited[id][AL] := 2⁶⁴-1 */
        uint256 slot = ss
            .target(address(launcher))
            .sig("deposited(uint256,address)")
            .with_key(id)
            .with_key(AL)
            .find();
        vm.store(
            address(launcher),
            bytes32(slot),
            bytes32(uint256(type(uint64).max))
        );

        /* a +1 deposit must now overflow and revert with SumOverflow */
        inv.mint(AL, 1);
        vm.startPrank(AL);
        inv.approve(address(launcher), 1);
        uint256 expected = uint256(type(uint64).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SumOverflow.selector, expected));
        launcher.deposit(id, 1);
        vm.stopPrank();
    }

    /*-------------------------------------------------------------*
    | 2. aggregate SumOverflow (line 300)                         |
    *-------------------------------------------------------------*/
    function testDeposit_Revert_SumOverflow_Total() external {
        RocketConfig memory cfg = _defaultConfig();
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        ERC20Mock inv = ERC20Mock(address(cfg.invitingToken));

        /* seed struct for slot discovery */
        inv.mint(AL, 1);
        vm.startPrank(AL);
        inv.approve(address(launcher), 1);
        launcher.deposit(id, 1); // totalInviteContributed == 1
        vm.stopPrank();

        /* force totalInviteContributed[id] := 2⁶⁴-1 */
        uint256 slot = ss
            .target(address(launcher))
            .sig("totalInviteContributed(uint256)")
            .with_key(id)
            .find();
        vm.store(
            address(launcher),
            bytes32(slot),
            bytes32(uint256(type(uint64).max))
        );

        /* BO’s 1-token deposit should now overflow aggregate tally */
        inv.mint(BO, 1);
        vm.startPrank(BO);
        inv.approve(address(launcher), 1);
        uint256 expected = uint256(type(uint64).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SumOverflow.selector, expected));
        launcher.deposit(id, 1);
        vm.stopPrank();
    }

    /**
     * @notice 100 % burn path leaves a residual LP slice (creator share = 0).
     */
    function testDeployLiquidity_WithBurnPath() external {
        RocketConfig memory cfg = _defaultConfig();
        cfg.percentOfLiquidityCreator = 0;
        cfg.percentOfLiquidityBurned = type(uint32).max; // 100 %
        vm.prank(AL);
        uint256 id = launcher.createRocket(cfg);

        uint64 stake = 5 * ONE;
        ERC20Mock invit = ERC20Mock(address(cfg.invitingToken));
        vm.startPrank(AL);
        invit.approve(address(launcher), stake);
        launcher.deposit(id, stake);
        vm.stopPrank();

        vm.warp(cfg.liquidityDeployTime + 1);

        vm.recordLogs();
        launcher.deployLiquidity(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("LiquidityDeployed(uint256,uint128)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                assertEq(uint256(logs[i].topics[1]), id, "rocketId");
                uint128 lpLeft = abi.decode(logs[i].data, (uint128));
                uint128 stateLp = launcher.totalLP(id);
                /* event and state must agree – allow ±1 rounding wiggle */
                assertApproxEqAbs(lpLeft, stateLp, 1, "LP after burn");
                seen = true;
                break;
            }
        }
        require(seen, "LiquidityDeployed not seen");
    }

    /*-------------------------------------------------------------*
    |  hit lines 564-565 – simple theme() getter                  |
    *-------------------------------------------------------------*/
    function testTheme_ReturnsConstructorURI() external view {
        assertEq(launcher.theme(), "ipfs://placeholder-theme");
    }

    function testDeployerTheme_ReturnsYouTubeURI() public {
        RocketLauncherDeployer dep = new RocketLauncherDeployer();

        string memory expected = "https://www.youtube.com/watch?v=uGcsIdGOuZY";

        assertEq(dep.theme(), expected);
    }
}
