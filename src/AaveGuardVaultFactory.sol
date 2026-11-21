// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AaveGuardVault} from "./AaveGuardVault.sol";

/// @title AaveGuardVaultFactory
/// @notice Deploys one AaveGuardVault per call, owned by the caller, wired to this chain's
///         Aave V3 Pool, WETH, USDC and variable-debt USDC token.
contract AaveGuardVaultFactory {
    address public immutable pool;
    address public immutable weth;
    address public immutable usdc;
    address public immutable variableDebtUsdc;

    mapping(address owner => address[]) internal _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault);

    constructor(address pool_, address weth_, address usdc_, address variableDebtUsdc_) {
        require(pool_ != address(0) && weth_ != address(0) && usdc_ != address(0), "zero address");
        pool = pool_;
        weth = weth_;
        usdc = usdc_;
        variableDebtUsdc = variableDebtUsdc_;
    }

    function createVault() external returns (address vault) {
        vault = address(new AaveGuardVault(msg.sender, pool, weth, usdc, variableDebtUsdc));
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}
