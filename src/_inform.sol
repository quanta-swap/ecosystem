// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*───────────────────────────────────────────────────────────────
│  PushNotificationHub (uint64 feed IDs)                       │
│                                                               │
│  • Anyone can create a *feed* (title, description, icon URL,   │
│    and extra link).                                           │
│  • Each feed has its own admin set (1‑of‑N security). Any      │
│    admin may manage admins and metadata.                      │
│  • Users atomically manage subs via manageSubscriptions().    │
│  • Feeds keyed by **uint64** to stay in 64‑bit space.          │
└──────────────────────────────────────────────────────────────*/

/*───────────────────────────────────────────────────────────────
│  IPushNotificationHub (uint64 IDs)                            │
└──────────────────────────────────────────────────────────────*/

interface IPushNotificationHub {
    /*──────── View helpers ────────*/
    function feedCount() external view returns (uint64);

    function feedInfo(uint64 id)
        external
        view
        returns (
            string memory title,
            string memory description,
            string memory icon,
            string memory link,
            uint16 adminCount,
            uint32 subscriberCount
        );

    function isAdmin(uint64 id, address a) external view returns (bool);

    function subscribed(uint64 id, address user) external view returns (bool);

    /*──────── Subscription mgmt ────────*/
    function manageSubscriptions(
        uint64[] calldata removeIds,
        uint64[] calldata addIds
    ) external;

    /*──────── Feed admin ops ────────*/
    function createFeed(
        string calldata title,
        string calldata description,
        string calldata icon,
        string calldata link
    ) external returns (uint64 id);

    function updateFeed(
        uint64 id,
        string calldata title,
        string calldata description,
        string calldata icon,
        string calldata link
    ) external;

    function addAdmin(uint64 id, address newAdmin) external;

    function removeAdmin(uint64 id, address admin) external;

    function swapAdmin(
        uint64 id,
        address oldAdmin,
        address newAdmin
    ) external;

    /*──────── Notifications ────────*/
    function pushNotification(
        uint64[] calldata ids,      // ← many feeds in one shot
        string calldata subject,
        string calldata body,
        string calldata link
    ) external;
}

contract PushNotificationHub is IPushNotificationHub {

    // "Welcome to the Internet!"
    function theme() external pure returns (string memory) {
        return "https://www.youtube.com/watch?v=k1BneeJTDcU";
    }

    /*──────── Feed storage ────────*/
    struct Feed {
        string title;
        string description;
        string icon;
        string link;
        mapping(address => bool) admins;
        uint16 adminCount;
        uint32 subCount;
    }

    uint64 public feedCount;
    mapping(uint64 => Feed) private _feeds;

    /*──────── Subscriptions ────────*/
    mapping(uint64 => mapping(address => bool)) public subscribed;

    /*──────── Events ────────*/
    event FeedCreated(uint64 indexed id, string title, string description, string icon, string link, address indexed creator);
    event FeedUpdated(uint64 indexed id, string title, string description, string icon, string link, address indexed sender);
    event AdminAdded(uint64 indexed id, address indexed admin);
    event AdminRemoved(uint64 indexed id, address indexed admin);
    event AdminSwapped(uint64 indexed id, address indexed oldAdmin, address indexed newAdmin);
    event Subscribed(uint64 indexed id, address indexed user);
    event Unsubscribed(uint64 indexed id, address indexed user);
    event Notification(uint64 indexed id, address indexed sender, string subject, string body, string link);

    /*──────── Modifiers ────────*/
    modifier validFeed(uint64 id) {
        require(id < feedCount, "feed");
        _;
    }
    modifier onlyAdmin(uint64 id) {
        require(_feeds[id].admins[msg.sender], "admin");
        _;
    }

    /*════════ Feed management ════════*/
    function createFeed(
        string calldata title,
        string calldata description,
        string calldata icon,
        string calldata link
    ) external returns (uint64 id) {
        id = feedCount;
        require(id < type(uint64).max, "max");
        feedCount = id + 1;
        Feed storage f = _feeds[id];
        f.title = title;
        f.description = description;
        f.icon = icon;
        f.link = link;
        f.admins[msg.sender] = true;
        f.adminCount = 1;
        emit FeedCreated(id, title, description, icon, link, msg.sender);
    }

    function updateFeed(
        uint64 id,
        string calldata title,
        string calldata description,
        string calldata icon,
        string calldata link
    ) external validFeed(id) onlyAdmin(id) {
        Feed storage f = _feeds[id];
        if (bytes(title).length != 0) f.title = title;
        if (bytes(description).length != 0) f.description = description;
        if (bytes(icon).length != 0) f.icon = icon;
        if (bytes(link).length != 0) f.link = link;
        emit FeedUpdated(id, f.title, f.description, f.icon, f.link, msg.sender);
    }

    /*──────── Admin ops ────────*/
    function addAdmin(uint64 id, address newAdmin)
        external
        validFeed(id)
        onlyAdmin(id)
    {
        require(newAdmin != address(0), "0x0");
        Feed storage f = _feeds[id];
        require(!f.admins[newAdmin], "dup");
        f.admins[newAdmin] = true;
        f.adminCount += 1;
        emit AdminAdded(id, newAdmin);
    }

    function removeAdmin(uint64 id, address admin)
        external
        validFeed(id)
        onlyAdmin(id)
    {
        Feed storage f = _feeds[id];
        require(f.admins[admin], "na");
        require(f.adminCount > 1, "last");
        delete f.admins[admin];
        f.adminCount -= 1;
        emit AdminRemoved(id, admin);
    }

    function swapAdmin(uint64 id, address oldAdmin, address newAdmin)
        external
        validFeed(id)
        onlyAdmin(id)
    {
        Feed storage f = _feeds[id];
        require(f.admins[oldAdmin], "old");
        require(newAdmin != address(0) && !f.admins[newAdmin], "bad");
        delete f.admins[oldAdmin];
        f.admins[newAdmin] = true;
        emit AdminSwapped(id, oldAdmin, newAdmin);
    }

    /*════════ Subscription helpers ════════*/
    function _subscribe(uint64 id, address user) internal {
        require(!subscribed[id][user], "sub");
        subscribed[id][user] = true;
        _feeds[id].subCount += 1;
        emit Subscribed(id, user);
    }

    function _unsubscribe(uint64 id, address user) internal {
        require(subscribed[id][user], "!sub");
        delete subscribed[id][user];
        Feed storage f = _feeds[id];
        require(f.subCount > 0, "ct");
        f.subCount -= 1;
        emit Unsubscribed(id, user);
    }

    /*════════ Unified subscription manager ════════*/
    function manageSubscriptions(uint64[] calldata removeIds, uint64[] calldata addIds) external {
        uint256 lenR = removeIds.length;
        for (uint256 i; i < lenR; ++i) {
            uint64 id = removeIds[i];
            require(id < feedCount, "feed");
            _unsubscribe(id, msg.sender);
        }
        uint256 lenA = addIds.length;
        for (uint256 i; i < lenA; ++i) {
            uint64 id = addIds[i];
            require(id < feedCount, "feed");
            _subscribe(id, msg.sender);
        }
    }

    /*════════ Notifications (multi-feed) ════════*/
    function pushNotification(
        uint64[] calldata ids,
        string calldata subject,
        string calldata body,
        string calldata link
    ) external {
        uint256 len = ids.length;
        for (uint256 i; i < len; ++i) {
            uint64 id = ids[i];
            require(id < feedCount, "feed");                // feed exists
            require(_feeds[id].admins[msg.sender], "admin"); // caller is admin
            emit Notification(id, msg.sender, subject, body, link);
        }
    }

    /*════════ View helpers ════════*/
    function feedInfo(uint64 id)
        external
        view
        validFeed(id)
        returns (
            string memory title,
            string memory description,
            string memory icon,
            string memory link,
            uint16 adminCount,
            uint32 subscriberCount
        )
    {
        Feed storage f = _feeds[id];
        return (f.title, f.description, f.icon, f.link, f.adminCount, f.subCount);
    }

    function isAdmin(uint64 id, address a) external view validFeed(id) returns (bool) {
        return _feeds[id].admins[a];
    }
}
