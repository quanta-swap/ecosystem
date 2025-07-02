// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol"; // adjust the relative path if needed

/* ───────────────  Re-entrancy guard  ─────────────── */
abstract contract ReentrancyGuard {
    uint8 private constant _NOT = 1;
    uint8 private constant _ENT = 2;
    uint8 private _stat = _NOT;
    modifier nonReentrant() {
        require(_stat != _ENT, "re-enter");
        _stat = _ENT;
        _;
        _stat = _NOT;
    }
}

contract Crowdsaler is ReentrancyGuard {
    // Price is determined by amount raised
    struct Crowdsale {
        address controller;
        IZRC20 input;
        IZRC20 output;
        uint64 minimumRaise; // in input tokens
        uint64 outputAmount;
        uint64 raisedAmount; // in input tokens
        uint64 endsAt;
        uint64 totalClaimedOut; // NEW: tracks output paid to users
        bool controllerClaimed; // renamed for clarity
    }

    struct CrowdsaleMetadata {
        string title;
        string description;
        string imageUrl;
        string websiteUrl;
        string[] socialUrls;
    }

    /* All events related to crowdsales */
    event CrowdsaleCreated(
        uint64 indexed id,
        address indexed controller,
        address input,
        address output,
        uint64 outputAmount,
        uint64 minimumRaise,
        uint64 endsAt
    );
    event CrowdsaleEntered(
        uint64 indexed id,
        address indexed user,
        uint64 amount
    );
    event CrowdsaleClaimed(
        uint64 indexed id,
        address indexed user,
        uint64 outputAmount,
        uint64 inputRefund
    );
    event CrowdsaleControllerClaimed(
        uint64 indexed id,
        address indexed controller,
        uint64 inputAmount,
        uint64 unsoldOutput
    );
    event CrowdsaleDustWithdrawn(
        uint64 indexed id,
        address indexed controller,
        uint64 dustAmount
    );
    event CrowdsaleMetadataSet(
        uint64 indexed id,
        string title,
        string description,
        string imageUrl,
        string websiteUrl,
        string[] socialUrls
    );
    /// Emitted when a contributor pulls out before the sale ends.
    event CrowdsaleContributionWithdrawn(
        uint64 indexed id,
        address indexed user,
        uint64 amount
    );

    Crowdsale[] public crowdsales;

    mapping(address => mapping(uint64 => uint64)) public contributions; // user => crowdsaleId => amount
    mapping(address => mapping(uint64 => bool)) public claimed; // user => crowdsaleId => claimed

    function createCrowdsale(
        IZRC20 input,
        IZRC20 output,
        uint64 outputAmount,
        uint64 minimumRaise,
        uint64 duration,
        CrowdsaleMetadata calldata metadata
    ) external nonReentrant {
        require(input != output, "Input and output must differ");
        require(duration > 0, "Duration must be positive");
        /* pull the output funds into the contract */
        require(
            output.transferFrom(msg.sender, address(this), outputAmount),
            "Transfer failed"
        );
        crowdsales.push(
            Crowdsale({
                controller: msg.sender,
                input: input,
                output: output,
                outputAmount: outputAmount,
                minimumRaise: minimumRaise,
                raisedAmount: 0,
                endsAt: uint64(block.timestamp) + duration,
                totalClaimedOut: 0,
                controllerClaimed: false
            })
        );
        emit CrowdsaleCreated(
            uint64(crowdsales.length - 1),
            msg.sender,
            address(input),
            address(output),
            outputAmount,
            minimumRaise,
            uint64(block.timestamp) + duration
        );
        emit CrowdsaleMetadataSet(
            uint64(crowdsales.length - 1),
            metadata.title,
            metadata.description,
            metadata.imageUrl,
            metadata.websiteUrl,
            metadata.socialUrls
        );
    }

    /**
     * @notice Register a user’s contribution to an open crowdsale.
     *         The caller supplies `amount` of *input* tokens which are pulled
     *         into the contract.  Price discovery is fully linear: contributors
     *         receive a pro-rata share of the pre-deposited `outputAmount`
     *         once the sale ends.
     *
     * @param id      Crowdsale index in the `crowdsales` array.
     * @param amount  Exact quantity of *input* tokens to contribute (uint64).
     *
     * Assumptions & invariants
     * ------------------------
     * • All observable balances in this universe are ≤ 2⁶⁴-1, so a single
     *   contributor cannot overflow the `uint64` slots even after many calls.
     * • The nonReentrant guard prevents malicious `IZRC20` implementations from
     *   re-entering and double-crediting themselves.
     * • Checks-Effects-Interactions ordering is respected: state is updated
     *   before the external `transferFrom` interaction.
     */
    function enterCrowdsale(uint64 id, uint64 amount) external nonReentrant {
        /*──────────────  CHECKS  ──────────────*/
        require(id < crowdsales.length, "bad id");
        require(amount > 0, "zero");

        Crowdsale storage cs = crowdsales[id];
        require(block.timestamp < cs.endsAt, "ended");

        /* Guard against accidental raisedAmount wrap-around.  In a 64-bit token
           economy this is practically unreachable but still costs ~3 gas.     */
        require(cs.raisedAmount + amount >= cs.raisedAmount, "raised ovf");

        /*──────────────  EFFECTS  ─────────────*/
        cs.raisedAmount += amount;
        contributions[msg.sender][id] += amount;

        /*───────────  INTERACTIONS  ───────────*/
        /* Pull the input tokens *after* internal bookkeeping to follow CEI.     */
        require(
            cs.input.transferFrom(msg.sender, address(this), amount),
            "xfer"
        );
        emit CrowdsaleEntered(id, msg.sender, amount);
    }

    function quoteContributions(
        uint64 id,
        address user
    ) public view returns (uint64) {
        require(id < crowdsales.length, "Invalid crowdsale id");
        Crowdsale storage cs = crowdsales[id];
        uint64 userContribution = contributions[user][id];
        if (cs.raisedAmount == 0) {
            return 0;
        }
        return
            uint64(
                (uint256(userContribution) * cs.outputAmount) / cs.raisedAmount
            );
    }

    /**
     * ----------------------------------------------------------------------
     *  withdrawContributions                                                ░
     * ----------------------------------------------------------------------
     *  Let a contributor fully exit an *ongoing* crowdsale by reclaiming
     *  every input token they have supplied so far.  This is useful if the
     *  user decides the sale’s price trajectory no longer fits their edge.
     *
     *  @param id  Crowdsale index in the `crowdsales` array.
     *
     *  Flow & guarantees
     *  -----------------
     *  • REQUIRES the sale has **not** ended (`block.timestamp < endsAt`).
     *  • REQUIRES the caller has a non-zero contribution.
     *  • Updates internal state **before** interacting with `input.transfer`
     *    (CEI pattern + nonReentrant guard).
     *  • Cannot underflow: `raisedAmount ≥ userContribution` by invariant.
     *  • Emits `CrowdsaleContributionWithdrawn` for off-chain indexers.
     */
    function withdrawContributions(uint64 id) external nonReentrant {
        /*──────────────  CHECKS  ──────────────*/
        require(id < crowdsales.length, "bad id");

        Crowdsale storage cs = crowdsales[id];
        require(block.timestamp < cs.endsAt, "ended");

        uint64 amt = contributions[msg.sender][id];
        require(amt > 0, "none");

        /*──────────────  EFFECTS  ─────────────*/
        cs.raisedAmount -= amt; // safe: ≤ previous value
        contributions[msg.sender][id] = 0; // zero-out sender position

        /*───────────  INTERACTIONS  ───────────*/
        require(cs.input.transfer(msg.sender, amt), "xfer");

        emit CrowdsaleContributionWithdrawn(id, msg.sender, amt);
    }

    function claimContributions(uint64 id) external nonReentrant {
        require(id < crowdsales.length, "bad id"); // moved first
        Crowdsale storage cs = crowdsales[id];
        require(block.timestamp >= cs.endsAt, "not ended");
        require(!claimed[msg.sender][id], "claimed");

        claimed[msg.sender][id] = true;
        if (cs.raisedAmount >= cs.minimumRaise) {
            uint64 out = quoteContributions(id, msg.sender);
            if (out == 0) {
                // tiny contributor refund
                uint64 refund = contributions[msg.sender][id];
                require(cs.input.transfer(msg.sender, refund), "refund");
                emit CrowdsaleClaimed(id, msg.sender, 0, refund);
                return;
            }
            require(cs.output.transfer(msg.sender, out), "xfer");
            cs.totalClaimedOut += out;
            emit CrowdsaleClaimed(id, msg.sender, out, 0);
        } else {
            uint64 inp = contributions[msg.sender][id];
            if (inp > 0) require(cs.input.transfer(msg.sender, inp), "xfer");
            emit CrowdsaleClaimed(id, msg.sender, 0, inp);
        }
    }

    function claimCrowdsaleFunds(uint64 id) external nonReentrant {
        require(id < crowdsales.length, "bad id"); // moved first
        Crowdsale storage cs = crowdsales[id];
        require(block.timestamp >= cs.endsAt, "not ended");
        require(msg.sender == cs.controller, "not ctrl");
        require(!cs.controllerClaimed, "claimed");

        uint64 unsold;               // track unsold output for event
        if (cs.raisedAmount >= cs.minimumRaise) {
            uint64 raised = cs.raisedAmount;
            cs.controllerClaimed = true;
            if (raised > 0) cs.input.transfer(msg.sender, raised);
            unsold = 0;
        } else {
            unsold = cs.outputAmount;
            cs.controllerClaimed = true;
            if (unsold > 0) cs.output.transfer(msg.sender, unsold);
        }

        emit CrowdsaleControllerClaimed(id, msg.sender, cs.raisedAmount, unsold);
    }

    // After a successful sale, let controller sweep leftover output once:
    // (callable after all contributor claims, gas-cheap)
    function withdrawDust(uint64 id) external nonReentrant {
        require(id < crowdsales.length, "bad id");
        Crowdsale storage cs = crowdsales[id];
        require(block.timestamp >= cs.endsAt, "not ended");
        require(msg.sender == cs.controller, "not ctrl");
        require(cs.totalClaimedOut == cs.outputAmount, "claims open");
        require(cs.controllerClaimed, "ctrl unclaimed");

        uint64 dust = cs.outputAmount - cs.totalClaimedOut; // safe: uint64
        require(dust > 0, "no dust");
        cs.output.transfer(msg.sender, dust);

        emit CrowdsaleDustWithdrawn(id, msg.sender, dust);
    }
}
