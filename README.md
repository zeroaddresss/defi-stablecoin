# DSC: Decentralized Stablecoin

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Solidity Version](https://img.shields.io/badge/solidity-^0.8.18-lightgrey)
![Build Status](https://img.shields.io/badge/build-passing-brightgreen)

DSC is an algorithmic, decentralized stablecoin system designed to maintain a 1:1 peg with the US Dollar. It's built on the principles of overcollateralization and exogenous collateral, similar to DAI but without governance, fees, and only backed by WETH and WBTC.

## 🌟 Key Features

- **Decentralized**: No central authority controls the system
- **Overcollateralized**: Always maintains > 100% collateralization
- **Algorithmic Stability**: Uses smart contracts to maintain the peg
- **Exogenous Collateral**: Backed by WETH and WBTC
- **Liquidation System**: Ensures system solvency
- **No Governance**: Fully autonomous operation
- **No Fees**: Zero transaction or stability fees

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation.html)
- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)

### Installation

1. Clone the repository:
   ```
   git clone https://github.com/zeroaddresss/dsc-stablecoin.git
   cd dsc-stablecoin
   ```

2. Install dependencies:
   ```
   forge install
   ```

3. Compile the contracts:
   ```
   forge build
   ```

4. Run tests:
   ```
   forge test
   ```

## 📘 Detailed Documentation

### Core Contracts

1. **DecentralizedStableCoin.sol**: The ERC20 token implementation of DSC.
2. **DSCEngine.sol**: The core logic for minting, burning, depositing, and redeeming DSC.
3. **OracleLib.sol**: A library for interacting with Chainlink price feeds and checking for stale data.

### Key Functions

- `depositCollateralAndMintDSC`: Deposit collateral and mint DSC in one transaction
- `redeemCollateralForDSC`: Burn DSC and redeem collateral in one transaction
- `liquidate`: Liquidate undercollateralized positions

### System Parameters

- Liquidation Threshold: 50% (200% overcollateralized)
- Liquidation Bonus: 10%
- Minimum Health Factor: 1e18 (1 in standard units)

## 💡 Examples and Use Cases

1. **Minting DSC**:
   ```solidity
   // Deposit 1 WETH as collateral
   IERC20(WETH).approve(address(dscEngine), 1e18);
   dscEngine.depositCollateralAndMintDSC(WETH, 1e18, 100e18);
   ```

2. **Redeeming Collateral**:
   ```solidity
   dscEngine.redeemCollateralForDSC(WETH, 0.5e18, 50e18);
   ```

3. **Liquidating a Position**:
   ```solidity
   dscEngine.liquidate(WETH, userAddress, 100e18);
   ```

## 📁 Project Structure

```
dsc-stablecoin/
├── src/
│   ├── DecentralizedStableCoin.sol
│   ├── DSCEngine.sol
│   └── libraries/
│       └── OracleLib.sol
├── script/
│   ├── DeployDSC.s.sol
│   └── HelperConfig.s.sol
└── test/
    └── mocks/
        └── MockV3Aggregator.sol
```

## 🛠 Dependencies

- OpenZeppelin Contracts
- Chainlink Contracts

## 🧪 Testing

Run the test suite using Foundry:

```
forge test
```

For more verbose output:

```
forge test -vvvv
```

## 🚢 Deployment

To deploy the DSC system:

1. Set up your `.env` file with the required environment variables (e.g., `PRIVATE_KEY`, `ETHERSCAN_API_KEY`)
2. Run the deployment script:
   ```
   forge script script/DeployDSC.s.sol:DeployDSC --rpc-url $RPC_URL --broadcast --verify -vvvv
   ```
---

⚠️ **Disclaimer**: This project is for educational purposes only. Do not use in production without proper audits and risk assessment.
