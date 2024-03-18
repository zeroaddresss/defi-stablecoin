// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Test } from "forge-std/Test.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator ethUsdPriceFeed;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDesposited;

    uint256 constant MAX_DEPOSIT_AMOUNT = type(uint96).max;
    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    /*
     * @notice Only the DSCEngine can mint DSC!
     */
    // function mintDsc(uint256 dscAmount, uint256 addressSeed) public {
    //     if (usersWithCollateralDesposited.length == 0) {
    //         return;
    //     }
    //     address sender = usersWithCollateralDesposited[addressSeed % usersWithCollateralDesposited.length];
    //     (uint256 totalDscMinted, uint256 collateralValeuInUSD) = dsce.getAccountInformation(sender);
    //     uint256 maxDscToMint = (collateralValeuInUSD / 2) - totalDscMinted;
    //     if (maxDscToMint < 0) {
    //         return;
    //     }
    //     dscAmount = bound(dscAmount, 0, uint256(maxDscToMint));
    //     if (dscAmount == 0) {
    //         return;
    //     }
    //     vm.startPrank(sender);
    //     dsce.mint(msg.sender, dscAmount);
    //     vm.stopPrank();
    //     timesMintIsCalled++;
    // }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 0, MAX_DEPOSIT_AMOUNT);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dsce), collateralAmount);

        dsce.depositCollateral(address(collateral), collateralAmount);
        // dsce.depositCollateral(collateral, collateralAmount);
        vm.stopPrank();
        // this can double push the same address
        usersWithCollateralDesposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);
        if (collateralAmount == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), collateralAmount);
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}