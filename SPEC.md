# Aave Guard Vault — spec (prototype, 22 Nov 2026)

Source: overnight agent-DeFi research (`agents-lending.md`). Agent Spend Controls is a grant, not a loan. Official Aave and Morpho agent tools still make the owner sign every borrow.

**Problem.** An owner who supplies collateral to Aave has no on-chain way to let an AI agent borrow USDC on its own under caps and a hard health-factor guard.

**Users.** Builders running paying or trading agents who want the collateral to earn on Aave while the agent spends only within policy.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).** One vault per owner (EOA or Safe). The owner supplies ETH (auto-wrapped), WETH, or optional USDC to the official Aave V3 Pool. Each agent gets a per-tx cap, a per-period cap (fixed windows), a payee allowlist and an expiry, and may borrow variable-rate USDC only to an allowlisted address. The vault is the single Aave user; per-agent outstanding is principal borrowed minus repaid. Aave interest accrues on the shared position. After every borrow and withdraw, health factor must stay at or above an owner-set floor (default 1.5, minimum 1.1); if not, the whole transaction reverts. The owner or guardian can pause or revoke; an agent can renounce. Anyone may repay. The owner can withdraw and repay while paused. The web dapp covers the owner and agent flows, plus health factor, caps, and a clear liquidation warning. Out of v0: Morpho, other assets, fees, unsecured credit, keepers.

**Choices for Lef to review.** Default HF floor 1.5 / min 1.1. Variable-rate USDC only. Caps are borrow volume, not interest. No fee. Standalone vault + factory, not a Safe module. Base first for cheaper gas.

**Competitors.** Aave for Agents, Morpho Agents, Agent Treasury (CRE demo), Circuit SDK, SOURCE / Priors (wrong chain).

**Edge.** The agent can call the vault itself; caps, allowlist and a hard HF floor are on-chain, without CRE or a new money market.

**Open questions.** Audit before a live deploy? Owner wallet or Safe? First chain (recommend Base)? Name and fees?
