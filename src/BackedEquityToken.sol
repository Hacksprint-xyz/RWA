// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { FunctionsClient } from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import { ConfirmedOwner } from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IPriceFeed, PriceFeedLib } from "./libraries/PriceFeedLib.sol";

/**
 * @title BackedEquityToken
 * @notice An ERC-20 that represents shares of one equity held at an off-chain brokerage.
 *
 * Flow
 *  - Minting is owner-only. The owner asks an off-chain job (Chainlink Functions) for the brokerage portfolio
 *    value; tokens are only minted if the portfolio covers the new supply at `COLLATERAL_RATIO`.
 *  - Redeeming is open to every holder. Tokens are burned, an off-chain job sells the shares and delivers the
 *    redemption coin to this contract, and the holder then calls `withdraw()`.
 *  - If a redemption fails off-chain (response of 0 / error), the burned tokens are re-minted to the holder.
 *
 * @dev Educational code. Not audited.
 */
contract BackedEquityToken is FunctionsClient, ConfirmedOwner, ERC20, Pausable {
    using FunctionsRequest for FunctionsRequest.Request;
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for address;

    /*//////////////////////////////////////////////////////////////
                              TYPES / ERRORS
    //////////////////////////////////////////////////////////////*/
    error BackedEquityToken__NotEnoughCollateral();
    error BackedEquityToken__BelowMinimumRedemption();
    error BackedEquityToken__NothingToWithdraw();
    error BackedEquityToken__UnknownRequest(bytes32 requestId);

    enum RequestKind {
        Mint,
        Redeem
    }

    struct PendingRequest {
        uint256 amount; // tokens to mint, or tokens that were burned for a redemption
        address requester;
        RequestKind kind;
        uint256 expectedPayout; // redemption only: max payout in redemption-coin units
    }

    struct Config {
        uint64 subscriptionId;
        address functionsRouter;
        bytes32 donId;
        address equityFeed; // equity / USD
        address redemptionCoinFeed; // redemption coin / USD
        address redemptionCoin;
        uint64 secretVersion;
        uint8 secretSlot;
        uint256 maxPriceAge; // seconds
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant WAD = 1e18;

    uint256 public constant COLLATERAL_RATIO = 200; // 200%
    uint256 public constant COLLATERAL_PRECISION = 100;
    /// @notice Smallest redemption, valued in redemption coin with 18 decimals. Match your brokerage's minimum
    ///         withdrawal size.
    uint256 public constant MIN_REDEMPTION_WAD = 100e18;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    uint64 private immutable i_subscriptionId;
    bytes32 private immutable i_donId;
    IPriceFeed private immutable i_equityFeed;
    IPriceFeed private immutable i_redemptionCoinFeed;
    IERC20 private immutable i_redemptionCoin;
    uint8 private immutable i_redemptionCoinDecimals;
    uint256 private immutable i_maxPriceAge;

    string private s_mintSource;
    string private s_redeemSource;
    uint64 private s_secretVersion;
    uint8 private s_secretSlot;

    uint256 private s_portfolioBalance; // USD, 18 decimals
    uint256 private s_pendingMint; // tokens requested but not yet minted
    IPriceFeed private s_reserveFeed; // optional proof-of-reserve feed (USD, any decimals); zero = disabled

    mapping(bytes32 requestId => PendingRequest request) private s_requests;
    mapping(address user => uint256 amount) private s_withdrawable; // redemption-coin units

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event MintRequested(bytes32 indexed requestId, uint256 amount);
    event RedeemRequested(bytes32 indexed requestId, address indexed user, uint256 amount, uint256 expectedPayout);
    event PortfolioBalanceUpdated(uint256 balanceWad);
    event Minted(bytes32 indexed requestId, address indexed to, uint256 amount);
    event MintRejected(bytes32 indexed requestId, uint256 amount);
    event RedemptionReady(bytes32 indexed requestId, address indexed user, uint256 payout);
    event RedemptionRefunded(bytes32 indexed requestId, address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event ReserveFeedSet(address indexed feed);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        string memory name_,
        string memory symbol_,
        Config memory cfg,
        string memory mintSource,
        string memory redeemSource
    )
        FunctionsClient(cfg.functionsRouter)
        ConfirmedOwner(msg.sender)
        ERC20(name_, symbol_)
    {
        i_subscriptionId = cfg.subscriptionId;
        i_donId = cfg.donId;
        i_equityFeed = IPriceFeed(cfg.equityFeed);
        i_redemptionCoinFeed = IPriceFeed(cfg.redemptionCoinFeed);
        i_redemptionCoin = IERC20(cfg.redemptionCoin);
        i_redemptionCoinDecimals = IERC20Metadata(cfg.redemptionCoin).decimals();
        i_maxPriceAge = cfg.maxPriceAge;

        s_secretVersion = cfg.secretVersion;
        s_secretSlot = cfg.secretSlot;
        s_mintSource = mintSource;
        s_redeemSource = redeemSource;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/
    function setSecrets(uint64 secretVersion, uint8 secretSlot) external onlyOwner {
        s_secretVersion = secretVersion;
        s_secretSlot = secretSlot;
    }

    function setSources(string calldata mintSource, string calldata redeemSource) external onlyOwner {
        s_mintSource = mintSource;
        s_redeemSource = redeemSource;
    }

    /**
     * @notice Set (or clear with address(0)) an independent proof-of-reserve feed. When set, a mint also
     *         needs the attested reserves to cover the new supply at `COLLATERAL_RATIO`, on top of the
     *         brokerage balance reported by the off-chain job. A stale or non-positive reserve answer
     *         blocks minting (redemptions are unaffected) until the feed recovers.
     */
    function setReserveFeed(address feed) external onlyOwner {
        s_reserveFeed = IPriceFeed(feed);
        emit ReserveFeedSet(feed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Ask the off-chain job for the portfolio value and (if `amount > 0`) mint `amount` tokens to the
     *         owner once the value is confirmed. Pass 0 to only refresh the stored portfolio balance.
     */
    function sendMintRequest(uint256 amount) external onlyOwner whenNotPaused returns (bytes32 requestId) {
        if (amount != 0) {
            // Count tokens that are already waiting to be minted, otherwise parallel requests could over-mint.
            if (!_isCovered(totalSupply() + s_pendingMint + amount)) {
                revert BackedEquityToken__NotEnoughCollateral();
            }
            s_pendingMint += amount;
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSource);
        req.addDONHostedSecrets(s_secretSlot, s_secretVersion);

        requestId = _sendRequest(req.encodeCBOR(), i_subscriptionId, CALLBACK_GAS_LIMIT, i_donId);
        s_requests[requestId] = PendingRequest(amount, msg.sender, RequestKind.Mint, 0);
        emit MintRequested(requestId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Burn `amount` tokens and ask the off-chain job to sell the equivalent shares for the redemption
     *         coin. Once the job reports back, call `withdraw()`.
     */
    function sendRedeemRequest(uint256 amount) external whenNotPaused returns (bytes32 requestId) {
        uint256 payoutWad = getRedemptionCoinValueOfUsd(getUsdValueOfEquity(amount));
        if (payoutWad < MIN_REDEMPTION_WAD) revert BackedEquityToken__BelowMinimumRedemption();
        uint256 expectedPayout = _fromWad(payoutWad);

        // Burn first: reverts early if the caller lacks the balance, and prevents re-use of the tokens.
        _burn(msg.sender, amount);

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSource);
        req.addDONHostedSecrets(s_secretSlot, s_secretVersion);
        string[] memory args = new string[](4);
        args[0] = amount.toString(); // tokens burned, 18 decimals
        args[1] = expectedPayout.toString(); // payout in redemption-coin units
        args[2] = uint256(i_redemptionCoinDecimals).toString();
        args[3] = address(this).toHexString(); // where the coin must be delivered
        req.setArgs(args);

        requestId = _sendRequest(req.encodeCBOR(), i_subscriptionId, CALLBACK_GAS_LIMIT, i_donId);
        s_requests[requestId] = PendingRequest(amount, msg.sender, RequestKind.Redeem, expectedPayout);
        emit RedeemRequested(requestId, msg.sender, amount, expectedPayout);
    }

    function withdraw() external whenNotPaused {
        uint256 amount = s_withdrawable[msg.sender];
        if (amount == 0) revert BackedEquityToken__NothingToWithdraw();
        s_withdrawable[msg.sender] = 0;
        i_redemptionCoin.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           FUNCTIONS CALLBACK
    //////////////////////////////////////////////////////////////*/
    /// @dev Deliberately not `whenNotPaused`: a reverting callback would lose the response for good.
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        PendingRequest memory request = s_requests[requestId];
        if (request.requester == address(0)) revert BackedEquityToken__UnknownRequest(requestId);
        delete s_requests[requestId]; // each request can be settled once

        bool ok = err.length == 0 && response.length == 32;
        uint256 value = ok ? abi.decode(response, (uint256)) : 0;

        if (request.kind == RequestKind.Mint) {
            _settleMint(requestId, request, ok, value);
        } else {
            _settleRedeem(requestId, request, value);
        }
    }

    function _settleMint(bytes32 requestId, PendingRequest memory request, bool ok, uint256 balanceWad) private {
        s_pendingMint -= request.amount;
        if (ok) {
            s_portfolioBalance = balanceWad;
            emit PortfolioBalanceUpdated(balanceWad);
        }
        if (request.amount == 0) return;

        if (!ok || !_coveredOrFalse(totalSupply() + request.amount)) {
            emit MintRejected(requestId, request.amount);
            return;
        }
        _mint(request.requester, request.amount);
        emit Minted(requestId, request.requester, request.amount);
    }

    /// @param payout redemption-coin units actually delivered to this contract by the off-chain job
    function _settleRedeem(bytes32 requestId, PendingRequest memory request, uint256 payout) private {
        if (payout == 0) {
            // The sale failed off-chain: give the holder their tokens back.
            _mint(request.requester, request.amount);
            emit RedemptionRefunded(requestId, request.requester, request.amount);
            return;
        }
        if (payout > request.expectedPayout) payout = request.expectedPayout; // never credit more than quoted
        s_withdrawable[request.requester] += payout;
        emit RedemptionReady(requestId, request.requester, payout);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    function _requiredBalance(uint256 totalTokens) private view returns (uint256) {
        return (getUsdValueOfEquity(totalTokens) * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    /// @dev Never reverts: a stale or broken feed at settlement time rejects the mint instead of leaving the
    ///      request (and `s_pendingMint`) stuck forever.
    function _coveredOrFalse(uint256 totalTokens) private view returns (bool covered) {
        try this.isCovered(totalTokens) returns (bool result) {
            covered = result;
        } catch {
            covered = false;
        }
    }

    /// @dev True when both the reported brokerage balance and (if configured) the attested reserves cover
    ///      `totalTokens` at the required ratio.
    function _isCovered(uint256 totalTokens) private view returns (bool) {
        uint256 required = _requiredBalance(totalTokens);
        if (required > s_portfolioBalance) return false;
        IPriceFeed reserveFeed = s_reserveFeed;
        if (address(reserveFeed) != address(0)) {
            if (required > PriceFeedLib.latestPrice(reserveFeed, i_maxPriceAge)) return false;
        }
        return true;
    }

    function _fromWad(uint256 amountWad) private view returns (uint256) {
        uint8 d = i_redemptionCoinDecimals;
        if (d == 18) return amountWad;
        if (d < 18) return amountWad / 10 ** (18 - d);
        return amountWad * 10 ** (d - 18);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW / PURE
    //////////////////////////////////////////////////////////////*/
    /// @notice Equity price in USD, 18 decimals.
    function getEquityPrice() public view returns (uint256) {
        return PriceFeedLib.latestPrice(i_equityFeed, i_maxPriceAge);
    }

    /// @notice Redemption coin price in USD, 18 decimals.
    function getRedemptionCoinPrice() public view returns (uint256) {
        return PriceFeedLib.latestPrice(i_redemptionCoinFeed, i_maxPriceAge);
    }

    function getUsdValueOfEquity(uint256 tokenAmount) public view returns (uint256) {
        return (tokenAmount * getEquityPrice()) / WAD;
    }

    /// @param usdAmount USD value, 18 decimals
    /// @return redemption-coin amount, 18 decimals
    function getRedemptionCoinValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * WAD) / getRedemptionCoinPrice();
    }

    function getPortfolioBalance() external view returns (uint256) {
        return s_portfolioBalance;
    }

    /// @notice Whether `totalTokens` of supply would be covered right now. Reverts on a stale feed.
    function isCovered(uint256 totalTokens) external view returns (bool) {
        return _isCovered(totalTokens);
    }

    function getReserveFeed() external view returns (address) {
        return address(s_reserveFeed);
    }

    function getPendingMint() external view returns (uint256) {
        return s_pendingMint;
    }

    function getRequest(bytes32 requestId) external view returns (PendingRequest memory) {
        return s_requests[requestId];
    }

    function getWithdrawableAmount(address user) external view returns (uint256) {
        return s_withdrawable[user];
    }

    function getRedemptionCoin() external view returns (address) {
        return address(i_redemptionCoin);
    }
}
