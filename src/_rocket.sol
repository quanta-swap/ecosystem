// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC20.sol";
// TODO! Fix locatable liquidity
// TODO! Add a more structured approach to view functions

/*─────────────────── minimal ReentrancyGuard ───────────────────*/
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;
    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface IUTD {
    function create(
        string calldata name,
        string calldata symbol,
        uint64 initialSupply,
        uint8 decimals,
        address root,
        bytes calldata extra
    ) external returns (address);
    function verify(address coin) external view returns (bool isDeployed);
}

interface IDEX {
    /**
     * @notice Stateless probe that asks the DEX whether it *could* list
     *         the (`tokenA`, `tokenB`) pair under its current rules
     *         (fee tiers, tick spacing, allow‑lists, oracle settings).
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  Minimal‑surface compatibility check                         │
     * ╰───────────────────────────────────────────────────────────────╯
     * • This call is deliberately read‑only (`view`) and returns a single
     *   boolean.  It exists so that upstream protocols (e.g. RocketLauncher)
     *   can fail fast *without* performing approvals, transfers, or CREATE2
     *   deployments—thereby shrinking inter‑protocol surface area and
     *   eliminating “half‑configured pool” states.
     *
     * • No fee‑tier or pool‑address data is returned: exposing those here
     *   would lock integrators to one AMM design and create aliasing between
     *   “compatibility mode” and “instantiation mode.”  If multiple fee tiers
     *   exist, the factory should encode tier choice deterministically
     *   (e.g. in the CREATE2 salt) so that both parties reach the same
     *   conclusion from just the token pair.
     *
     * • Gas expectations: implementations MUST be side‑effect‑free and
     *   cheap enough to call in a constructor or a simulation run.
     *
     * Return contract:
     * ----------------
     *   • `true`  — the next call to `initializeLiquidity` *may* succeed
     *               (subject to race conditions and supply amounts).
     *   • `false` — the pair is outright unsupported and `initializeLiquidity`
     *               would revert regardless of supplied amounts.
     *
     * @param tokenA  Candidate reserve token A.
     * @param tokenB  Candidate reserve token B.
     *
     * @return supported  Boolean flag indicating provisional support.
     */
    function checkSupportForPair(
        address tokenA,
        address tokenB
    ) external view returns (bool supported);

    /**
     * @notice Boot‑strap a brand‑new pool for the (`tokenA`, `tokenB`) pair,
     *         deposit the two seed amounts, mint LP tokens to `to`, and return
     *         both the deterministic pool address **and** the amount of LP
     *         minted.
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  One‑shot initialisation — design philosophy                 │
     * ╰───────────────────────────────────────────────────────────────╯
     * • All first‑time pool logic (pair creation, reserve deposits,
     *   minting, invariant sync) is collapsed into this single call.
     *   That eliminates multi‑step approval flows and the half‑configured
     *   “zombie pair” class of bugs.
     *
     * • We now return *two* values:
     *     1. `location`  — the pool address actually used.
     *     2. `liquidity` — LP tokens minted to `to`.
     *
     *   Rationale: some integrators (e.g. analytics, sub‑graphs, optimistic
     *   routers) need an on‑chain confirmation of the pair address that was
     *   ultimately chosen, instead of re‑deriving it off‑chain and hoping the
     *   factory used the same salt/ordering.  Exposing it here removes that
     *   aliasing risk without widening the surface area elsewhere.
     *
     * • `liquidity` remains a `uint256` for forward‑compatibility with AMMs
     *   that may extend Uniswap‑style maths beyond the `uint128` domain.
     *
     * Security invariants (MUST hold):
     * --------------------------------
     * 1.  Function either fully succeeds or reverts – no partial pools.
     * 2.  `location != address(0)` and **owns** the reserves after success.
     * 3.  `liquidity > 0`  iff  both `amountA` and `amountB` are > 0.
     * 4.  Total LP supply increases by exactly `liquidity`.
     * 5.  No leftover token approvals remain on the factory/router.
     *
     * @param tokenA   Reserve token A (`token0` in canonical ordering).
     * @param tokenB   Reserve token B (`token1`).
     * @param amountA  Exact deposit of `tokenA`.
     * @param amountB  Exact deposit of `tokenB`.
     * @param to       Recipient of the LP tokens (e.g. RocketLauncher).
     *
     * @return location   Deterministic pool address actually instantiated.
     * @return liquidity  LP tokens minted to `to`; MUST be greater than zero.
     */
    function initializeLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address to,
        bytes calldata data
    ) external returns (uint64 location, uint256 liquidity);

    /**
     * @notice Burn `liquidity` LP tokens held by the caller and sweep the
     *         underlying pool reserves to `to`.
     *
     * ╭───────────────────────────────────────────────────────────────╮
     * │  ⚠️  Implicit‑approval / single‑router authority model        │
     * ╰───────────────────────────────────────────────────────────────╯
     * • The RocketLauncher never calls ERC‑20 `approve()` on the LP token.
     *   Instead, the LP contract exposes a **factory‑only** pathway that
     *   allows this router (the DEX factory) to transfer and burn LP held
     *   by the caller in a single atomic action.
     *
     * • Rationale: minimising inter‑protocol surface area and avoiding
     *   multiple aliasing usage paths.  A conventional allowance dance
     *   would require every integrating contract to track LP balances,
     *   set allowances, and revoke them—multiplying integration bugs and
     *   audit scope.  By collapsing everything into one privileged entry
     *   point, the LP token has exactly *one* method by which third‑party
     *   contracts can burn liquidity, greatly simplifying reasoning and
     *   static‑analysis.
     *
     * • Security invariants
     *   ───────────────────
     *   1. Only the router/factory address can invoke the LP’s privileged
     *      burn‑and‑transfer function.
     *   2. Outside that function the LP token behaves exactly like a normal
     *      ERC‑20—every transfer still needs a prior allowance.
     *   3. A successful call MUST burn the precise `liquidity` amount from
     *      the caller’s balance and transfer the corresponding reserves
     *      in the same transaction (atomicity).
     *
     * @param tokenA    Reserve‑token A (pair ordering specific).
     * @param tokenB    Reserve‑token B.
     * @param liquidity LP tokens to burn (uint256 to tolerate >2¹²⁸‑1).
     * @param to        Recipient of the withdrawn reserves.
     * @param minA      Minimum acceptable `tokenA` out (slippage guard, 64‑bit).
     * @param minB      Minimum acceptable `tokenB` out (slippage guard, 64‑bit).
     *
     * @return amountA  Actual `tokenA` sent to `to`.
     * @return amountB  Actual `tokenB` sent to `to`.
     */
    function withdrawLiquidity(
        address tokenA,
        address tokenB,
        uint64 location,
        uint256 liquidity,
        address to,
        uint64 minA,
        uint64 minB
    ) external returns (uint64 amountA, uint64 amountB);
}

struct TokenConfig {
    string name;
    string symbol;
    uint64 supply64;
    uint8 decimals;
    bytes extra;
}

struct Account {
    uint256 value;
    uint256 total;
    bool fixated;
    Schedule schedule;
}

struct Schedule {
    uint64 start;
    uint64 length;
}

struct Allocation {
    uint32 creatorOfferings;
    uint32 liquidityBurning;
    uint32 liquidityDeposit;
}

struct Guardrails {
    uint64 minRaise;
    uint64 maxRaise;
}

struct RaiseConfig {
    address creator;
    IDEX dex;
    IUTD utd;
    IZRC20 invitedTok;
    Guardrails guards;
    Allocation allocs;
    TokenConfig token;
    Schedule schedule;
    uint64 strikeTime;
    bytes deployBytes;
}

struct RaiseState {
    IZRC20 offered;
    Account offeredSupply;
    Account invitedSupply;
    Account liquiditySupply;
    bool launched;
    uint64 position;
    bool exploded;
}

struct Raise {
    RaiseConfig config;
    RaiseState state;
}

contract IPO is ReentrancyGuard {
    uint64 private boop;
    mapping(address /* sender */ => mapping(address /* deployed */ => uint64 /* invited */)) contributed;
    mapping(address /* sender */ => mapping(address /* deployed */ => uint64 /* invited */)) liquidated;
    mapping(uint64 => Raise) private raises;
    mapping(address => Account) private reserves;

    mapping(address => address) public underwriters;

    function create(
        RaiseConfig calldata config
    ) external payable nonReentrant returns (uint64 id) {
        require(msg.value >= 1337e18, "Must be elite");
        _validateConfig(config);
        (address deployed, uint64 obtained) = _deployToken(
            config.utd,
            config.token
        );
        if (address(config.dex) != address(0)) {
            require(
                IDEX(config.dex).checkSupportForPair(
                    address(config.invitedTok),
                    deployed
                ),
                "unsupported dex"
            );
        }
        require(reserves[deployed].total == 0, "reserves exist");
        reserves[deployed] = Account({
            value: msg.value,
            total: msg.value,
            fixated: true,
            schedule: Schedule({start: 0, length: 0})
        });
        boop++;
        raises[boop].config = config;
        raises[boop].state = RaiseState({
            offered: IZRC20(deployed),
            offeredSupply: Account({
                value: obtained,
                total: obtained,
                fixated: true,
                schedule: config.schedule
            }),
            invitedSupply: Account({
                value: 0,
                total: 0,
                fixated: false,
                schedule: Schedule({start: 0, length: 0})
            }),
            liquiditySupply: Account({
                value: 0,
                total: 0,
                fixated: false,
                schedule: config.schedule
            }),
            launched: false,
            position: 0,
            exploded: false
        });
        require(
            raises[boop].state.offered.checkSupportsMover(address(this)),
            "unsupported mover"
        );
        underwriters[deployed] = msg.sender;
        return boop;
    }

    function _validateConfig(RaiseConfig calldata config) internal view {
        require(address(config.utd) != address(0), "Zero Address");
        require(address(config.invitedTok) != address(0), "Zero Address");
        require(
            config.guards.minRaise < config.guards.maxRaise,
            "min/max mixup"
        );
        require(10 ** config.token.decimals < type(uint64).max, "unit mishap");
        require(config.token.supply64 != 0, "zero supply");
        require(config.schedule.length >= 1 days, "vest too fast");
        require(
            config.strikeTime > block.timestamp + 1 days,
            "strike too early"
        );
        require(config.schedule.start >= config.strikeTime, "start too early");
        require(
            config.allocs.liquidityBurning + config.allocs.liquidityDeposit ==
                type(uint32).max,
            "missing allocation"
        );
    }

    function _deployToken(
        IUTD utd,
        TokenConfig memory config
    ) internal returns (address deployed, uint64 obtained) {
        deployed = utd.create(
            config.name,
            config.symbol,
            config.supply64,
            config.decimals,
            address(this),
            config.extra
        );
        obtained = uint64(IZRC20(deployed).balanceOf(address(this)));
    }

    function deposit(uint64 id, uint64 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        Raise storage raise = raises[id];
        require(
            raise.state.offered.checkSupportsOwner(msg.sender),
            "unsupported owner"
        );
        require(raise.config.creator != address(0), "raise does not exist");
        require(block.timestamp < raise.config.strikeTime, "deposit too late");
        require(
            raise.state.offered.transferFrom(msg.sender, address(this), amount),
            "fail to deposit"
        );
        require(
            raise.state.invitedSupply.value + amount <=
                raise.config.guards.maxRaise,
            "overfunded"
        );
        contributed[msg.sender][address(raise.state.offered)] += amount;
        raise.state.invitedSupply.value += amount;
        raise.state.invitedSupply.total += amount;
        liquidated[msg.sender][address(raise.state.offered)] = raise
            .state
            .liquiditySupply
            .schedule
            .start;
    }

    function launch(uint64 id) external nonReentrant {
        Raise storage raise = raises[id];
        require(raise.config.creator != address(0), "raise does not exist");
        require(block.timestamp >= raise.config.strikeTime, "not time yet");
        raise.state.launched = true;
        require(
            raise.config.invitedTok.approve(
                address(raise.config.dex),
                uint64(raise.state.invitedSupply.total)
            ),
            "fail to approve dex (invited)"
        );
        require(
            raise.state.offered.approve(
                address(raise.config.dex),
                uint64(raise.state.offeredSupply.total)
            ),
            "fail to approve dex (offered)"
        );
        uint64 balInvitedBefore = uint64(
            raise.config.invitedTok.balanceOf(address(this))
        );
        uint64 balOfferedBefore = uint64(
            raise.state.offered.balanceOf(address(this))
        );
        if (raise.state.invitedSupply.total >= raise.config.guards.minRaise) {
            try
                raise.config.dex.initializeLiquidity(
                    address(raise.config.invitedTok),
                    address(raise.state.offered),
                    raise.state.invitedSupply.value,
                    raise.state.offeredSupply.value,
                    address(this),
                    raise.config.deployBytes
                )
            returns (uint64 position, uint256 liquidity) {
                uint256 burned = (liquidity / type(uint32).max) *
                    raise.config.allocs.liquidityBurning;
                raise.state.liquiditySupply.value = liquidity - burned;
                raise.state.liquiditySupply.total = liquidity - burned;
                raise.state.position = position;
            } catch {
                raise.state.exploded = true;
            }
        }
        require(
            raise.config.invitedTok.approve(address(raise.config.dex), 0),
            "fail to approve dex (invited)"
        );
        require(
            raise.state.offered.approve(address(raise.config.dex), 0),
            "fail to approve dex (offered)"
        );
        uint64 balInvitedAfter = uint64(
            raise.config.invitedTok.balanceOf(address(this))
        );
        uint64 balOfferedAfter = uint64(
            raise.state.offered.balanceOf(address(this))
        );

        uint64 invitedCredit = balInvitedAfter < balInvitedBefore
            ? 0
            : balInvitedAfter - balInvitedBefore;
        uint64 invitedDebit = balInvitedAfter > balInvitedBefore
            ? 0
            : balInvitedBefore - balInvitedAfter;
        raise.state.invitedSupply.value += invitedCredit;
        raise.state.invitedSupply.total += invitedCredit;
        raise.state.invitedSupply.value -= invitedDebit;
        raise.state.invitedSupply.total -= invitedDebit;

        uint64 offeredCredit = balOfferedAfter < balOfferedBefore
            ? 0
            : balOfferedAfter - balOfferedBefore;
        uint64 offeredDebit = balOfferedAfter > balOfferedBefore
            ? 0
            : balOfferedBefore - balOfferedAfter;
        raise.state.offeredSupply.value += offeredCredit;
        raise.state.offeredSupply.total += offeredCredit;
        raise.state.offeredSupply.value -= offeredDebit;
        raise.state.offeredSupply.total -= offeredDebit;

        raise.state.liquiditySupply.fixated = true;
        raise.state.invitedSupply.fixated = true;
        raise.state.offeredSupply.fixated = true;
    }

    function attend(
        uint64 id,
        uint64 minInviteOut,
        uint64 minOfferedOut,
        address to
    ) external nonReentrant {
        Raise storage raise = raises[id];
        require(raise.config.creator != address(0), "raise does not exist");
        require(raise.state.launched, "not launched");

        if (
            (raise.state.exploded ||
                raise.state.invitedSupply.total <
                raise.config.guards.minRaise) &&
            msg.sender == underwriters[address(raise.state.offered)]
        ) {
            (bool success, ) = msg.sender.call{
                value: reserves[address(raise.state.offered)].value
            }("");
            require(success, "quanta refund failed");
        }

        if (msg.sender == raise.config.creator) {
            if (
                raise.state.exploded ||
                raise.state.invitedSupply.total < raise.config.guards.minRaise
            ) {
                require(
                    raise.state.offered.transfer(
                        msg.sender,
                        uint64(raise.state.offeredSupply.value)
                    ),
                    "failed credit"
                );
            } else if (
                block.timestamp >= raise.state.offeredSupply.schedule.start
            ) {
                uint64 span = uint64(block.timestamp) -
                    liquidated[msg.sender][address(raise.state.offered)];
                uint64 credit = (uint64(raise.state.offeredSupply.total) *
                    span) / raise.state.offeredSupply.schedule.length;
                if (credit > 0) {
                    require(
                        raise.state.offered.transfer(msg.sender, credit),
                        "failed credit"
                    );
                }
                raise.state.offeredSupply.value -= credit;
                raise.state.offeredSupply.schedule.start = uint64(
                    block.timestamp
                );
                raise.state.offeredSupply.schedule.length -= span;
                if (raise.state.invitedSupply.value > 0) {
                    require(
                        raise.config.invitedTok.transfer(
                            msg.sender,
                            uint64(raise.state.invitedSupply.value)
                        ),
                        "failed credit"
                    );
                    raise.state.invitedSupply.value = 0;
                }
                liquidated[msg.sender][address(raise.state.offered)] = uint64(
                    block.timestamp
                );
            }
        }

        if (
            raise.state.exploded ||
            raise.state.invitedSupply.total < raise.config.guards.minRaise
        ) {
            raise.config.invitedTok.transfer(
                msg.sender,
                contributed[msg.sender][address(raise.state.offered)]
            );
        } else {
            if (address(raise.config.dex) == address(0)) {
                uint64 credit = (uint64(raise.state.offeredSupply.total) *
                    contributed[msg.sender][address(raise.state.offered)]) /
                    uint64(raise.state.invitedSupply.total);
                if (credit > 0) {
                    require(
                        raise.state.offered.transfer(msg.sender, credit),
                        "failed credit"
                    );
                    raise.state.offeredSupply.value -= credit;
                }
            } else {
                uint64 span = uint64(block.timestamp) -
                    raise.state.liquiditySupply.schedule.start;
                uint64 creditMaximum = uint64(
                    (raise.state.liquiditySupply.total *
                        contributed[msg.sender][address(raise.state.offered)]) /
                        raise.state.invitedSupply.total
                );
                uint64 creditVested = (creditMaximum * span) /
                    raise.state.liquiditySupply.schedule.length;
                raise.config.dex.withdrawLiquidity(
                    address(raise.config.invitedTok),
                    address(raise.state.offered),
                    raise.state.position,
                    creditVested,
                    to,
                    minInviteOut,
                    minOfferedOut
                );
            }
        }
    }

    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=yN3lUM-r6bk";
    }

    event Confession(address, bytes message);

    function confess(
        address offered,
        uint64 amount,
        address to,
        bytes calldata message
    ) external nonReentrant returns (uint256 credit) {
        require(message.length > 0, "requires intent");
        credit =
            (reserves[offered].total * amount) /
            IZRC20(offered).totalSupply();
        require(
            IZRC20(offered).transferFrom(msg.sender, address(1), amount),
            "failed burn"
        );
        (bool success, ) = to.call{value: credit}("");
        require(success, "quanta refund failed");
        emit Confession(msg.sender, message);
    }
    
}
