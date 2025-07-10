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

/**
 * @title  DEXMock
 * @notice Pretends to be a DEX router.  LP tokens are represented as an
 *         incrementing uint128 counter; no real swaps or pools exist.
 */
contract DEXMock is IDEX {
    uint128 public lpCounter;

    function initializeLiquidity(
        address,
        address,
        uint256,
        uint256,
        address
    ) external override returns (uint256) {
        return ++lpCounter; // trivial LP id
    }

    function withdrawLiquidity(
        address,
        address,
        uint128,
        address
    ) external pure override returns (uint64, uint64) {
        return (0, 0); // no-op
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

    /*───────────────────── placeholder test ────────────────────*/
    /// @notice Placeholder – replace with real tests.
    function test__PLACEHOLDER() external {
        // Intentionally left blank.
    }
}
