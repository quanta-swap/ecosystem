// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/Test.sol";
import "../src/_option.sol";
import {MockZRC20} from "./mocks/MockZRC20.sol";

/* happy-path for buyOptions[] and acceptRequests[] with MAX_BATCH items */
contract OptionDeskBatch is Test {
    AmeriPeanOptionDesk desk;
    MockZRC20 r; MockZRC20 q; MockZRC20 f;
    address w = address(0x111); address b = address(0x222);

    function setUp() public {
        desk = new AmeriPeanOptionDesk();
        r = new MockZRC20("R","R"); q = new MockZRC20("Q","Q"); f = new MockZRC20("F","F");
        r.mint(w, 10_000_000);
        q.mint(b, 10_000_000);
        f.mint(b, 10_000_000);
    }

    function testBatchBuyOptions() public {
        uint256 n = desk.MAX_BATCH();          // 50
        uint64[] memory ids = new uint64[](n);

        /* writer posts 50 small options */
        vm.startPrank(w);
        r.approve(address(desk), uint64(n*10));
        for (uint64 i; i < n; ++i) {
            ids[i] = desk.postOption(r,q,f,10,5,1,
                                     uint64(block.timestamp),
                                     uint64(block.timestamp+7 days));
        }
        vm.stopPrank();

        /* buyer purchases all 50 in one call */
        vm.startPrank(b);
        f.approve(address(desk), uint64(n));
        desk.buyOptions(ids);                   // must pass
        vm.stopPrank();
    }

    function testBatchAcceptRequests() public {
        uint256 n = desk.MAX_BATCH();
        uint64[] memory reqIds = new uint64[](n);

        /* requester files 50 RFQs */
        vm.startPrank(b);
        f.approve(address(desk), uint64(n));
        for (uint64 i; i < n; ++i) {
            reqIds[i] = desk.postRequest(r,q,f,10,5,1,
                                         uint64(block.timestamp),
                                         uint64(block.timestamp+7 days),
                                         0);
        }
        vm.stopPrank();

        /* maker accepts all in one call */
        vm.startPrank(w);
        r.approve(address(desk), uint64(n*10));
        desk.acceptRequests(reqIds);            // must pass
        vm.stopPrank();
    }
}
