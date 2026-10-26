// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPriceFeed, PriceFeedLib } from "./libraries/PriceFeedLib.sol";

/**
 * @title SyntheticEquityToken
 * @notice A synthetic token that tracks an equity price using the chain's native asset as collateral.
 *         Works like an over-collateralised stablecoin: deposit native currency, mint against it, stay above
 *         a 200% collateral ratio or be liquidated at a 10% bonus.
 *
 * @dev Educational code. Not audited. No protocol fee, no interest, no bad-debt handling.
 */
contract SyntheticEquityToken is ERC20, ReentrancyGuard {
    error SyntheticEquityToken__InsufficientCollateral();
    error SyntheticEquityToken__PositionHealthy();
    error SyntheticEquityToken__ZeroAmount();
    error SyntheticEquityToken__TransferFailed();

    event Deposited(address indexed user, uint256 collateral, uint256 minted);
    event Redeemed(address indexed user, uint256 burned, uint256 collateralReturned);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtCovered, uint256 collateralSeized);

    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // collateral counts at 50% => 200% ratio
    uint256 private constant LIQUIDATION_BONUS = 10; // liquidators receive 10% extra collateral
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    IPriceFeed private immutable i_equityFeed; // equity / USD
    IPriceFeed private immutable i_nativeFeed; // native asset / USD
    uint256 private immutable i_maxPriceAge;

    mapping(address user => uint256 amount) private s_minted;
    mapping(address user => uint256 amount) private s_collateral;

    constructor(
        string memory name_,
        string memory symbol_,
        address equityFeed,
        address nativeFeed,
        uint256 maxPriceAge
    )
        ERC20(name_, symbol_)
    {
        i_equityFeed = IPriceFeed(equityFeed);
        i_nativeFeed = IPriceFeed(nativeFeed);
        i_maxPriceAge = maxPriceAge;
    }

    /*//////////////////////////////////////////////////////////////
                              EXTERNAL
    //////////////////////////////////////////////////////////////*/
    /// @notice Deposit `msg.value` as collateral and mint `amountToMint` tokens (either may be zero, not both).
    function depositAndMint(uint256 amountToMint) external payable {
        if (msg.value == 0 && amountToMint == 0) revert SyntheticEquityToken__ZeroAmount();

        s_collateral[msg.sender] += msg.value;
        s_minted[msg.sender] += amountToMint;
        _revertIfUnhealthy(msg.sender);

        if (amountToMint != 0) _mint(msg.sender, amountToMint);
        emit Deposited(msg.sender, msg.value, amountToMint);
    }

    /// @notice Burn `amount` tokens and take back collateral worth the same USD value.
    function redeemAndBurn(uint256 amount) external nonReentrant {
        if (amount == 0) revert SyntheticEquityToken__ZeroAmount();

        uint256 collateralOut = getNativeAmountFromUsd(getUsdValueOfSynthetic(amount));
        s_minted[msg.sender] -= amount;
        s_collateral[msg.sender] -= collateralOut;
        _revertIfUnhealthy(msg.sender);

        _burn(msg.sender, amount);
        _sendNative(msg.sender, collateralOut);
        emit Redeemed(msg.sender, amount, collateralOut);
    }

    /// @notice Repay `debtToCover` of an unhealthy position with your own tokens and receive its collateral
    ///         at a 10% discount.
    function liquidate(address user, uint256 debtToCover) external nonReentrant {
        if (debtToCover == 0) revert SyntheticEquityToken__ZeroAmount();
        if (getHealthFactor(user) >= MIN_HEALTH_FACTOR) revert SyntheticEquityToken__PositionHealthy();

        uint256 base = getNativeAmountFromUsd(getUsdValueOfSynthetic(debtToCover));
        uint256 seized = base + (base * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 available = s_collateral[user];
        if (seized > available) seized = available; // under-water position: take what is left

        s_minted[user] -= debtToCover; // reverts if more than the user's debt
        s_collateral[user] = available - seized;

        _burn(msg.sender, debtToCover);
        _sendNative(msg.sender, seized);
        emit Liquidated(user, msg.sender, debtToCover, seized);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW / PURE
    //////////////////////////////////////////////////////////////*/
    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debtUsd = getUsdValueOfSynthetic(s_minted[user]);
        if (debtUsd == 0) return type(uint256).max;
        uint256 collateralUsd = getUsdValueOfNative(s_collateral[user]);
        uint256 adjusted = (collateralUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (adjusted * PRECISION) / debtUsd;
    }

    /// @return USD value, 18 decimals
    function getUsdValueOfSynthetic(uint256 amount) public view returns (uint256) {
        return (amount * PriceFeedLib.latestPrice(i_equityFeed, i_maxPriceAge)) / PRECISION;
    }

    /// @return USD value, 18 decimals
    function getUsdValueOfNative(uint256 amountWei) public view returns (uint256) {
        return (amountWei * PriceFeedLib.latestPrice(i_nativeFeed, i_maxPriceAge)) / PRECISION;
    }

    /// @param usdAmount USD value, 18 decimals
    /// @return amount of native currency in wei
    function getNativeAmountFromUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * PRECISION) / PriceFeedLib.latestPrice(i_nativeFeed, i_maxPriceAge);
    }

    function getPosition(address user) external view returns (uint256 minted, uint256 collateral) {
        return (s_minted[user], s_collateral[user]);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/
    function _revertIfUnhealthy(address user) private view {
        if (getHealthFactor(user) < MIN_HEALTH_FACTOR) revert SyntheticEquityToken__InsufficientCollateral();
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert SyntheticEquityToken__TransferFailed();
    }
}
