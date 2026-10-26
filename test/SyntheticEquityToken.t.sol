// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { SyntheticEquityToken } from "../src/SyntheticEquityToken.sol";
import { MockPriceFeed } from "./mocks/Mocks.sol";

contract SyntheticEquityTokenTest is Test {
    SyntheticEquityToken token;
    MockPriceFeed equityFeed;
    MockPriceFeed nativeFeed;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_000_000);
        equityFeed = new MockPriceFeed(8, 250e8); // $250
        nativeFeed = new MockPriceFeed(8, 2_000e8); // $2000
        token = new SyntheticEquityToken("Synthetic Equity", "sEQ", address(equityFeed), address(nativeFeed), 1 days);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_mintUpToTwoHundredPercent() public {
        // 1 ETH = $2000 collateral -> $1000 of debt max -> 4 tokens
        vm.prank(alice);
        token.depositAndMint{ value: 1 ether }(4e18);
        assertEq(token.balanceOf(alice), 4e18);
        assertEq(token.getHealthFactor(alice), 1e18);
    }

    function test_mintBeyondLimitReverts() public {
        vm.prank(alice);
        vm.expectRevert(SyntheticEquityToken.SyntheticEquityToken__InsufficientCollateral.selector);
        token.depositAndMint{ value: 1 ether }(4.01e18);
    }

    function test_redeemReturnsCollateralOfEqualValue() public {
        vm.startPrank(alice);
        token.depositAndMint{ value: 1 ether }(2e18);
        uint256 before = alice.balance;
        token.redeemAndBurn(1e18); // $250 / $2000 = 0.125 ETH
        vm.stopPrank();
        assertEq(alice.balance - before, 0.125 ether);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_cannotRedeemMoreThanMinted() public {
        vm.startPrank(alice);
        token.depositAndMint{ value: 1 ether }(4e18);
        vm.expectRevert(); // arithmetic underflow on the position
        token.redeemAndBurn(5e18);
        vm.stopPrank();
    }

    function test_cannotLiquidateHealthyPosition() public {
        vm.prank(alice);
        token.depositAndMint{ value: 1 ether }(2e18);
        vm.prank(bob);
        token.depositAndMint{ value: 10 ether }(5e18);
        vm.prank(bob);
        vm.expectRevert(SyntheticEquityToken.SyntheticEquityToken__PositionHealthy.selector);
        token.liquidate(alice, 1e18);
    }

    function test_liquidationPaysTenPercentBonus() public {
        vm.prank(alice);
        token.depositAndMint{ value: 1 ether }(4e18); // exactly at the limit
        vm.prank(bob);
        token.depositAndMint{ value: 20 ether }(2e18);

        nativeFeed.update(1_000e8); // ETH halves -> alice's health factor 0.5
        assertLt(token.getHealthFactor(alice), 1e18);

        uint256 before = bob.balance;
        vm.prank(bob);
        token.liquidate(alice, 1e18); // $250 / $1000 = 0.25 ETH, +10% = 0.275 ETH

        assertEq(bob.balance - before, 0.275 ether);
        (uint256 minted, uint256 collateral) = token.getPosition(alice);
        assertEq(minted, 3e18);
        assertEq(collateral, 1 ether - 0.275 ether);
    }

    function test_liquidationCapsAtAvailableCollateral() public {
        vm.prank(alice);
        token.depositAndMint{ value: 1 ether }(4e18);
        vm.prank(bob);
        token.depositAndMint{ value: 50 ether }(4e18);

        nativeFeed.update(250e8); // collateral now worth $250 against $1000 of debt
        vm.prank(bob);
        token.liquidate(alice, 4e18);
        (, uint256 collateral) = token.getPosition(alice);
        assertEq(collateral, 0);
    }
}
