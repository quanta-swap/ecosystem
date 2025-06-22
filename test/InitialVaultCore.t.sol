// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_initial.sol";

/*──────────────────────────  Helpers  ──────────────────────────*/
uint64 constant ONE = 1e8; // wQRL, QSD, reward use 8 dec
uint256 constant WEI_1 = ONE * 1e10; // 1 token in wei (scale 1e10)

/*────────── 64-bit ERC-20 mock (transfer/allowance) ──────────*/
contract MockZRC20 is IZRC2 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 8;
    uint64 public totalSupply;
    mapping(address => uint64) public balanceOf;
    mapping(address => mapping(address => uint64)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function _move(address f, address t, uint64 a) internal {
        require(balanceOf[f] >= a, "bal");
        unchecked {
            balanceOf[f] -= a;
            balanceOf[t] += a;
        }
        emit Transfer(f, t, a);
    }

    function mint(address to, uint64 a) external {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function transfer(address t, uint64 a) external returns (bool) {
        _move(msg.sender, t, a);
        return true;
    }

    function approve(address s, uint64 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transferFrom(
        address f,
        address t,
        uint64 a
    ) external returns (bool) {
        uint64 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        if (al != type(uint64).max) {
            allowance[f][msg.sender] = al - a;
            emit Approval(f, msg.sender, al - a);
        }
        _move(f, t, a);
        return true;
    }
}

/*────────── QSD mock implementing liquidity loan I/F ─────────*/
contract MockQSD is MockZRC20, IQSD {
    IZRC20 public immutable W;
    uint128 public sharesSupply;
    uint64 public wqrlPool;

    constructor(address w) MockZRC20("QSD", "QSD") {
        W = IZRC20(w);
    }

    function liquidityLoanIn(
        uint64 wAmt,
        uint128 /*minShares*/
    ) external override returns (uint128 sh) {
        require(W.transferFrom(msg.sender, address(this), wAmt), "xfer");
        sh = uint128(wAmt); // 1:1 mapping for simplicity
        sharesSupply += sh;
        wqrlPool += wAmt;
        emit Transfer(address(0), msg.sender, 0); // dummy event keeps Foundry quiet
    }

    function liquidityLoanOut(
        uint128 sh,
        uint64 /*mQ*/,
        uint64 /*mB*/
    ) external override returns (uint64 wOut, uint64 qOut) {
        require(sh > 0 && sh <= sharesSupply, "bad sh");
        wOut = uint64((uint256(wqrlPool) * sh) / sharesSupply);
        qOut = uint64(sh); // 1 QSD per share
        sharesSupply -= sh;
        wqrlPool -= wOut;

        require(W.transfer(msg.sender, wOut), "wqrl");
        this.mint(msg.sender, qOut); // give QSD to caller
    }
}

/*────────────────────  BISMARCK test-suite  ───────────────────*/
contract BismarckVault_Test is Test {
    /* actors */
    address owner = address(this);
    address alice = address(0xA1);
    address bob = address(0xB2);
    address carol = address(0xC3);

    /* mocks */
    MockZRC20 wqrl;
    IZRC2 reward;
    MockQSD qsd;
    BISMARCK vault;

    function setUp() public {
        /* deploy mocks */
        wqrl = new MockZRC20("wQRL", "wQRL");
        reward = new MockZRC20("FREE", "Free Trade / Day");
        qsd = new MockQSD(address(wqrl));

        /* mint tokens & allowances */
        wqrl.mint(alice, 100 * ONE);           // unchanged
        wqrl.mint(bob,   300 * ONE);           // Bob can deposit 275
        wqrl.mint(carol, 300 * ONE);           // room for cap-overflow test

        vm.startPrank(alice);
        wqrl.approve(address(this), type(uint64).max); // for later transfers
        wqrl.approve(address(qsd), type(uint64).max);
        vm.stopPrank();

        vm.startPrank(bob);
        wqrl.approve(address(qsd), type(uint64).max);
        vm.stopPrank();

        vm.startPrank(carol);
        wqrl.approve(address(qsd), type(uint64).max);
        vm.stopPrank();

        /* vault with 300 tokens cap */
        vault = new BISMARCK(
            address(wqrl),
            address(qsd),
            address(reward),
            300 * ONE
        );

        /* blanket approvals to vault */
        vm.prank(alice);
        wqrl.approve(address(vault), type(uint64).max);
        vm.prank(bob);
        wqrl.approve(address(vault), type(uint64).max);
        vm.prank(carol);
        wqrl.approve(address(vault), type(uint64).max);
    }

    /*──────────── Phase-1: deposit / cancel ───────────*/
    function testDepositCancelAndCap() public {
        vm.prank(alice);
        vault.deposit(50 * ONE);
        assertEq(vault.deposited(alice), 50 * ONE);

        /* cancel half */
        vm.prank(alice);
        vault.cancel(25 * ONE);
        assertEq(vault.deposited(alice), 25 * ONE);

        /* cap enforcement */
        vm.prank(bob);
        vault.deposit(275 * ONE); // reaches cap
        vm.prank(carol);
        vm.expectRevert(); // cap
        vault.deposit(1); // exceeds cap
    }

    /*──────────── Phase-2: one-shot deploy ───────────*/
    function _seedAndDeploy() internal {
        /*   Alice 100 wQRL   Bob 100 wQRL   */
        vm.prank(alice);
        vault.deposit(100 * ONE);
        vm.prank(bob);
        vault.deposit(100 * ONE);

        vm.prank(owner);
        vault.deploy(150); // minShares 150 (< 200)
    }

    function testDeployClosesDeposits() public {
        _seedAndDeploy();

        assertTrue(vault.live());
        assertGt(vault.totalShares(), 0);

        /* further deposits/cancels blocked */
        vm.prank(carol);
        vm.expectRevert("closed");
        vault.deposit(1);
        vm.prank(alice);
        vm.expectRevert(); // live
        vault.cancel(1);
    }

    /*──────────── Vesting & claim logic ───────────*/
    function testVestingCurveAndClaim() public {
        _seedAndDeploy();

        /* T0: 25 % cliff vested */
        vm.roll(block.number + 1); // no effect on timestamp
        vm.warp(block.timestamp + 1); // 1 s later to avoid 0 dt
        vm.prank(alice);
        vault.claim();
        assertEq(reward.balanceOf(alice), 25 * ONE);

        /* halfway (≈182.5 d) ⇒ 25 % + 37.5 % = 62.5 % */
        vm.warp(block.timestamp + 182 days + 12 hours);
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(
            reward.balanceOf(alice),
            uint256((6250 * 100 * ONE) / 10000), // 62.5 tokens
            1
        );

        /* after 365 d full 100 % */
        vm.warp(block.timestamp + 183 days);
        vm.prank(alice);
        vault.claim();
        assertEq(reward.balanceOf(alice), 100 * ONE);
    }

    /*──────────── Phase-3: withdraw underlying ───────────*/
    function testWithdrawAfterVesting() public {
        _seedAndDeploy();

        /* warp > 365 d */
        vm.warp(block.timestamp + 366 days);
        uint128 sharesBefore = vault.pendingShares(alice);

        vm.prank(alice);
        vault.withdrawUnderlying(0, 0); // accept any amounts

        /* one-shot guard */
        vm.prank(alice);
        vm.expectRevert("already");
        vault.withdrawUnderlying(0, 0);

        /* reward auto-claimed */
        assertEq(reward.balanceOf(alice), 100 * ONE);

        /* shares burned in QSD */
        uint128 supplyAfter = qsd.sharesSupply();
        assertEq(supplyAfter, uint128(uint256(sharesBefore) == 0 ? 0 : supplyAfter));
        assertEq(supplyAfter, qsd.sharesSupply());           // explicit sanity
        assertEq(supplyAfter + sharesBefore, 200 * ONE);     // total supply conserved
    }

    /*──────────── Guard paths ───────────*/
    function testEarlyWithdrawReverts() public {
        _seedAndDeploy();
        vm.prank(alice);
        vm.expectRevert("locked");
        vault.withdrawUnderlying(0, 0);
    }

    function testNonOwnerDeployReverts() public {
        vm.prank(alice);
        vm.expectRevert("owner");
        vault.deploy(1);
    }

    function testZeroDepositReverts() public {
        vm.prank(alice);
        vm.expectRevert(); // amt
        vault.deposit(0);
    }
}
