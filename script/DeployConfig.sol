// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Per-chain deploy settings. Only Ethereum mainnet, Base and local anvil are supported.
///         Live-chain addresses are from the official Aave address book (AaveV3Ethereum / AaveV3Base).
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet; // live chain with real funds -> needs CONFIRM_MAINNET=yes to broadcast
        address usdc;
        address weth;
        address pool;
        address poolAddressesProvider;
        address variableDebtUsdc;
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address internal constant POOL_ETHEREUM = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant PROVIDER_ETHEREUM = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant PROVIDER_BASE = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant VAR_DEBT_USDC_ETHEREUM = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address internal constant VAR_DEBT_USDC_BASE = 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28;

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) {
            return Chain(
                "Ethereum mainnet",
                true,
                USDC_ETHEREUM,
                WETH_ETHEREUM,
                POOL_ETHEREUM,
                PROVIDER_ETHEREUM,
                VAR_DEBT_USDC_ETHEREUM
            );
        }
        if (chainId == BASE) {
            return Chain("Base", true, USDC_BASE, WETH_BASE, POOL_BASE, PROVIDER_BASE, VAR_DEBT_USDC_BASE);
        }
        if (chainId == ANVIL) {
            return Chain("Local anvil", false, address(0), address(0), address(0), address(0), address(0));
        }
        revert("DeployConfig: unsupported chain (only 1, 8453, 31337)");
    }
}
