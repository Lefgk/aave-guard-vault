# Aave Guard Vault

The owner supplies ETH, WETH or USDC to **Aave V3** through a vault. Each authorized agent may borrow USDC to allowlisted destinations, within a **per-tx cap** and **per-period cap**, only if the vault **health factor** stays above an owner-set floor (checked after the borrow). Agents (and anyone else) may **repay**. The owner can **pause**, **revoke**, **withdraw** and **repay**.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed. Collateral on Aave can be liquidated if health factor falls below 1.

See [SPEC.md](SPEC.md) for the problem, choices and open questions, and [DEPLOY.md](DEPLOY.md) for the deploy runbook.

## Layout

| Path | What |
|---|---|
| `src/AaveGuardVault.sol` | The vault: supply/withdraw, agent caps, allowlist, HF floor, pause, revoke, repay |
| `src/AaveGuardVaultFactory.sol` | Deploys one vault per owner, wired to this chain's Aave V3 Pool, WETH and USDC |
| `src/interfaces/IPool.sol` | Minimal Aave V3 Pool / WETH / provider interfaces |
| `src/mocks/` | MockUSDC, MockWETH and MockAavePool for local tests only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against the real Aave V3 Pool and Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain official addresses |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8623) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain factory / USDC / WETH / Pool addresses written by a successful deploy |
| `docs/slither-report.txt` | Static-analysis output (when generated) |
| `Makefile` | One-command test, dapp build, dry-run and deploy targets |

## Contract model

- `supplyETH()`, `supply(asset, amount)`, `withdraw` / `withdrawETH` are owner only. Allowed collateral is WETH and USDC; ETH is wrapped first.
- `grantAgent`, `setBudget(agent, perTxCap, periodCap, periodSeconds)`, `setRecipient` and `setHealthFactorFloor` are owner only. The floor cannot be set below 1.1e18 (default 1.5e18).
- `borrow(to, amount, memo)` is called by the agent. It checks the agent is active and not expired, the vault isn't paused, the recipient is allowlisted, both caps hold, then borrows variable-rate USDC from Aave and reverts if the resulting health factor is below the floor.
- `repay(amount)` and `repayFor(agent, amount)` can be called by anyone (works while paused). Agent repay reduces that agent's outstanding principal.
- `revokeAgent` (owner or guardian) bumps the agent's epoch, so all of its budgets and allowlist entries die at once.
- `pause()` is owner or guardian; `unpause()` is owner only. Withdraw and repay work while paused.
- Ownership uses `Ownable2Step`, so a Safe can be the owner.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-vault.

Connect a wallet, switch network, then: create or pick a vault, supply ETH/WETH/USDC, set the health-factor floor, grant an agent (caps, period, allowlist, expiry), inspect health factor and caps, borrow or repay, pause, or revoke.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8623
```

Fork tests (real Aave V3 Pool and Circle USDC, plus the deploy-script fork tests):

```bash
anvil --port 8623 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

This worker uses **anvil port 8623 only**.

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | Aave V3 Pool | USDC | WETH |
|---|---|---|---|---|
| Ethereum mainnet | 1 | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Base | 8453 | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x4200000000000000000000000000000000000006` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8623; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes addresses into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md).

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil                                   # terminal 1 (chain 31337)
./script/deploy-anvil.sh                # factory + MockUSDC/WETH/AavePool on a fresh anvil
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs

`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
