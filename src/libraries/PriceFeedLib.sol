// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Minimal price-feed interface (compatible with the common aggregator ABI).
interface IPriceFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Reads a price feed, rejects stale / non-positive answers and normalises to 18 decimals.
library PriceFeedLib {
    error PriceFeedLib__StalePrice();
    error PriceFeedLib__InvalidPrice();

    /// @param feed    the feed to read
    /// @param maxAge  maximum accepted age of the answer in seconds. Equity feeds only update during market
    ///                hours, so choose this deliberately instead of reusing a crypto-style heartbeat.
    /// @return priceWad the price scaled to 18 decimals
    function latestPrice(IPriceFeed feed, uint256 maxAge) internal view returns (uint256 priceWad) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
            revert PriceFeedLib__StalePrice();
        }
        if (block.timestamp - updatedAt > maxAge) revert PriceFeedLib__StalePrice();
        if (answer <= 0) revert PriceFeedLib__InvalidPrice();

        uint8 feedDecimals = feed.decimals();
        if (feedDecimals <= 18) {
            priceWad = uint256(answer) * 10 ** (18 - feedDecimals);
        } else {
            priceWad = uint256(answer) / 10 ** (feedDecimals - 18);
        }
    }
}
