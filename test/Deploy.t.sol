// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {AaveGuardVaultFactory} from "../src/AaveGuardVaultFactory.sol";
import {AaveGuardVault} from "../src/AaveGuardVault.sol";

contract DeployConfigTest is Test {
    function test_ethereumAndBaseAddressesAndFlags() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(e.weth, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(e.pool, 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
        assertEq(e.poolAddressesProvider, 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
        assertEq(e.variableDebtUsdc, 0x72E95b8931767C79bA4EeE721354d6E99a61D004);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(b.weth, 0x4200000000000000000000000000000000000006);
        assertEq(b.pool, 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5);
        assertEq(b.poolAddressesProvider, 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D);
        assertEq(b.variableDebtUsdc, 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28);
        assertTrue(b.isMainnet);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111); // Sepolia is not a supported target
        Deploy script = new Deploy();
        vm.expectRevert(bytes("DeployConfig: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysFactoryAndMocks() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (AaveGuardVaultFactory factory, address usdc, address weth, address pool) = script.run();
        assertTrue(address(factory).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertTrue(weth.code.length > 0);
        assertTrue(pool.code.length > 0);
        assertEq(factory.pool(), pool);
        assertEq(factory.usdc(), usdc);
        assertEq(factory.weth(), weth);
        address vault = factory.createVault();
        assertTrue(vault.code.length > 0);
        assertEq(AaveGuardVault(payable(vault)).owner(), address(this));
        assertEq(factory.vaultsOf(address(this)).length, 1);
        assertEq(AaveGuardVault(payable(vault)).healthFactorFloor(), 1.5e18);
    }
}
