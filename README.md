
## Foundry DeFi Stablecoin

This project implements a stablecoin where users can deposit WETH and WBTC in exchange for DSC tokens (DecentralizedStableCoin, our stablecoin), whose price is 1:1 pegged to USD, i.e., 1DSC = 1$.
The protocol is always meant to be overcollateralized and the logic implemented guarantees that this property always holds (invariant). The core logic is implemented within the DSCEngine.sol contract.

Moreover, it takes advantage of Foundry for scripts and testing suites (unit, fuzzing, invariants).