// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { BackedEquityToken } from "../../src/BackedEquityToken.sol";
import { MockPriceFeed, MockCoin, MockFunctionsRouter } from "../mocks/Mocks.sol";

/// @dev Drives the token through random mint / redeem requests and random off-chain responses, while
///      keeping a ghost ledger the invariants compare against.
contract BackedEquityHandler is Test {
    BackedEquityToken public token;
    MockFunctionsRouter public router;
    MockPriceFeed public equityFeed;

    address public immutable tokenOwner;
    address[] public users;

    bytes32[] public openMints;
    bytes32[] public openRedeems;

    // ghost ledger
    uint256 public ghostMinted; // tokens minted by settled mint requests
    uint256 public ghostBurned; // tokens burned by redeem requests
    uint256 public ghostRefunded; // tokens re-minted by failed redemptions
    uint256 public ghostPendingMint; // sum of unsettled mint request amounts
    uint256 public ghostQuoted; // sum of quotes of settled, successful redemptions
    uint256 public ghostCredited; // what the token actually credited for those
    bool public mintedWithoutCover; // set if a mint ever pushed supply above what the balance supports

    mapping(bytes32 => uint256) private mintAmount;
    mapping(bytes32 => uint256) private redeemAmount;

    constructor(
        BackedEquityToken token_,
        MockFunctionsRouter router_,
        MockPriceFeed equityFeed_,
        address tokenOwner_
    ) {
        token = token_;
        router = router_;
        equityFeed = equityFeed_;
        tokenOwner = tokenOwner_;
        for (uint256 i; i < 3; i++) {
            users.push(makeAddr(string(abi.encodePacked("user", i))));
        }
    }

    function requestMint(uint256 amount) external {
        amount = bound(amount, 0, 50e18);
        vm.prank(tokenOwner);
        try token.sendMintRequest(amount) returns (bytes32 id) {
            openMints.push(id);
            mintAmount[id] = amount;
            ghostPendingMint += amount;
        } catch { }
    }

    function fulfillMint(uint256 index, uint256 reportedBalance) external {
        if (openMints.length == 0) return;
        index = bound(index, 0, openMints.length - 1);
        reportedBalance = bound(reportedBalance, 0, 100_000e18);
        bytes32 id = openMints[index];
        uint256 amount = mintAmount[id];
        _removeMint(index);

        uint256 supplyBefore = token.totalSupply();
        router.fulfill(address(token), id, abi.encode(reportedBalance), "");
        ghostPendingMint -= amount;

        uint256 supplyAfter = token.totalSupply();
        if (supplyAfter > supplyBefore) {
            ghostMinted += supplyAfter - supplyBefore;
            // right after a mint, 200% of the supply's value must fit inside the reported balance
            if ((token.getUsdValueOfEquity(supplyAfter) * 2) > reportedBalance) mintedWithoutCover = true;
        }
    }

    function transferToUser(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 bal = token.balanceOf(tokenOwner);
        if (bal == 0) return;
        vm.prank(tokenOwner);
        token.transfer(user, bound(amount, 0, bal));
    }

    function requestRedeem(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(user);
        try token.sendRedeemRequest(amount) returns (bytes32 id) {
            openRedeems.push(id);
            redeemAmount[id] = amount;
            ghostBurned += amount;
        } catch { }
    }

    /// @param payoutSeed 0 simulates a failed sale; otherwise any payout, including ones above the quote
    function fulfillRedeem(uint256 index, uint256 payoutSeed) external {
        if (openRedeems.length == 0) return;
        index = bound(index, 0, openRedeems.length - 1);
        bytes32 id = openRedeems[index];
        uint256 amount = redeemAmount[id];
        BackedEquityToken.PendingRequest memory req = token.getRequest(id);
        _removeRedeem(index);

        uint256 payout = payoutSeed % 4 == 0 ? 0 : bound(payoutSeed, 1, 1_000_000e6);
        uint256 withdrawableBefore = token.getWithdrawableAmount(req.requester);
        router.fulfill(address(token), id, abi.encode(payout), "");

        if (payout == 0) {
            ghostRefunded += amount;
        } else {
            ghostQuoted += req.expectedPayout;
            ghostCredited += token.getWithdrawableAmount(req.requester) - withdrawableBefore;
        }
    }

    function movePrice(uint256 newPrice) external {
        equityFeed.update(int256(bound(newPrice, 50e8, 1_000e8)));
    }

    function openMintCount() external view returns (uint256) {
        return openMints.length;
    }

    function _removeMint(uint256 i) private {
        openMints[i] = openMints[openMints.length - 1];
        openMints.pop();
    }

    function _removeRedeem(uint256 i) private {
        openRedeems[i] = openRedeems[openRedeems.length - 1];
        openRedeems.pop();
    }
}

contract BackedEquityTokenInvariantTest is StdInvariant, Test {
    BackedEquityToken token;
    BackedEquityHandler handler;
    MockPriceFeed equityFeed;

    function setUp() public {
        vm.warp(1_000_000);
        MockFunctionsRouter router = new MockFunctionsRouter();
        equityFeed = new MockPriceFeed(8, 250e8);
        MockPriceFeed coinFeed = new MockPriceFeed(8, 1e8);
        MockCoin coin = new MockCoin(6);

        BackedEquityToken.Config memory cfg = BackedEquityToken.Config({
            subscriptionId: 1,
            functionsRouter: address(router),
            donId: bytes32("don"),
            equityFeed: address(equityFeed),
            redemptionCoinFeed: address(coinFeed),
            redemptionCoin: address(coin),
            secretVersion: 1,
            secretSlot: 0,
            maxPriceAge: 365 days
        });
        token = new BackedEquityToken("Backed Equity", "bEQ", cfg, "return 1", "return 1");

        // the handler's mint requests must come from the token owner
        handler = new BackedEquityHandler(token, router, equityFeed, address(this));
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BackedEquityHandler.requestMint.selector;
        selectors[1] = BackedEquityHandler.fulfillMint.selector;
        selectors[2] = BackedEquityHandler.transferToUser.selector;
        selectors[3] = BackedEquityHandler.requestRedeem.selector;
        selectors[4] = BackedEquityHandler.fulfillRedeem.selector;
        selectors[5] = BackedEquityHandler.movePrice.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// supply always equals what was minted, minus what redemptions burned, plus what failed redemptions refunded
    function invariant_supplyMatchesLedger() public view {
        assertEq(
            token.totalSupply(), handler.ghostMinted() + handler.ghostRefunded() - handler.ghostBurned()
        );
    }

    /// tokens waiting to be minted are exactly the open mint requests
    function invariant_pendingMintMatchesOpenRequests() public view {
        assertEq(token.getPendingMint(), handler.ghostPendingMint());
    }

    /// a mint never leaves the supply above what the reported balance supports at 200%
    function invariant_neverMintedWithoutCover() public view {
        assertFalse(handler.mintedWithoutCover());
    }

    /// the contract never credits holders more than the quotes it issued
    function invariant_creditedNeverExceedsQuoted() public view {
        assertLe(handler.ghostCredited(), handler.ghostQuoted());
    }
}
