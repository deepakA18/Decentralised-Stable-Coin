// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

///////////////////////////imports///////////////////////////////////////////////

import {DecentralisedStableCoin} from "./DecentralisedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ///////////////////////////Errors///////////////////////////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__breaksHealthFactor(uint256 healthFactor);
    error DSCEngine__DscMintingFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////////State Variables///////////////////////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR= 1;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant LIQUIDATION_BONUS = 10; //10%

    mapping(address token => address priceFeed) private s_PriceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted; 
    DecentralisedStableCoin private immutable i_dsc;
    address[] private s_collateralTokens;


    ///////////////////////////Events///////////////////////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralReedemed(address indexed redeemedFrom,address indexed redeemedTo,address indexed token, uint256 amount);

    ///////////////////////////Modifiers///////////////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateral(address token) {
        if (s_PriceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////////////Functions///////////////////////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_PriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralisedStableCoin(dscAddress);
    }

    ///////////////////////////External Functions///////////////////////////////////////////

    function depositeCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedCollateral(tokenCollateralAddress)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(address tokenCollateralAddress,uint256 amountCollateral,uint256 amountDscToBurn) external {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant{
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted)
        {
            revert DSCEngine__DscMintingFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //not gonna hit?

    }

    function liquidate(address collateral,address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor > MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral,debtToCover);

        uint256 bonusCollateral  = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToReedem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToReedem, user, msg.sender);

        _burnDSC(debtToCover,user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor)
        {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function getHealthFactor() external {}


  ///////////////////////////Internal & Private Functions///////////////////////////////////////////


  function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256) {
        if(totalDscMinted == 0)
        {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreashold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreashold & 1e18) / totalDscMinted;
  } 


  function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
         s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if(!success){
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
  }


  function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral,address from, address to) private {

     s_CollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralReedemed(from,to,tokenCollateralAddress,amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }

  }

  function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
  }

    function _healthFactor(address user) private view returns(uint256){
        //1. total DSC minted
        //2. Total collateral VALUE
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Do they have enough collateral ?
        //2. Revert if they don't

        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR)
        {
            revert DSCEngine__breaksHealthFactor(userHealthFactor);
        }

    }


    ///////////////////////////Public & External Functions///////////////////////////////////////////

      function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }


    function getTokenAmountFromUsd(address token,uint256 usdAmountInWei) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_PriceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value

        for(uint256 i=0;i<s_collateralTokens.length;i++)
        {
            address token = s_collateralTokens[i];
            uint256 amount = s_CollateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);

        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_PriceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;

    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        (totalDscMinted,collateralValueInUsd) = _getAccountInformation(user);
    }

    function getAdditionalFeedPrecision() external pure returns(uint256){
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns(uint256){
        return PRECISION;
    }
}
