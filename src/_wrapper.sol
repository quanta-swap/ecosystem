// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IZRC20.sol";

/*─────────────────────────────────────────────────────────────────────────────*
│ WQ – Wrapped Quanta (native, 8-dec / 64-bit)                                 │
│                                                                              │
│ • Deposits and withdrawals use the chain’s native Quanta coin (`msg.value`). │
│ • Public balances / allowances are uint64 (≈1.84 e19 units max).             │
│ • 1 WQ   = 10¹⁰ wei-quanta   (8-decimal fixed-point).                        │
│ • Any `msg.value % 1e10` wei is *immediately refunded* to the depositor.     │
*─────────────────────────────────────────────────────────────────────────────*/
contract WQ is IZRC20 {
    /*———————————— ERC-20 metadata ———————————*/
    string  public constant name     = "Wrapped Quanta";
    string  public constant symbol   = "WQ";
    uint8   public constant decimals = 8;

    /*———————————— Internal constants —————————*/
    uint256 private constant SCALE = 1e10;          // wei-quanta per 8-dec WQ
    uint64  private constant INF   = type(uint64).max; // sentinel “∞” allowance

    /*———————————— ERC-20 state (64-bit) ———————*/
    mapping(address => uint64)                     public balanceOf;
    mapping(address => mapping(address => uint64)) public allowance;

    /*———————————— ERC-20 & wrapper events ————*/
    event Deposit   (address indexed dst,                       uint64 tok);
    event Withdrawal(address indexed src,                       uint64 tok);

    /*═════════════════════════════════════════════════════════════════════════*/
    /*                              NATIVE → WQ                               */
    /*═════════════════════════════════════════════════════════════════════════*/

    /// Fallback entry-point: wrap any incoming Quanta.
    receive() external payable { deposit(); }

    /**
     * @notice Convert native Quanta to WQ.
     *
     * @dev
     * 1. Calculates whole-token lots: `tok = msg.value / 1e10`.
     * 2. Immediately refunds the remainder (`msg.value % 1e10`) back to sender.
     * 3. Mints `tok` WQ (if non-zero) and emits ERC-20 events.
     */
    function deposit() public payable {
        uint256 weiIn  = msg.value;
        uint64  tok    = uint64(weiIn / SCALE);        // fits 64-bit by design
        uint256 dust   = weiIn - uint256(tok) * SCALE; // remainder wei

        if (dust > 0) {
            // Refund the dust so no wei remains stranded.
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = msg.sender.call{value: dust}("");
            require(ok, "refund failed");
        }

        if (tok > 0) {
            balanceOf[msg.sender] += tok;
            emit Deposit(msg.sender, tok);
            emit Transfer(address(0), msg.sender, tok); // ERC-20 mint
        }
    }

    /*═════════════════════════════════════════════════════════════════════════*/
    /*                              WQ → NATIVE                               */
    /*═════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Burn `wad` WQ and receive native Quanta.
     * @param  wad  Amount in WQ (8-dec units).
     */
    function withdraw(uint64 wad) external {
        uint64 bal = balanceOf[msg.sender];
        require(bal >= wad, "balance");

        balanceOf[msg.sender] = bal - wad;
        emit Withdrawal(msg.sender, wad);
        emit Transfer(msg.sender, address(0), wad);     // ERC-20 burn

        uint256 weiOut = uint256(wad) * SCALE;
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = msg.sender.call{value: weiOut}("");
        require(ok, "send failed");
    }

    /*═════════════════════════════════════════════════════════════════════════*/
    /*                                ERC-20 views                             */
    /*═════════════════════════════════════════════════════════════════════════*/

    /// @return totalSupply – sum of all WQ in existence (8-dec units).
    function totalSupply() external view returns (uint64) {
        return uint64(address(this).balance / SCALE);
    }

    /*═════════════════════════════════════════════════════════════════════════*/
    /*                               ERC-20 writes                             */
    /*═════════════════════════════════════════════════════════════════════════*/

    function approve(address guy, uint64 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    /**
     * -------------------------------------------------------------------------
     *  transferBatch                                                          ░
     * -------------------------------------------------------------------------
     *  Sends tokens from the caller (`msg.sender`) to many recipients in a
     *  single call – syntactic sugar around repeated `transferFrom` calls.
     *
     *  @param dst  Array of recipient addresses.
     *  @param wad  Array of token quantities (8-dec WQ) matching `dst`.
     *  @return success  Always true when the entire batch succeeds.
     *
     *  Requirements
     *  ------------
     *  • `dst.length == wad.length` – 1:1 correspondence between recipients and
     *    amounts.  
     *  • Each element is processed **sequentially**; if any leg fails the whole
     *    transaction reverts (atomic “all-or-nothing”).  
     *  • Worst-case gas is linear in `dst.length`; keep batches modest (≲200)
     *    to stay within the block gas limit.
     *
     *  Implementation notes
     *  --------------------
     *  • Delegates to `transferFrom(msg.sender, …)` so all balance/allowance
     *    invariants are enforced by the canonical logic.  
     *  • `unchecked` block saves ~30 gas on the loop counter since overflow on
     *    `i` is impossible (max 2²⁵ ⁶ iterations is unreachable).
     */
    function transferBatch(
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success)
    {
        uint256 len = dst.length;
        require(len == wad.length, "len");

        unchecked {
            for (uint256 i; i < len; ++i) {
                // Each leg is a full ERC-20 transfer; reverts bubble up.
                require(
                    transferFrom(msg.sender, dst[i], wad[i]),
                    "xfer fail"
                );
            }
        }
        return true;
    }

    function transfer(address dst, uint64 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /**
     * -------------------------------------------------------------------------
     *  transferFromBatch                                                      ░
     * -------------------------------------------------------------------------
     *  Sends tokens from a single `src` address to many recipients using the
     *  caller’s allowance in **one** transaction.
     *
     *  @param src  Address to debit for every leg of the batch.
     *  @param dst  Array of recipient addresses.
     *  @param wad  Array of token quantities (8-dec WQ) matching `dst`.
     *  @return success  Always true when the entire batch succeeds.
     *
     *  Behaviour
     *  ---------
     *  • Mirrors the semantics of making `dst.length` individual `transferFrom`
     *    calls: allowance is decremented incrementally, and the function
     *    reverts as soon as any leg would revert.  
     *  • Maintains atomicity – either **all** transfers succeed or none.
     *  • Gas cost is roughly the sum of the individual transfers plus a small
     *    loop overhead; batching mainly reduces calldata size.
     */
    function transferFromBatch(
        address src,
        address[] calldata dst,
        uint64[] calldata wad
    ) external returns (bool success)
    {
        uint256 len = dst.length;
        require(len == wad.length, "len");

        unchecked {
            for (uint256 i; i < len; ++i) {
                require(
                    transferFrom(src, dst[i], wad[i]),
                    "xfer fail"
                );
            }
        }
        return true;
    }

    function transferFrom(
        address src,
        address dst,
        uint64  wad
    ) public returns (bool) {
        require(balanceOf[src] >= wad, "balance");

        if (src != msg.sender && allowance[src][msg.sender] != INF) {
            uint64 left = allowance[src][msg.sender];
            require(left >= wad, "allowance");
            allowance[src][msg.sender] = left - wad;
            emit Approval(src, msg.sender, left - wad);
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }
}
