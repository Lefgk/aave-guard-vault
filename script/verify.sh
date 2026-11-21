#!/usr/bin/env bash
# Verify deployed contracts on Etherscan v2 (one API key works for Ethereum 1 and Base 8453).
#   ./script/verify.sh factory <factoryAddress>
#   ./script/verify.sh vault   <vaultAddress> <ownerAddress>
# Env: RPC_URL (to detect chain), ETHERSCAN_API_KEY. Key is never echoed.
# Constructor args for the factory are taken from this chain's DeployConfig addresses.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
: "${RPC_URL:?set RPC_URL}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY (Etherscan v2 key)}"
KIND=${1:?factory|vault}; ADDR=${2:?address}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
case "$CHAIN_ID" in
  1)
    echo "==> Chain: Ethereum mainnet (1)"
    USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    POOL=0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    DEBT=0x72E95b8931767C79bA4EeE721354d6E99a61D004
    ;;
  8453)
    echo "==> Chain: Base (8453)"
    USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    WETH=0x4200000000000000000000000000000000000006
    POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
    DEBT=0x59dca05b6c26dbd64b5381374aAaC5CD05644C28
    ;;
  *) echo "Unsupported chain $CHAIN_ID" >&2; exit 1;;
esac
COMMON=(--chain "$CHAIN_ID" --watch --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID")
case "$KIND" in
  factory)
    forge verify-contract "$ADDR" src/AaveGuardVaultFactory.sol:AaveGuardVaultFactory "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address,address)' "$POOL" "$WETH" "$USDC" "$DEBT")"
    ;;
  vault)
    OWNER=${3:?owner address}
    forge verify-contract "$ADDR" src/AaveGuardVault.sol:AaveGuardVault "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' "$OWNER" "$POOL" "$WETH" "$USDC" "$DEBT")"
    ;;
  *) echo "first arg must be factory or vault" >&2; exit 1 ;;
esac
