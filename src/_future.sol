// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────────────────
│  64-bit ZRC-20 interface (ERC-20 semantics)
└──────────────────────────────────────────────*/
import {IZRC20} from "./IZRC20.sol";   // adjust the relative path if needed

/*──────────────────────────────────────────────
│  Minimal ERC-165 / ERC-721 stack (stand-alone)
└──────────────────────────────────────────────*/
interface IERC165 {
    function supportsInterface(bytes4) external view returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4);
}

interface IERC721 is IERC165 {
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed id
    );
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 indexed id
    );
    event ApprovalForAll(address indexed owner, address indexed op, bool ok);

    function balanceOf(address) external view returns (uint256);

    function ownerOf(uint256) external view returns (address);

    function safeTransferFrom(address, address, uint256) external;

    function transferFrom(address, address, uint256) external;

    function approve(address, uint256) external;

    function getApproved(uint256) external view returns (address);

    function setApprovalForAll(address, bool) external;

    function isApprovedForAll(address, address) external view returns (bool);

    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes calldata
    ) external;
}

interface IERC721Metadata is IERC721 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI(uint256) external view returns (string memory);
}

abstract contract ERC165 is IERC165 {
    function supportsInterface(
        bytes4 i
    ) public view virtual override returns (bool) {
        return i == type(IERC165).interfaceId;
    }
}

/*──────────────────────────────────────────────
│  Re-entrancy guard
└──────────────────────────────────────────────*/
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

/*──────────────────────  Safe token transfer wrappers  ─────────────────────*/
library SafeZRC20 {
    function _call(address t, bytes memory dat) private returns (bool) {
        (bool ok, bytes memory ret) = t.call(dat);
        if (!ok) return false; // low-level call failed
        if (ret.length == 0) return true; // non-standard ERC-20
        if (ret.length == 32) return abi.decode(ret, (bool)); // standard ERC-20
        return false; // anything else: reject
    }

    function safeTransfer(IZRC20 tok, address to, uint64 amt) internal {
        require(
            _call(
                address(tok),
                abi.encodeWithSelector(tok.transfer.selector, to, amt)
            ),
            "safeT"
        );
    }

    function safeTransferFrom(
        IZRC20 tok,
        address f,
        address t,
        uint64 amt
    ) internal {
        require(
            _call(
                address(tok),
                abi.encodeWithSelector(tok.transferFrom.selector, f, t, amt)
            ),
            "safeTF"
        );
    }
}
using SafeZRC20 for IZRC20;

/*──────────────────────────────────────────────
│  AmeriPeanFuturesDesk – ERC-721 futures + requests (no counters)
└──────────────────────────────────────────────*/
contract AmeriPeanFuturesDesk is ERC165, IERC721Metadata, ReentrancyGuard {

    /*────────── NEW: gas-guard & flag bits ─────────*/
    uint256 public constant MAX_BATCH = 50;

    uint8 private constant F_PURCHASED = 1;   // 0b001
    uint8 private constant F_SETTLED   = 2;   // 0b010
    uint8 private constant F_PLEDGED   = 4;   // 0b100

    /*═════════════  ERC-721 state  ═════════════*/
    string private constant _NAME = "AmeriPean Future";
    string private constant _SYMBOL = "APFUT";
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /*═════════════  FUTURE STATE  ═════════════*/
    struct Future {
        address maker;        // short – locks base
        IZRC20  base;
        IZRC20  quote;
        uint64  baseAmt;
        uint64  quoteAmt;
        uint64  expiry;       // UNIX ts (inclusive)
        uint8   flags;        // bit-packed booleans
    }
    Future[] private _fut;
    mapping(uint256 => bool) private _exists;

    /*═════════════  REQUEST STATE  ═════════════*/
    struct Request {
        address requester; // long side – will lock quote on accept
        IZRC20 base;
        IZRC20 quote;
        uint64 baseAmt;
        uint64 quoteAmt;
        uint64 expiry;
        bool open;
    }
    Request[] private _req;

    /*═════════════  EVENTS  ═══════════════════*/
    /* futures */
    event Posted(uint64 indexed id, address indexed maker);
    event Modified(uint64 indexed id);
    event Cancelled(uint64 indexed id);
    event Purchased(uint64 indexed id, address indexed buyer);
    event Settled(uint64 indexed id);
    event Pledged(uint64 indexed id, bool pledged);
    /* requests */
    event RequestPosted(
        uint64 indexed reqId,
        address indexed requester,
        uint64 indexed counter
    );
    event RequestModified(uint64 indexed reqId);
    event RequestCancelled(uint64 indexed reqId);
    event RequestMatched(
        uint64 indexed reqId,
        uint64 indexed futId,
        address indexed maker
    );

    /* Show me how it ends, it's alright... */
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=v0UcYtCFS9U";
    }

    /*═════════════  ERC-165  ══════════════════*/
    function supportsInterface(
        bytes4 i
    ) public view override(ERC165, IERC165) returns (bool) {
        return
            i == type(IERC721).interfaceId ||
            i == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(i);
    }

    /*═════════════  ERC-721 CORE  ═════════════*/
    function name() external pure override returns (string memory) {
        return _NAME;
    }

    function symbol() external pure override returns (string memory) {
        return _SYMBOL;
    }

    function tokenURI(uint256) external pure override returns (string memory) {
        return "";
    }

    function balanceOf(address o) public view override returns (uint256) {
        require(o != address(0), "0");
        return _balances[o];
    }

    function ownerOf(uint256 id) public view override returns (address) {
        address o = _owners[id];
        require(o != address(0), "nf");
        return o;
    }

    function getApproved(uint256 id) public view override returns (address) {
        require(_exists[id], "nf");
        return _tokenApprovals[id];
    }

    function isApprovedForAll(
        address o,
        address op
    ) public view override returns (bool) {
        return _operatorApprovals[o][op];
    }

    function approve(address to, uint256 id) external override {
        address o = ownerOf(id);
        require(to != o, "self");
        require(msg.sender == o || isApprovedForAll(o, msg.sender), "auth");
        _tokenApprovals[id] = to;
        emit Approval(o, to, id);
    }

    function setApprovalForAll(address op, bool ok) external override {
        _operatorApprovals[msg.sender][op] = ok;
        emit ApprovalForAll(msg.sender, op, ok);
    }

    function transferFrom(address f, address t, uint256 id) public override {
        require(_isApprovedOrOwner(msg.sender, id), "auth");
        _transfer(f, t, id);
    }

    function safeTransferFrom(
        address f,
        address t,
        uint256 id
    ) external override {
        safeTransferFrom(f, t, id, "");
    }

    function safeTransferFrom(
        address f,
        address t,
        uint256 id,
        bytes memory d
    ) public override {
        transferFrom(f, t, id);
        require(_checkOnERC721Received(f, t, id, d), "rcv");
    }

    /*–––– helpers ––––*/
    function _isApprovedOrOwner(
        address s,
        uint256 id
    ) internal view returns (bool) {
        address o = ownerOf(id);
        return (s == o || getApproved(id) == s || isApprovedForAll(o, s));
    }

    function _transfer(address f, address t, uint256 id) internal {
        require(ownerOf(id) == f, "own");
        require((_fut[id].flags & F_PLEDGED) == 0, "pledged");  // ← use bit-flag
        require(t != address(0), "to0");

        _beforeTokenTransfer(f, t, id);

        if (_tokenApprovals[id] != address(0)) {
            delete _tokenApprovals[id];
            emit Approval(f, address(0), id);
        }
        unchecked {
            _balances[f] -= 1;
            _balances[t] += 1;
        }
        _owners[id] = t;
        emit Transfer(f, t, id);
    }

    function _mint(address to, uint256 id) internal {
        require(to != address(0), "to0");
        require(!_exists[id], "dup");
        _beforeTokenTransfer(address(0), to, id);
        _owners[id] = to;
        _balances[to] += 1;
        _exists[id] = true;
        emit Transfer(address(0), to, id);
    }

    function _burn(uint256 id) internal {
        address o = ownerOf(id);
        _beforeTokenTransfer(o, address(0), id);
        if (_tokenApprovals[id] != address(0)) delete _tokenApprovals[id];
        unchecked {
            _balances[o] -= 1;
        }
        delete _owners[id];
        delete _exists[id];
        emit Transfer(o, address(0), id);
    }

    function _checkOnERC721Received(
        address f,
        address t,
        uint256 id,
        bytes memory d
    ) private returns (bool) {
        if (t.code.length == 0) return true;
        try IERC721Receiver(t).onERC721Received(msg.sender, f, id, d) returns (
            bytes4 v
        ) {
            return v == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    /*════════ POST FUTURE (writer) ════════*/
    function postFuture(
        IZRC20 base,
        IZRC20 quote,
        uint64 baseAmt,
        uint64 quoteAmt,
        uint64 expiry
    ) external nonReentrant returns (uint64 id) {
        _validateTokens(base, quote);
        _validateAmounts(baseAmt, quoteAmt);
        _validateExpiry(expiry);

        base.safeTransferFrom(msg.sender, address(this), baseAmt);

        id = uint64(_fut.length);
        _fut.push(
            Future({
                maker:     msg.sender,
                base:      base,
                quote:     quote,
                baseAmt:   baseAmt,
                quoteAmt:  quoteAmt,
                expiry:    expiry,
                flags:     0                     // nothing yet
            })
        );
        _mint(msg.sender, id);
        emit Posted(id, msg.sender);
    }

    /*════════ MODIFY FUTURE ════════*/
    function modifyFuture(
        uint64 id,
        uint64 newBase,
        uint64 newQuote,
        uint64 newExp
    ) external nonReentrant {
        Future storage f = _fut[id];
        require(msg.sender == f.maker, "maker");
        require((f.flags & F_PURCHASED) == 0, "sold");

        _validateAmounts(newBase, newQuote);
        _validateExpiry(newExp);

        if (newBase > f.baseAmt) {
            uint64 delta = newBase - f.baseAmt;
            f.base.safeTransferFrom(msg.sender, address(this), delta);
        } else if (newBase < f.baseAmt) {
            uint64 delta = f.baseAmt - newBase;
            f.base.safeTransfer(msg.sender, delta);
        }

        f.baseAmt  = newBase;
        f.quoteAmt = newQuote;
        f.expiry   = newExp;
        emit Modified(id);
    }

    /*════════ CANCEL FUTURE ════════*/
    function cancelFuture(uint64 id) external nonReentrant {
        Future storage f = _fut[id];
        require(msg.sender == f.maker, "maker");
        require((f.flags & F_PURCHASED) == 0, "sold");

        f.base.safeTransfer(f.maker, f.baseAmt);
        _burn(id);
        delete _fut[id];
        emit Cancelled(id);
    }

    /*════════ BUY (long side deposits quote) ════════*/
    function buyFutures(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) _buy(ids[i], msg.sender);
    }

    function _buy(uint64 id, address buyer) internal {
        Future storage f = _fut[id];
        require((f.flags & (F_PURCHASED | F_SETTLED)) == 0, "state");

        f.flags |= F_PURCHASED;
        f.quote.safeTransferFrom(buyer, address(this), f.quoteAmt);

        _transfer(f.maker, buyer, id);
        emit Purchased(id, buyer);
    }

    /*════════ PLEDGE / UNPLEDGE ════════*/
    function pledgeFuture(uint64 id, bool lock_) external {
        require(_isApprovedOrOwner(msg.sender, id), "auth");
        if (lock_) {
            _fut[id].flags |= F_PLEDGED;
        } else {
            _fut[id].flags &= ~F_PLEDGED;
        }
        emit Pledged(id, lock_);
    }

    /*════════ SETTLE (expiry reached) ════════*/
    function settle(uint64 id) external nonReentrant {
        _settle(id);
    }

    function settleFutures(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) _settle(ids[i]);
    }

    function _settle(uint64 id) internal {
        Future storage f = _fut[id];
        require((f.flags & F_PURCHASED) != 0, "unsold");
        require((f.flags & F_SETTLED) == 0, "done");
        require(block.timestamp >= f.expiry, "early");

        f.flags |= F_SETTLED;

        f.base.safeTransfer(ownerOf(id), f.baseAmt);
        f.quote.safeTransfer(f.maker,         f.quoteAmt);

        _burn(id);
        delete _fut[id];
        emit Settled(id);
    }

    /*════════ RECLAIM UNSOLD AFTER EXPIRY ════════*/
    function reclaimExpired(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) {
            uint64 id = ids[i];
            Future storage f = _fut[id];

            require(block.timestamp > f.expiry, "time");
            require((f.flags & F_PURCHASED) == 0, "sold");
            require(msg.sender == f.maker, "maker");

            f.base.safeTransfer(f.maker, f.baseAmt);
            _burn(id);
            delete _fut[id];
            emit Cancelled(id);
        }
    }

    /*═════════════  REQUEST WORKFLOW  ═════════════*/
    function postRequest(
        IZRC20 base,
        IZRC20 quote,
        uint64 baseAmt,
        uint64 quoteAmt,
        uint64 expiry,
        uint64 counter // unused, for UI parity
    ) external returns (uint64 reqId) {
        require(baseAmt > 0 && quoteAmt > 0, "zero");
        require(expiry > block.timestamp, "exp");
        reqId = uint64(_req.length);
        _req.push(
            Request(msg.sender, base, quote, baseAmt, quoteAmt, expiry, true)
        );
        emit RequestPosted(reqId, msg.sender, counter);
    }

    function modifyRequest(
        uint64 reqId,
        uint64 newQuote,
        uint64 newExp
    ) external {
        Request storage r = _req[reqId];
        require(r.open, "closed");
        require(msg.sender == r.requester, "own");
        require(newQuote > 0, "zero");
        require(newExp > block.timestamp, "exp");
        r.quoteAmt = newQuote;
        r.expiry = newExp;
        emit RequestModified(reqId);
    }

    function cancelRequests(uint64[] calldata ids) external {
        for (uint i; i < ids.length; ++i) {
            uint64 id = ids[i];
            Request storage r = _req[id];
            require(r.open, "closed");
            require(msg.sender == r.requester, "own");
            r.open = false;
            emit RequestCancelled(id);
        }
    }

    function acceptRequest(
        uint64 reqId
    ) external nonReentrant returns (uint64 futId) {
        futId = _accept(reqId, msg.sender);
    }

    function acceptRequests(uint64[] calldata ids) external nonReentrant {
        for (uint i; i < ids.length; ++i) _accept(ids[i], msg.sender);
    }

    /*════════ ACCEPT RFQ (writer) ════════*/
    function _accept(
        uint64 reqId,
        address maker
    ) internal returns (uint64 futId) {
        Request storage r = _req[reqId];
        require(r.open, "closed");

        r.base.safeTransferFrom(maker,      address(this), r.baseAmt);
        r.quote.safeTransferFrom(r.requester, address(this), r.quoteAmt);

        futId = _createFuture(
            maker,
            r.requester,
            r.base,
            r.quote,
            r.baseAmt,
            r.quoteAmt,
            r.expiry
        );

        r.open = false;
        emit RequestMatched(reqId, futId, maker);
    }

    /*════════ FACTORY ════════*/
    function _createFuture(
        address maker,
        address holder,
        IZRC20 base,
        IZRC20 quote,
        uint64 baseAmt,
        uint64 quoteAmt,
        uint64 expiry
    ) internal returns (uint64 id) {
        id = uint64(_fut.length);
        _fut.push(
            Future({
                maker:    maker,
                base:     base,
                quote:    quote,
                baseAmt:  baseAmt,
                quoteAmt: quoteAmt,
                expiry:   expiry,
                flags:    F_PURCHASED          // already funded
            })
        );
        _mint(holder, id);
        emit Purchased(id, holder);
    }

    /*═════════════  VIEWS  ═════════════════════*/
    function futureCount() external view returns (uint256) {
        return _fut.length;
    }

    function requestCount() external view returns (uint256) {
        return _req.length;
    }

    /*════════ FUTURE INFO VIEW ════════*/
    function futureInfo(
        uint64 id
    )
        external
        view
        returns (
            address maker,
            address holder,
            address base,
            address quote,
            uint64  baseAmt,
            uint64  quoteAmt,
            uint64  expiry,
            bool    purchased,
            bool    settled,
            bool    pledged_
        )
    {
        Future storage f = _fut[id];
        maker      = f.maker;
        holder     = _exists[id] ? ownerOf(id) : address(0);
        base       = address(f.base);
        quote      = address(f.quote);
        baseAmt    = f.baseAmt;
        quoteAmt   = f.quoteAmt;
        expiry     = f.expiry;
        purchased  = (f.flags & F_PURCHASED) != 0;
        settled    = (f.flags & F_SETTLED)   != 0;
        pledged_   = (f.flags & F_PLEDGED)   != 0;
    }

    function requestInfo(
        uint64 id
    )
        external
        view
        returns (
            address requester,
            address base,
            address quote,
            uint64 baseAmt,
            uint64 quoteAmt,
            uint64 expiry,
            bool open
        )
    {
        Request storage r = _req[id];
        requester = r.requester;
        base = address(r.base);
        quote = address(r.quote);
        baseAmt = r.baseAmt;
        quoteAmt = r.quoteAmt;
        expiry = r.expiry;
        open = r.open;
    }

    function exists(uint64 id) external view returns (bool) {
        return _exists[id];
    }

    /*════════ ERC-721 HOOK ════════*/
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 id
    ) internal view {
        if (from != address(0) && to != address(0)) {
            require((_fut[id].flags & F_PLEDGED) == 0, "pledged");
        }
    }

    /*════════ Validation helpers (private) ════════*/
    function _validateAmounts(uint64 baseAmt, uint64 quoteAmt) private pure {
        require(baseAmt > 0 && quoteAmt > 0, "zero");
    }
    function _validateExpiry(uint64 expiry) private view {
        require(expiry > block.timestamp, "expPast");
    }
    function _validateTokens(IZRC20 base, IZRC20 quote) private view {
        require(address(base)  != address(0) && address(base).code.length  != 0, "base");
        require(address(quote) != address(0) && address(quote).code.length != 0, "quote");
    }
}
