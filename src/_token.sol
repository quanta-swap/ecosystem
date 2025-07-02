// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZRC20} from "./IZRC20.sol";

/*──────────────────────────────────────────────────────────────────────────────
│  TradesPerDayToken – A 64‑bit IZRC‑20 with daily‑additive lock mechanics       │
│                                                                               │
│  • Multiple concurrent admins with 1‑of‑N authority.                          │
│  • All balances, allowances and supply are uint64.                            │
│  • Admins may freeze portions of accounts for the rest of the UTC day.        │
│  • Batch helpers improve UX while respecting the allowance model.             │
│                                                                               │
│  Per‑account storage layout:                                                  │
│    uint64 bal      – spendable balance.                                       │
│    uint64 locked   – amount frozen until the next UTC day boundary.           │
│    uint32 win      – day‑number associated with `locked`.                     │
└─────────────────────────────────────────────────────────────────────────────*/
contract TradesPerDayToken is IZRC20 {
    /*──────────────────────  Token metadata  ──────────────────────*/
    string private constant _NAME    = "Free Trade Per Day Token"; // e.g. "Trades‑Per‑Day Token"
    string private constant _SYMBOL  = "FREE";                     // e.g. "TPD"
    uint8  private constant _DECIMALS = 8;                          // fixed 8‑dp asset
    uint64 private constant ONE_TOKEN = 10 ** 8;                    // 1.00000000 base units

    /*──────────────────  Per‑account packed struct  ───────────────*/
    struct Account {
        uint64 bal;    // spendable balance
        uint64 locked; // tokens frozen for the rest of `win`
        uint32 win;    // UTC day‑number the lock applies to
    }
    mapping(address => Account) private _acct;

    /*──────────────────  Allowances  ──────────────────────────────*/
    mapping(address => mapping(address => uint64)) private _allow;

    /*──────────────────  Supply & admin set  ──────────────────────*/
    uint64 private _tot;                          // totalSupply
    mapping(address => bool) public isAdmin;      // O(1) membership check
    uint16  private _adminCount;                  // prevents 0‑admin state

    /*────────────────────────  Events  ────────────────────────────*/
    event Locked(address indexed acct, uint64 totalLocked, uint32 window);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event AdminSwapped(address indexed oldAdmin, address indexed newAdmin);

    /*─────────────────────  Constructor  ──────────────────────────*/
    /**
     * @param fixedSupply  One‑shot mint allocated to deployer (uint64, 8 dp).
     */
    constructor(uint64 fixedSupply) {
        // Deployer is the first admin (1‑of‑N governance).
        isAdmin[msg.sender] = true;
        _adminCount = 1;
        emit AdminAdded(msg.sender);

        // Optional instant mint to bootstrap liquidity.
        if (fixedSupply > 0) {
            _tot = fixedSupply;
            _acct[msg.sender].bal = fixedSupply;
            emit Transfer(address(0), msg.sender, fixedSupply);
        }
    }

    /*───────────  Non‑core fun: theme music easter‑egg  ───────────*/
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=wbkEFIVXLNw";
    }

    /*──────────────────  IZRC‑20 metadata  ────────────────────────*/
    function name()    external pure override returns (string memory) { return _NAME; }
    function symbol()  external pure override returns (string memory) { return _SYMBOL; }
    function decimals() external pure override returns (uint8)        { return _DECIMALS; }
    function totalSupply() external view override returns (uint64)    { return _tot; }

    /*──────────────────  Standard getters  ────────────────────────*/
    function balanceOf(address a) external view override returns (uint64) { return _acct[a].bal; }
    function allowance(address o, address s) external view override returns (uint64) { return _allow[o][s]; }

    /*────────────────────  Admin modifier  ────────────────────────*/
    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "TPD:not admin");
        _;
    }

    /*──────────────────  Transfer plumbing  ───────────────────────*/
    /**
     * @notice Direct transfer of tokens.
     * @dev    Reverts if `msg.sender` lacks unlocked balance.
     */
    function transfer(address to, uint64 value) external override returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    /**
     * @notice Approve `spender` to expend `value` tokens.
     * @dev    `uint64.max` is treated as “infinite” allowance (gas‑discount).
     */
    function approve(address spender, uint64 value) external override returns (bool) {
        _allow[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * @notice Transfer on behalf of `from`, obeying allowance model.
     */
    function transferFrom(address from, address to, uint64 value) external override returns (bool) {
        /*–––– allowance accounting ––––*/
        uint64 cur = _allow[from][msg.sender];
        if (cur != type(uint64).max) {
            require(cur >= value, "TPD:allow");
            unchecked { _allow[from][msg.sender] = cur - value; }
            emit Approval(from, msg.sender, cur - value);
        }
        _move(from, to, value);
        return true;
    }

    /** @dev Internal balance move that respects the per‑day lock. */
    function _move(address from, address to, uint64 value) internal {
        require(to != address(0), "TPD:zero dst");
        Account storage src = _acct[from];
        uint64 lockedNow = (src.win == _curWin()) ? src.locked : 0;
        require(src.bal - lockedNow >= value, "TPD:locked/bal");
        unchecked {
            src.bal -= value;
            _acct[to].bal += value;
        }
        emit Transfer(from, to, value);
    }

    /*───────────────────  Daily additive lock  ────────────────────*/
    /**
     * @notice Freeze `amount` of `acct`’s tokens until 00:00 UTC of the next day.
     * @dev    Multiple calls in the same day are additive.
     *
     * Requirements:
     *  • Caller must be admin.
     *  • `amount` must be >0 and ≤ ONE_TOKEN per call.
     *  • Account must have enough *unlocked* balance.
     */
    function lock(address acct, uint64 amount) external onlyAdmin {
        require(acct != address(0), "TPD:zero acct");
        require(amount > 0 && amount <= ONE_TOKEN, "TPD:>1 token");

        Account storage a = _acct[acct];
        uint32 w = _curWin();
        uint64 currentLocked = (a.win == w) ? a.locked : 0;
        require(a.bal - currentLocked >= amount, "TPD:not enough unlocked");
        unchecked { a.locked = currentLocked + amount; }
        a.win = w;
        emit Locked(acct, a.locked, w);
    }

    /** @return Number of tokens frozen for `acct` in the current UTC day. */
    function lockedBalanceOf(address acct) external view returns (uint64) {
        Account storage a = _acct[acct];
        return (a.win == _curWin()) ? a.locked : 0;
    }

    /*────────────────────  Admin management  ──────────────────────*/
    // Any *current* admin may add another admin (1‑of‑N governance).
    function addAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0) && !isAdmin[newAdmin], "TPD:bad");
        isAdmin[newAdmin] = true;
        _adminCount += 1;
        emit AdminAdded(newAdmin);
    }

    // Any admin may remove another admin as long as one remains.
    function removeAdmin(address admin) external onlyAdmin {
        require(isAdmin[admin], "TPD:not admin");
        require(_adminCount > 1, "TPD:last admin");
        isAdmin[admin] = false;
        _adminCount -= 1;
        emit AdminRemoved(admin);
    }

    // Any admin may atomically replace one admin address with a new one.
    function swapAdmin(address oldAdmin, address newAdmin) external onlyAdmin {
        require(isAdmin[oldAdmin], "TPD:old !admin");
        require(newAdmin != address(0) && !isAdmin[newAdmin], "TPD:bad new");
        isAdmin[oldAdmin] = false;
        isAdmin[newAdmin] = true;
        emit AdminSwapped(oldAdmin, newAdmin);
    }

    function getAdminCount() external view returns (uint16) { return _adminCount; }

    /*───────────────────  Batch helpers  ──────────────────────────*/
    function transferBatch(address[] calldata dst, uint64[] calldata wad) external override returns (bool) {
        _transferFromBatch(msg.sender, dst, wad);
        return true;
    }

    function transferFromBatch(address src, address[] calldata dst, uint64[] calldata wad) external override returns (bool) {
        _transferFromBatch(src, dst, wad);
        return true;
    }

    /** @dev Internal loop used by both batch façades. */
    function _transferFromBatch(address src, address[] calldata dst, uint64[] calldata wad) internal {
        uint256 len = dst.length;
        require(len == wad.length, "TPD:len");

        uint64 cur = _allow[src][msg.sender];
        bool inf = cur == type(uint64).max;

        for (uint256 i; i < len; ++i) {
            uint64 value = wad[i];
            if (!inf) {
                require(cur >= value, "TPD:allow");
                cur -= value;
            }
            _move(src, dst[i], value);
        }

        if (!inf) {
            _allow[src][msg.sender] = cur;
            emit Approval(src, msg.sender, cur);
        }
    }

    /*──────────────────  Time helper (UTC day)  ───────────────────*/
    function _curWin() internal view returns (uint32) {
        // Whole days since Unix epoch (UTC). Safe until year ~2106.
        return uint32(block.timestamp / 1 days);
    }
}