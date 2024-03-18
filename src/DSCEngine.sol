// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { DecentralizedStableCoin } from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
// import { aggregatorv3interface } from "@chainlink/contracts/src/v0.8/interfaces/aggregatorv3interface.sol";
// import { erc20mock } from "@openzeppelin/contracts/mocks/token/erc20mock.sol";
import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author akamaitrue
 *
 * The system is designed to have the tokens maintain a 1:1 peg, i.e. 1 DSC token == $1
 * The DSC stablecoin has the following properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * The DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
*/

contract DSCEngine is ReentrancyGuard {

  ////////////////
  /// Errors ////
  ///////////////
  error DSCEngine__NeedsMoreThanZero();
  error DSCEngine__TokenNotAllowed();
  error DSCEngine__TransferFailed();
  error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
  error DSCEngine__HealthFactorTooLow(uint256 healthFactor);
  error DSCEngine__MintFailed();
  error DSCEngine__HealthFactorOK();
  error DSCEngine__HealthFactorNotImproved();

  ////////////
  // Types //
  ///////////
  using OracleLib for AggregatorV3Interface;

  //////////////////////
  // State Variables //
  /////////////////////
  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant FEED_PRECISION = 1e8;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
  uint256 private constant LIQUIDATION_PRECISION = 100;
  uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
  uint256 private constant MIN_HEALTH_FACTOR = 1e18;

  mapping(address token => address priceFeed) private s_priceFeed;  // named mapping
  /// @dev amount of collateral deposited by user
  mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
  mapping(address user => uint256 amountDSCMinted) private s_dscMinted;
  /// @dev if we knew exactly how many tokens we have, we could make this immutable
  address[] private s_collateralTokens;

  DecentralizedStableCoin private immutable i_dsc;

  /////////////////
  /// Events /////
  ////////////////
  event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
  event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address token, uint256 amount);

  ////////////////
  // Modifiers //
  ///////////////

  modifier moreThanZero(uint256 amount) {
    if(amount == 0) {
      revert DSCEngine__NeedsMoreThanZero();
    }
    _;
  }

  modifier isAllowedToken(address token) {
    if(s_priceFeed[token] == address(0)) {
      revert DSCEngine__TokenNotAllowed();
    }
    _;
  }

  ///////////////
  // Functions //
  ///////////////

  constructor(
    address[] memory tokenAddresses,
    address[] memory priceFeedAddresses,
    address dscAddress
    ) {
    if (tokenAddresses.length != priceFeedAddresses.length) {
      revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    }
    for (uint256 i = 0; i < tokenAddresses.length; i++) {
      s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
      s_collateralTokens.push(tokenAddresses[i]);
    }
    i_dsc = DecentralizedStableCoin(dscAddress);
  }


  /////////////////////////
  // External Functions //
  ////////////////////////

  /*
    * @param collateralTokenAddress The address of the token to deposit as a collateral
    * @param collateralAmount The amount of collateral to deposit
    * @param amountDSCToMint The amount of DSC to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
  */
  function depositCollateralAndMintDSC(
    address collateralTokenAddress,
    uint256 collateralAmount,
    uint256 amountDSCToMint
    ) external {
    depositCollateral(collateralTokenAddress, collateralAmount);
    mintDSC(amountDSCToMint);
  }

  /*
   * @notice follows the CEI pattern
   * @param collateralToken The address of the token to deposit as a collateral
   * @param amountCollateral The amount of collateral to deposit
  */
  function depositCollateral(address collateralToken, uint256 collateralAmount)
    public moreThanZero(collateralAmount)
    isAllowedToken(collateralToken)
    nonReentrant
  {
      s_collateralDeposited[msg.sender][collateralToken] += collateralAmount;
      emit CollateralDeposited(msg.sender, collateralToken, collateralAmount);
      bool success = IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
      if (!success) {
        revert DSCEngine__TransferFailed();
      }
  }

  /*
    * @param collateralTokenAddress The address of the token to redeem as a collateral
    * @param collateralAmount The amount of collateral to redeem
    * @param amountDSCToBurn The amount of DSC to burn
    * @notice this function will burn DSC and redeem your collateral in one transaction
  */
  function redeemCollateralForDSC(
    address collateralTokenAddress,
    uint256 collateralAmount,
    uint256 amountDSCToBurn
  ) external
  {
    burnDSC(amountDSCToBurn);
    redeemCollateral(collateralTokenAddress, collateralAmount);
    // redeemCollateral already checks health factor
  }

  // in order to redeem collateral:
  // 1. health factor must be above 1 AFTER collateral is pulled
  function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount)
    public
    moreThanZero(collateralAmount)
    nonReentrant
  {
    _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmount);
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  /*
   * @notice follows the CEI pattern
   * @param amountDSCToMint The amount of DSC to mint
   * @notice they must have more collateral value than the minimum threshold
  */
  function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
    s_dscMinted[msg.sender] += amountDSCToMint;
    _revertIfHealthFactorIsBroken(msg.sender);
    bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
    if (!minted) {
      revert DSCEngine__MintFailed();
    }
  }

  function burnDSC(uint256 amount) public moreThanZero(amount) {
    // s_dscMinted[msg.sender] -= amount;
    // bool success = i_dsc.transferFrom(msg.sender, address(this), amount); // could also use the burn erc20 function or send to the zero address
    // if (!success) {
    //   revert DSCEngine__TransferFailed();
    // }
    // i_dsc.burn(amount);
    _burnDsc(amount, msg.sender, msg.sender);
    // No need to check if the burn breaks the health factor
    // _revertIfHealthFactorIsBroken(msg.sender);
  }

  // If someone is almost undercollateralized, we will pay you to liquidate them
  /*
    * @param collateral The ERC20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
    *
    * @notice You can partially liquidate a user
    * @notice You will get a liquidation reward for liquidating a user
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize liquidators
    * For example, if the price of the collateral plummeted before anyone could be liquidated, then the protocol would be insolvent
    *
    * Follows the CEI pattern: Checks-Effects-Interactions
    */
  function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant
  {
    uint256 startingUserHealthFactor = _healthFactor(user);
    // 1. check health factor of the user: can they be liquidated?
    if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
      revert DSCEngine__HealthFactorOK();
    }
    // 2. burn their DSC "debt" and redeem their collateral
    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateral, debtToCover);
    // give 10% bonus to liquidator
    // liquidator gets $110 of WETH for 100 DSC (reminder: 1DSC = 1$)
    // e.g., 0.05 * 0.1 = 0.005 ==> liquidator gets 0.005 WETH
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

    // burn the DSC debt
    _burnDsc(debtToCover, user, msg.sender);

    uint256 endingUserHealthFactor = _healthFactor(user);
    if (endingUserHealthFactor <= startingUserHealthFactor) {
      revert DSCEngine__HealthFactorNotImproved();
    }

    _revertIfHealthFactorIsBroken(user);
  }


  ////////////////////////////////////////
  // Private & Internal View Functions //
  ///////////////////////////////////////

  function _getUsdValue(address token, uint256 amount) private view returns(uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
    (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
    // we want to have everything in terms of WEI, so we 0-pad up to 18 decimals
    return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // Chainlink returns price with 8 decimals, we need 18
  }

  function _redeemCollateral(address from, address to, address collateralTokenAddress, uint256 collateralAmount) private {
    s_collateralDeposited[from][collateralTokenAddress] -= collateralAmount;
    emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);
    bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
    if (!success) {
      revert DSCEngine__TransferFailed();
    }
  }

  /*
   * Returns how close to liquidation a user is
   * If a user goes below 1, then they can get liquidated
  */
  function _getAccountInformation(address user) private view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD) {
    totalDSCMinted = s_dscMinted[user];
    collateralValueInUSD = getAccountCollateralValue(user);
  }


  function _healthFactor(address user) private view returns (uint256) {
    (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
    // return (collateralValueInUSD / totalDSCMinted);
    return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
  }

  function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD) internal pure returns (uint256) {
    if (totalDSCMinted == 0) return type(uint256).max;
    uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
  }

    // 1. Check health factor: do they have more collateral value than the minimum threshold?
    // 2. Revert if they don't
  function _revertIfHealthFactorIsBroken(address user) internal view {
    uint256 userHealthFactor = _healthFactor(user);
    if (userHealthFactor < MIN_HEALTH_FACTOR) {
      revert DSCEngine__HealthFactorTooLow(userHealthFactor);
    }
  }

  /*
    * @dev Low-level internal function
    * @dev Do not call unless the function calling it has already checked the health factor
    */
  function _burnDsc(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private
  {
    s_dscMinted[onBehalfOf] -= amountDSCToBurn;
    bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
    if (!success) {
      revert DSCEngine__TransferFailed();
    }
    i_dsc.burn(amountDSCToBurn);
  }

  ////////////////////////////////////////
  // Public & External View Functions ///
  ///////////////////////////////////////

  function getAccountCollateralValue(address user) public view returns(uint256) {
    uint256 totalCollateralValueInUSD;
    for (uint256 i = 0; i < s_collateralTokens.length; i++) {
      address token = s_collateralTokens[i];
      uint256 amount = s_collateralDeposited[user][token];
      totalCollateralValueInUSD += getUSDValue(token, amount);
    }
    return totalCollateralValueInUSD;
  }

  function getUSDValue(address token, uint256 amount) public view returns(uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
    (, int price, , , ) = priceFeed.staleCheckLatestRoundData();
    return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // Chainlink returns price with 8 decimals, we need 18
  }

  function getTokenAmountFromUSD(address token, uint256 usdAmountInWei) public view returns(uint256)
  {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
    (, int price, , , ) = priceFeed.staleCheckLatestRoundData();
    uint256 tokenAmount = (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    return tokenAmount;
  }

  function getAccountInformation(address user) external view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD) {
    (totalDSCMinted, collateralValueInUSD) = _getAccountInformation(user);
  }

  function calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD) external pure returns (uint256) {
    return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
  }

  function getCollateralTokens() external view returns(address[] memory) {
    return s_collateralTokens;
  }

  function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
    return s_collateralDeposited[user][token];
  }

  function getPrecision() external pure returns (uint256) {
    return PRECISION;
  }

  function getAdditionalFeedPrecision() external pure returns (uint256) {
    return ADDITIONAL_FEED_PRECISION;
  }

  function getLiquidationThreshold() external pure returns (uint256) {
    return LIQUIDATION_THRESHOLD;
  }

  function getLiquidationBonus() external pure returns (uint256) {
    return LIQUIDATION_BONUS;
  }

  function getLiquidationPrecision() external pure returns (uint256) {
    return LIQUIDATION_PRECISION;
  }

  function getMinHealthFactor() external pure returns (uint256) {
    return MIN_HEALTH_FACTOR;
  }

  function getDsc() external view returns (address) {
    return address(i_dsc);
  }

  function getCollateralTokenPriceFeed(address token) external view returns (address) {
    return s_priceFeed[token];
  }

  function getHealthFactor(address user) external view returns (uint256) {
    return _healthFactor(user);
  }
}