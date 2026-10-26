// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { BackedEquityToken } from "../src/BackedEquityToken.sol";
import { PriceFeedLib } from "../src/libraries/PriceFeedLib.sol";
import { MockPriceFeed, MockCoin, MockFunctionsRouter } from "./mocks/Mocks.sol";

contract BackedEquityTokenTest is Test {
    BackedEquityToken token;
    MockFunctionsRouter router;
    MockPriceFeed equityFeed;
    MockPriceFeed coinFeed;
    MockCoin coin;

    address owner = address(this);
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_000_000);
        router = new MockFunctionsRouter();
        equityFeed = new MockPriceFeed(8, 250e8); // $250
        coinFeed = new MockPriceFeed(8, 1e8); // $1
        coin = new MockCoin(6);

        BackedEquityToken.Config memory cfg = BackedEquityToken.Config({
            subscriptionId: 1,
            functionsRouter: address(router),
            donId: bytes32("don"),
            equityFeed: address(equityFeed),
            redemptionCoinFeed: address(coinFeed),
            redemptionCoin: address(coin),
            secretVersion: 1,
            secretSlot: 0,
            maxPriceAge: 1 days
        });
        token = new BackedEquityToken("Backed Equity", "bEQ", cfg, "return 1", "return 1");
    }

    /// refresh the stored portfolio balance through the mint path
    function _setPortfolio(uint256 balanceWad) internal {
        bytes32 id = token.sendMintRequest(0);
        router.fulfill(address(token), id, abi.encode(balanceWad), "");
    }

    function _mintTo(address who, uint256 amount, uint256 portfolio) internal {
        bytes32 id = token.sendMintRequest(amount);
        router.fulfill(address(token), id, abi.encode(portfolio), "");
        if (who != owner) token.transfer(who, amount);
    }

    function test_refreshUpdatesPortfolio() public {
        _setPortfolio(1_000e18);
        assertEq(token.getPortfolioBalance(), 1_000e18);
    }

    function test_mintRevertsWithoutCollateral() public {
        _setPortfolio(100e18); // 1 token needs $500
        vm.expectRevert(BackedEquityToken.BackedEquityToken__NotEnoughCollateral.selector);
        token.sendMintRequest(1e18);
    }

    function test_mintWithEnoughCollateral() public {
        _setPortfolio(1_000e18);
        _mintTo(owner, 2e18, 1_000e18); // $500 supply * 200% = $1000
        assertEq(token.balanceOf(owner), 2e18);
        assertEq(token.getPendingMint(), 0);
    }

    function test_parallelMintRequestsCannotOverMint() public {
        _setPortfolio(1_000e18);
        token.sendMintRequest(2e18);
        vm.expectRevert(BackedEquityToken.BackedEquityToken__NotEnoughCollateral.selector);
        token.sendMintRequest(1e18);
    }

    function test_mintRejectedWhenPortfolioDropped() public {
        _setPortfolio(1_000e18);
        bytes32 id = token.sendMintRequest(2e18);
        router.fulfill(address(token), id, abi.encode(uint256(400e18)), "");
        assertEq(token.totalSupply(), 0);
        assertEq(token.getPortfolioBalance(), 400e18);
        assertEq(token.getPendingMint(), 0);
    }

    function test_unknownOrRepeatedFulfillmentReverts() public {
        _setPortfolio(1_000e18);
        bytes32 id = token.sendMintRequest(1e18);
        router.fulfill(address(token), id, abi.encode(uint256(1_000e18)), "");
        vm.expectRevert(abi.encodeWithSelector(BackedEquityToken.BackedEquityToken__UnknownRequest.selector, id));
        router.fulfill(address(token), id, abi.encode(uint256(1_000e18)), "");
    }

    function test_redeemHappyPath() public {
        _setPortfolio(1_000e18);
        _mintTo(alice, 2e18, 1_000e18);
        coin.mint(address(token), 500e6); // brokerage delivered the coin

        vm.prank(alice);
        bytes32 id = token.sendRedeemRequest(1e18); // $250 -> 250 coin
        assertEq(token.balanceOf(alice), 1e18); // burned immediately

        router.fulfill(address(token), id, abi.encode(uint256(250e6)), "");
        assertEq(token.getWithdrawableAmount(alice), 250e6);

        vm.prank(alice);
        token.withdraw();
        assertEq(coin.balanceOf(alice), 250e6);
        assertEq(token.getWithdrawableAmount(alice), 0);
    }

    function test_redeemPayoutIsCappedAtQuote() public {
        _setPortfolio(1_000e18);
        _mintTo(alice, 2e18, 1_000e18);
        vm.prank(alice);
        bytes32 id = token.sendRedeemRequest(1e18);
        router.fulfill(address(token), id, abi.encode(uint256(9_999e6)), "");
        assertEq(token.getWithdrawableAmount(alice), 250e6);
    }

    function test_failedRedeemRefundsTokens() public {
        _setPortfolio(1_000e18);
        _mintTo(alice, 2e18, 1_000e18);
        vm.prank(alice);
        bytes32 id = token.sendRedeemRequest(1e18);
        router.fulfill(address(token), id, abi.encode(uint256(0)), "");
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.getWithdrawableAmount(alice), 0);
    }

    function test_erroredResponseRefundsTokens() public {
        _setPortfolio(1_000e18);
        _mintTo(alice, 2e18, 1_000e18);
        vm.prank(alice);
        bytes32 id = token.sendRedeemRequest(1e18);
        router.fulfill(address(token), id, "", "boom");
        assertEq(token.balanceOf(alice), 2e18);
    }

    function test_redeemBelowMinimumReverts() public {
        _setPortfolio(1_000e18);
        _mintTo(alice, 2e18, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(BackedEquityToken.BackedEquityToken__BelowMinimumRedemption.selector);
        token.sendRedeemRequest(0.1e18); // $25
    }

    function test_withdrawWithNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(BackedEquityToken.BackedEquityToken__NothingToWithdraw.selector);
        token.withdraw();
    }

    function test_onlyOwnerMints() public {
        vm.prank(alice);
        vm.expectRevert();
        token.sendMintRequest(1e18);
    }

    function test_stalePriceReverts() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PriceFeedLib.PriceFeedLib__StalePrice.selector);
        token.getEquityPrice();
    }

    function test_nonPositivePriceReverts() public {
        equityFeed.update(0);
        vm.expectRevert(PriceFeedLib.PriceFeedLib__InvalidPrice.selector);
        token.getEquityPrice();
    }

    function test_pauseBlocksRequests() public {
        token.pause();
        vm.expectRevert();
        token.sendMintRequest(0);
    }

    /*//////////////////////////////////////////////////////////////
                             PROOF OF RESERVE
    //////////////////////////////////////////////////////////////*/
    function test_reserveFeedBlocksMintRequest() public {
        _setPortfolio(1_000e18);
        MockPriceFeed reserves = new MockPriceFeed(18, 400e18); // attests only $400
        token.setReserveFeed(address(reserves));
        vm.expectRevert(BackedEquityToken.BackedEquityToken__NotEnoughCollateral.selector);
        token.sendMintRequest(2e18); // needs $1000
    }

    function test_reserveFeedAllowsMintWhenCovered() public {
        _setPortfolio(1_000e18);
        MockPriceFeed reserves = new MockPriceFeed(18, 1_000e18);
        token.setReserveFeed(address(reserves));
        _mintTo(owner, 2e18, 1_000e18);
        assertEq(token.balanceOf(owner), 2e18);
    }

    function test_reserveDropAfterRequestRejectsMint() public {
        _setPortfolio(1_000e18);
        MockPriceFeed reserves = new MockPriceFeed(8, 1_000e8); // different decimals are normalised
        token.setReserveFeed(address(reserves));
        bytes32 id = token.sendMintRequest(2e18);
        reserves.update(100e8);
        router.fulfill(address(token), id, abi.encode(uint256(1_000e18)), "");
        assertEq(token.totalSupply(), 0);
        assertEq(token.getPendingMint(), 0);
    }

    function test_staleReserveFeedBlocksMintButNotRedeem() public {
        // Give the portfolio enough headroom that only the stale reserve feed can block the mint
        // (3e18 supply needs $1500 at 200%).
        _setPortfolio(5_000e18);
        MockPriceFeed reserves = new MockPriceFeed(18, 5_000e18);
        _mintTo(alice, 2e18, 5_000e18);
        token.setReserveFeed(address(reserves));

        vm.warp(block.timestamp + 2 days);
        equityFeed.update(250e8);
        coinFeed.update(1e8); // keep the other feeds fresh; only the reserve feed is stale

        vm.expectRevert(PriceFeedLib.PriceFeedLib__StalePrice.selector);
        token.sendMintRequest(1e18);

        vm.prank(alice);
        token.sendRedeemRequest(1e18); // redemption does not read the reserve feed
    }

    function test_onlyOwnerSetsReserveFeed() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setReserveFeed(address(1));
    }

    function test_staleFeedAtSettlementRejectsMintInsteadOfSticking() public {
        _setPortfolio(1_000e18);
        bytes32 id = token.sendMintRequest(2e18);
        vm.warp(block.timestamp + 2 days); // equity feed goes stale before the response arrives
        router.fulfill(address(token), id, abi.encode(uint256(1_000e18)), "");
        assertEq(token.totalSupply(), 0);
        assertEq(token.getPendingMint(), 0);
        assertEq(token.getRequest(id).requester, address(0)); // settled, not stuck
    }
}
