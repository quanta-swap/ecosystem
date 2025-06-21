// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*════════════════════════════════════════════════════════════════════════════
│  AmeriPeanOptionDesk – hardened 2025-06 revision (64-bit ERC-721 options)  │
│  • Immutable collateral safety (no post-listing haircut)                  │
│  • Writer offers + requester RFQs (no counters) with bounded batch ops    │
│  • Pledge-lock blocks *both* transfers *and* exercise                     │
│  • Two-day timelocked owner rescue hatch, single pending tx               │
│  • start > now enforced; premium may be zero                              │
│  • Gas-guarded MAX_BATCH to prevent DoS                                   │
════════════════════════════════════════════════════════════════════════════*/

import {IZRC20} from "./IZRC20.sol";   // adjust the relative path if needed

/*─────────────────────────  Minimal ERC-165 / ERC-721  ─────────────────────*/
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
    event ApprovalForAll(
        address indexed owner,
        address indexed op,
        bool approved
    );

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

/*──────────────────────────────  Re-entrancy  ───────────────────────────────*/
abstract contract ReentrancyGuard {
    uint256 private _stat;
    modifier nonReentrant() {
        require(_stat == 0, "reenter");
        _stat = 1;
        _;
        _stat = 0;
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

/*────────────────────────────  AmeriPean Desk  ─────────────────────────────*/
contract AmeriPeanOptionDesk is ERC165, IERC721Metadata, ReentrancyGuard {
    /*──── constants ───*/
    string private constant _NAME = "AmeriPean Option";
    string private constant _SYMBOL = "APO";
    uint256 public constant MAX_BATCH = 50; // gas-safety bound

    /*──── ERC-721 state ───*/
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => bool) private _exists;

    /*── bit-flags for packed booleans ──*/
    uint8 private constant F_PURCHASED = 1; // 0b001
    uint8 private constant F_EXERCISED = 2; // 0b010
    uint8 private constant F_PLEDGED = 4; // 0b100
    struct Option {
        address maker;
        IZRC20 reserve;
        IZRC20 tradeFor;
        IZRC20 feeTok;
        uint64 reserveAmt; // total collateral originally posted
        uint64 strikeAmt; // strike required for the *full* reserveAmt
        uint64 remainingAmt; // NEW: collateral still un-exercised
        uint64 premiumAmt;
        uint64 start;
        uint64 expiry;
        uint8 flags; // bit-packed booleans
    }
    Option[] private _opt;

    /*──── Request state ────*/
    struct Request {
        address requester;
        IZRC20 reserve;
        IZRC20 tradeFor;
        IZRC20 feeTok;
        uint64 reserveAmt;
        uint64 strikeAmt;
        uint64 premiumAmt;
        uint64 start;
        uint64 expiry;
        bool open;
    }
    Request[] private _req;

    /*──── events ───*/
    event Posted(uint64 indexed id, address indexed maker);
    event Modified(uint64 indexed id);
    event Cancelled(uint64 indexed id);
    event Expired(uint64 indexed id);
    event Purchased(uint64 indexed id, address indexed buyer);
    event Exercised(uint64 indexed id, address indexed to, uint64 qty);
    event Pledged(uint64 indexed id, bool pledged);
    event RequestPosted(
        uint64 indexed reqId,
        address indexed requester,
        uint64 indexed counter
    );
    event RequestModified(uint64 indexed reqId);
    event RequestCancelled(uint64 indexed reqId);
    event RequestMatched(
        uint64 indexed reqId,
        uint64 indexed optionId,
        address indexed maker
    );
    event CollateralReturned(uint64 indexed id, address indexed to, uint64 amt);

    /* reject accidental native-ETH transfers */
    receive() external payable {
        revert("noQRL");
    }

    /*──── ERC-165 ───*/
    function supportsInterface(
        bytes4 i
    ) public view override(ERC165, IERC165) returns (bool) {
        return
            i == type(IERC721).interfaceId ||
            i == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(i);
    }

    /*──── ERC-721 META ───*/
    function name() external pure override returns (string memory) {
        return _NAME;
    }

    function symbol() external pure override returns (string memory) {
        return _SYMBOL;
    }

    function tokenURI(
        uint256 id
    ) external view override returns (string memory) {
        require(_exists[id], "nf");
        Option storage o = _opt[id];
        return
            string(
                abi.encodePacked(
                    'data:application/json,{"name":"Option #',
                    _toString(id),
                    '","description":"AmeriPean call option","attributes":['
                    '{"trait_type":"Reserve Amt","value":"',
                    _toString(o.reserveAmt),
                    '"},'
                    '{"trait_type":"Strike Amt","value":"',
                    _toString(o.strikeAmt),
                    '"}]}'
                )
            );
    }

    /*──── ERC-721 core ───*/
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

    function transferFrom(
        address f,
        address t,
        uint256 id
    ) public override nonReentrant {
        require(_isApprovedOrOwner(msg.sender, id), "auth");
        _transfer(f, t, id);
    }

    function safeTransferFrom(
        address f,
        address t,
        uint256 id
    ) external override nonReentrant {
        safeTransferFrom(f, t, id, "");
    }

    function safeTransferFrom(
        address f,
        address t,
        uint256 id,
        bytes memory d
    ) public override nonReentrant {
        transferFrom(f, t, id);
        require(_checkOnERC721Received(f, t, id, d), "rcv");
    }

    /*──── helpers ───*/
    function _isApprovedOrOwner(
        address s,
        uint256 id
    ) internal view returns (bool) {
        address o = ownerOf(id);
        return (s == o || getApproved(id) == s || isApprovedForAll(o, s));
    }

    function _transfer(address f, address t, uint256 id) internal {
        require(ownerOf(id) == f, "own");
        require((_opt[id].flags & F_PLEDGED) == 0, "pledged"); // CHANGED
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

    /*───────────────────  postOption (writer)  ──────────────────*/
    function postOption(
        IZRC20 reserve,
        IZRC20 tradeFor,
        IZRC20 feeTok,
        uint64 reserveAmt,
        uint64 strikeAmt,
        uint64 premiumAmt,
        uint64 start,
        uint64 expiry
    ) external nonReentrant returns (uint64 id) {
        _validateTokens(reserve, tradeFor, feeTok);
        _validateAmounts(reserveAmt, strikeAmt, premiumAmt);
        _validateWindow(start, expiry);

        reserve.safeTransferFrom(msg.sender, address(this), reserveAmt);

        id = _createOption(
            msg.sender,
            msg.sender,
            reserve,
            tradeFor,
            feeTok,
            reserveAmt,
            strikeAmt,
            reserveAmt, // remainingAmt = full collateral   ← CHANGED
            premiumAmt,
            start,
            expiry,
            false
        );
        emit Posted(id, msg.sender);
    }

    /*  immutable collateral: reserveAmt can **only increase** after posting  */
    function modifyOption(
        uint64 id,
        uint64 newReserve,
        uint64 newStrike,
        uint64 newPrem,
        uint64 newStart,
        uint64 newExp
    ) external nonReentrant {
        Option storage o = _opt[id];
        require(msg.sender == o.maker, "maker");
        require((o.flags & F_PURCHASED) == 0, "sold");
        _validateAmounts(newReserve, newStrike, newPrem);
        _validateWindow(newStart, newExp);

        require(newReserve >= o.reserveAmt, "haircut");
        if (newReserve > o.reserveAmt) {
            uint64 delta = newReserve - o.reserveAmt;
            o.reserve.safeTransferFrom(msg.sender, address(this), delta);
            o.remainingAmt += delta; // keep proportion  ← CHANGED
        }

        o.reserveAmt = newReserve;
        o.strikeAmt = newStrike;
        o.premiumAmt = newPrem;
        o.start = newStart;
        o.expiry = newExp;
        emit Modified(id);
    }

    function cancelOption(uint64 id) external nonReentrant {
        Option storage o = _opt[id];
        require(msg.sender == o.maker, "maker");
        require((o.flags & F_PURCHASED) == 0, "sold"); // CHANGED

        o.reserve.safeTransfer(o.maker, o.reserveAmt);

        _burn(id);
        delete _opt[id];
        emit Cancelled(id);
    }

    /*── buying ──*/
    function buyOptions(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) _buy(ids[i], msg.sender);
    }

    /*───────────────────────  _buy()  ───────────────────────────*/
    function _buy(uint64 id, address buyer) internal {
        Option storage o = _opt[id];
        require((o.flags & (F_PURCHASED | F_EXERCISED)) == 0, "state"); // CHANGED

        o.flags |= F_PURCHASED; // CHANGED
        if (o.premiumAmt > 0) {
            o.feeTok.safeTransferFrom(buyer, o.maker, o.premiumAmt);
        }

        _transfer(o.maker, buyer, id);
        require(_checkOnERC721Received(o.maker, buyer, id, ""), "rcv");
        emit Purchased(id, buyer);
    }

    /*── pledge lock ──*/
    function pledgeOption(uint64 id, bool lock_) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, id), "auth");
        if (lock_) {
            _opt[id].flags |= F_PLEDGED; // set bit
        } else {
            _opt[id].flags &= ~F_PLEDGED; // clear bit
        }
        emit Pledged(id, lock_);
    }

    /*── exercise (full) ──*/
    /* exercise *exactly* `qty` collateral units to `msg.sender` */
    function exercise(uint64 id, uint64 qty) external nonReentrant {
        exerciseTo(id, msg.sender, qty);
    }

    /*─────────────────────  exerciseTo()  ───────────────────────*/
    /* exercise *qty* collateral units to arbitrary recipient */
    function exerciseTo(uint64 id, address to, uint64 qty) public nonReentrant {
        Option storage o = _opt[id];
        require((o.flags & F_PLEDGED) == 0, "pledged");
        require(ownerOf(id) == msg.sender, "hold");
        require(
            block.timestamp >= o.start && block.timestamp <= o.expiry,
            "window"
        );
        require(qty > 0 && qty <= o.remainingAmt, "qty");

        /* strike to pay = qty × strikeAmt / reserveAmt  (ratio fixed) */
        uint64 strikePay = uint64(
            (uint256(o.strikeAmt) * qty) / uint256(o.reserveAmt)
        );

        o.remainingAmt -= qty;

        /* if everything is gone mark fully-exercised & burn */
        bool emptied = (o.remainingAmt == 0);
        if (emptied) {
            o.flags |= F_EXERCISED;
            _burn(id);
            delete _opt[id];
        }

        o.tradeFor.safeTransferFrom(msg.sender, o.maker, strikePay);
        o.reserve.safeTransfer(to, qty);

        emit Exercised(id, to, qty);

        /* emit CollateralReturned on full consumption for parity with expiry */
        if (emptied) emit CollateralReturned(id, to, 0);
    }

    /*── reclaim after expiry ──*/
    function reclaimExpired(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) {
            uint64 id = ids[i];
            Option storage o = _opt[id];
            require(block.timestamp > o.expiry, "time");
            require((o.flags & F_EXERCISED) == 0, "done");
            require(
                ownerOf(id) == msg.sender || o.maker == msg.sender,
                "party"
            );

            uint64 rem = o.remainingAmt; // ← CHANGED
            if (rem > 0) {
                o.reserve.safeTransfer(o.maker, rem);
                emit CollateralReturned(id, o.maker, rem);
            }

            _burn(id);
            delete _opt[id];
            emit Expired(id);
        }
    }

    /*───────────────────  postRequest (RFQ)  ───────────────────*/
    function postRequest(
        IZRC20 reserve,
        IZRC20 tradeFor,
        IZRC20 feeTok,
        uint64 reserveAmt,
        uint64 strikeAmt,
        uint64 premiumAmt,
        uint64 start,
        uint64 expiry,
        uint64 counter
    ) external returns (uint64 reqId) {
        _validateTokens(reserve, tradeFor, feeTok);
        _validateAmounts(reserveAmt, strikeAmt, premiumAmt);
        _validateWindow(start, expiry);

        reqId = uint64(_req.length);
        _req.push(
            Request(
                msg.sender,
                reserve,
                tradeFor,
                feeTok,
                reserveAmt,
                strikeAmt,
                premiumAmt,
                start,
                expiry,
                true
            )
        );
        emit RequestPosted(reqId, msg.sender, counter);
    }

    function modifyRequest(
        uint64 reqId,
        uint64 newStrike,
        uint64 newPrem,
        uint64 newStart,
        uint64 newExp
    ) external {
        Request storage r = _req[reqId];
        require(r.open, "closed");
        require(msg.sender == r.requester, "own");
        _validateAmounts(1, newStrike, newPrem);
        _validateWindow(newStart, newExp);
        r.strikeAmt = newStrike;
        r.premiumAmt = newPrem;
        r.start = newStart;
        r.expiry = newExp;
        emit RequestModified(reqId);
    }

    function cancelRequests(uint64[] calldata ids) external {
        require(ids.length <= MAX_BATCH, "batch");
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
    ) external nonReentrant returns (uint64 optionId) {
        optionId = _accept(reqId, msg.sender);
    }

    function acceptRequests(uint64[] calldata ids) external nonReentrant {
        require(ids.length <= MAX_BATCH, "batch");
        for (uint i; i < ids.length; ++i) _accept(ids[i], msg.sender);
    }

    /*───────────────────  acceptRequest (internal)  ─────────────*/
    function _accept(
        uint64 reqId,
        address maker
    ) internal returns (uint64 optionId) {
        Request storage r = _req[reqId];
        require(r.open, "closed");

        // 1️⃣ collect premium first (blocks requester griefing)
        if (r.premiumAmt > 0) {
            r.feeTok.safeTransferFrom(r.requester, maker, r.premiumAmt);
        }

        // 2️⃣ pull collateral from the writer
        r.reserve.safeTransferFrom(maker, address(this), r.reserveAmt);

        // 3️⃣ mint option token — remainingAmt starts equal to reserveAmt
        optionId = _createOption(
            maker,
            r.requester,
            r.reserve,
            r.tradeFor,
            r.feeTok,
            r.reserveAmt, // reserveAmt
            r.strikeAmt, // strikeAmt
            r.reserveAmt, // remainingAmt  ← NEW PARAM
            r.premiumAmt,
            r.start,
            r.expiry,
            true // purchased_
        );

        r.open = false;
        emit RequestMatched(reqId, optionId, maker);
    }

    /*╔═══════════  Views  ═══════════════════╗*/
    function optionCount() external view returns (uint256) {
        return _opt.length;
    }

    function requestCount() external view returns (uint256) {
        return _req.length;
    }

    function optionInfo(uint64 id) external view returns (Option memory o) {
        o = _opt[id];              // storage-to-memory copy (>=0.8.18)
    }

    function requestInfo(
        uint64 id
    )
        external
        view
        returns (
            address requester,
            address reserve,
            address tradeFor,
            address feeTok,
            uint64 reserveAmt,
            uint64 strikeAmt,
            uint64 premiumAmt,
            uint64 start,
            uint64 expiry,
            bool open
        )
    {
        Request storage r = _req[id];
        requester = r.requester;
        reserve = address(r.reserve);
        tradeFor = address(r.tradeFor);
        feeTok = address(r.feeTok);
        reserveAmt = r.reserveAmt;
        strikeAmt = r.strikeAmt;
        premiumAmt = r.premiumAmt;
        start = r.start;
        expiry = r.expiry;
        open = r.open;
    }

    function exists(uint64 id) external view returns (bool) {
        return _exists[id];
    }

    /*╔═══════════  Internal utils  ═══════════╗*/
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 id
    ) internal view {
        if (from != address(0) && to != address(0))
            require((_opt[id].flags & F_PLEDGED) == 0, "pledged"); // CHANGED
    }

    function _createOption(
        address maker,
        address holder,
        IZRC20 reserve,
        IZRC20 tradeFor,
        IZRC20 feeTok,
        uint64  reserveAmt,
        uint64  strikeAmt,
        uint64  remainingAmt,
        uint64  premiumAmt,
        uint64  start,
        uint64  expiry,
        bool    purchased_
    ) internal returns (uint64 id) {
        require(_opt.length < type(uint64).max, "id64");

        id = uint64(_opt.length);
        _opt.push();                             // expand array first
        Option storage o = _opt[id];             // storage pointer

        o.maker        = maker;
        o.reserve      = reserve;
        o.tradeFor     = tradeFor;
        o.feeTok       = feeTok;
        o.reserveAmt   = reserveAmt;
        o.strikeAmt    = strikeAmt;
        o.remainingAmt = remainingAmt;
        o.premiumAmt   = premiumAmt;
        o.start        = start;
        o.expiry       = expiry;
        o.flags        = purchased_ ? F_PURCHASED : uint8(0);

        _mint(holder, id);
        if (purchased_) emit Purchased(id, holder);
    }

    function _validateAmounts(
        uint64 reserveAmt,
        uint64 strikeAmt,
        uint64 /* premiumAmt */
    ) private pure {
        require(reserveAmt > 0 && strikeAmt > 0, "zero");
        // premium may be zero
    }

    function _validateWindow(uint64 start, uint64 expiry) private view {
        require(start >= block.timestamp, "startPast"); // allow “now”
        require(expiry > start, "window");
        require(expiry > block.timestamp, "expiryPast");
    }

    function _validateTokens(
        IZRC20 reserve,
        IZRC20 tradeFor,
        IZRC20 feeTok
    ) private view {
        require(
            address(reserve) != address(0) &&
                address(tradeFor) != address(0) &&
                address(feeTok) != address(0),
            "tok0"
        );
        require(address(reserve).code.length != 0, "reserve!code");
        require(address(tradeFor).code.length != 0, "trade!code");
        require(address(feeTok).code.length != 0, "fee!code");
    }

    function _toString(uint256 x) private pure returns (string memory) {
        if (x == 0) return "0";
        uint256 j = x;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory b = new bytes(len);
        uint256 k = len;
        while (x != 0) {
            k--;
            b[k] = bytes1(uint8(48 + (x % 10)));
            x /= 10;
        }
        return string(b);
    }
}
