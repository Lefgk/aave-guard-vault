// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AaveGuardVaultFactory} from "../src/AaveGuardVaultFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MockAavePool, MockVariableDebtToken} from "../src/mocks/MockAavePool.sol";
import {DeployConfig} from "./DeployConfig.sol";
import {IPoolAddressesProvider} from "../src/interfaces/IPool.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys AaveGuardVaultFactory on Ethereum mainnet (1), Base (8453) or local anvil (31337).
///         - Prints the chain it is on.
///         - Checks canonical USDC, WETH and that PoolAddressesProvider.getPool() matches the
///           official Aave V3 Pool before doing anything on a live chain.
///         - REFUSES to broadcast on chain 1 / 8453 unless env CONFIRM_MAINNET=yes.
///         - On a live broadcast, writes factory / USDC / WETH / pool into web/src/deployments.json.
///         Dry run (no --broadcast) is always allowed and prints gas estimates.
///         On local anvil, deploys MockUSDC, MockWETH, a MockAavePool (with seed liquidity) and the factory.
contract Deploy is Script {
    string internal constant DEPLOYMENTS_PATH = "web/src/deployments.json";

    function run() external returns (AaveGuardVaultFactory factory, address usdc, address weth, address pool) {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        console2.log("==> Chain:", c.name);
        console2.log("    chainId:", block.chainid);

        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (c.isMainnet) {
            _checkLive(c);
            if (broadcasting) {
                require(
                    keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("yes"),
                    "Deploy: refusing to broadcast on a live chain without CONFIRM_MAINNET=yes"
                );
                console2.log("    CONFIRM_MAINNET=yes - LIVE BROADCAST");
            } else {
                console2.log("    dry run (no --broadcast): nothing will be sent");
            }
        }

        vm.startBroadcast();
        if (c.isMainnet) {
            usdc = c.usdc;
            weth = c.weth;
            pool = c.pool;
            factory = new AaveGuardVaultFactory(c.pool, c.weth, c.usdc, c.variableDebtUsdc);
        } else {
            MockUSDC musdc = new MockUSDC();
            MockWETH mweth = new MockWETH();
            MockVariableDebtToken debt = new MockVariableDebtToken();
            MockAavePool mpool = new MockAavePool(address(mweth), address(musdc), address(debt));
            debt.setPool(address(mpool));
            musdc.mint(address(mpool), 10_000_000e6);
            usdc = address(musdc);
            weth = address(mweth);
            pool = address(mpool);
            factory = new AaveGuardVaultFactory(pool, weth, usdc, address(debt));
        }
        vm.stopBroadcast();

        console2.log("AaveGuardVaultFactory", address(factory));
        console2.log("USDC", usdc);
        console2.log("WETH", weth);
        console2.log("Pool", pool);

        if (broadcasting) {
            _writeWebConfig(address(factory), usdc, weth, pool);
        }
    }

    function _checkLive(DeployConfig.Chain memory c) internal view {
        require(c.usdc.code.length > 0, "Deploy: USDC has no code on this chain");
        require(keccak256(bytes(IERC20Meta(c.usdc).symbol())) == keccak256("USDC"), "Deploy: USDC symbol mismatch");
        require(IERC20Meta(c.usdc).decimals() == 6, "Deploy: USDC decimals mismatch");
        console2.log("    USDC verified (symbol USDC, 6 decimals):", c.usdc);

        require(c.weth.code.length > 0, "Deploy: WETH has no code on this chain");
        require(keccak256(bytes(IERC20Meta(c.weth).symbol())) == keccak256("WETH"), "Deploy: WETH symbol mismatch");
        console2.log("    WETH verified:", c.weth);

        require(c.pool.code.length > 0, "Deploy: Aave V3 Pool has no code on this chain");
        require(c.poolAddressesProvider.code.length > 0, "Deploy: PoolAddressesProvider has no code");
        address fromProvider = IPoolAddressesProvider(c.poolAddressesProvider).getPool();
        require(fromProvider == c.pool, "Deploy: PoolAddressesProvider.getPool() mismatch");
        console2.log("    Aave V3 Pool verified via provider:", c.pool);
        require(c.variableDebtUsdc.code.length > 0, "Deploy: variableDebtUsdc has no code");
    }

    function _writeWebConfig(address factory, address usdc, address weth, address pool) internal {
        string memory path = vm.envOr("DEPLOYMENTS_PATH", DEPLOYMENTS_PATH);
        if (!vm.exists(path)) {
            console2.log("    skip writing dapp config: file not found:", path);
            return;
        }
        string memory key = string.concat(".", vm.toString(block.chainid));
        string memory obj = "dep";
        vm.serializeAddress(obj, "factory", factory);
        vm.serializeAddress(obj, "usdc", usdc);
        vm.serializeAddress(obj, "weth", weth);
        string memory json = vm.serializeAddress(obj, "pool", pool);
        vm.writeJson(json, path, key);
        console2.log("    wrote factory + USDC + WETH + pool to", path);
    }
}
