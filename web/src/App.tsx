import { useState } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, pad, parseUnits, stringToHex, type Address } from "viem";
import { aaveGuardVaultAbi, aaveGuardVaultFactoryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

const MAX_HF = (1n << 256n) - 1n;

function formatHf(hf?: bigint) {
  if (hf === undefined) return "…";
  if (hf === 0n) return "0 (liquidatable)";
  if (hf >= MAX_HF / 2n) return "∞ (no debt)";
  const s = formatUnits(hf, 18);
  const n = Number(s);
  return Number.isFinite(n) ? n.toFixed(3) : s;
}

function hfClass(hf?: bigint, floor?: bigint) {
  if (hf === undefined) return "";
  if (hf >= MAX_HF / 2n) return "ok";
  if (hf < 10n ** 18n) return "bad";
  if (floor !== undefined && hf < floor) return "bad";
  if (hf < 12n * 10n ** 17n) return "bad";
  return "ok";
}

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <Shell
      title="Aave Guard Vault"
      tagline="Give an AI agent a USDC credit line backed by your own Aave V3 collateral. You supply ETH, WETH or USDC; the agent can only borrow USDC to addresses you allowlist, within caps you set, and only while the health factor stays above your floor."
      steps={[
        "Create a vault you own and supply collateral to Aave through it.",
        "Grant an agent key: expiry, per-transaction cap, period cap, allowed recipients.",
        "The agent borrows within those limits. Anyone can repay.",
        "Pause or revoke at any time; withdraw collateral once debt allows.",
      ]}
      contractLabel="Vault factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[
        { label: "Aave V3 pool", address: dep.pool },
        { label: "USDC", address: dep.usdc },
        { label: "WETH", address: dep.weth },
      ]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Collateral on Aave can be liquidated if the health
          factor falls below 1. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a vault or manage one you already own.</Empty>}

      {isConnected && address && (
        <>
          <VaultPicker owner={address} factory={dep.factory} vault={vault} setVault={setVault} />
          {vault && isAddress(vault) && (
            <>
              <VaultOverview vault={vault} usdc={dep.usdc} weth={dep.weth} />
              <GrantAgent vault={vault} />
              <AgentView vault={vault} usdc={dep.usdc} />
            </>
          )}
        </>
      )}
    </Shell>
  );
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch, isLoading } = useReadContract({
    address: factory,
    abi: aaveGuardVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run, safe } = useTx();
  return (
    <div className="card">
      <h2>1. Choose a vault</h2>
      <p className="muted">
        A vault is your own contract. It holds the Aave position and enforces the agent limits. Each wallet can own
        several.
      </p>
      <div className="field-label">Your vaults on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so vaults cannot be listed or created here.</Empty>
      ) : isLoading ? (
        <Loading>Looking up your vaults…</Loading>
      ) : vaults && vaults.length > 0 ? (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "seg seg-on" : "seg"} aria-pressed={v === vault} onClick={() => setVault(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === vault ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no vaults yet. Create one below, or paste the address of a vault you want to inspect.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={safe(async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: aaveGuardVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          })}
        >
          Create new vault
        </button>
        <label>
          Or open a vault by address
          <input value={vault} placeholder="0x…" spellCheck={false} onChange={(e) => setVault(e.target.value.trim() as Address)} />
        </label>
      </div>
      {vault && !isAddress(vault) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>
        “Create new vault” deploys a vault contract owned by your connected wallet. One transaction, gas only — no
        funds move.
      </Hint>
      {status}
    </div>
  );
}

function VaultOverview({ vault, usdc, weth }: { vault: Address; usdc?: Address; weth?: Address }) {
  const { data: account, refetch: refetchAcct } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "accountData",
  });
  const { data: debt, refetch: refetchDebt } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "usdcDebt",
  });
  const { data: paused, refetch: refetchPaused } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "paused",
  });
  const { data: owner } = useReadContract({ address: vault, abi: aaveGuardVaultAbi, functionName: "owner" });
  const { address: me } = useAccount();
  const notOwner = !!owner && !!me && owner.toLowerCase() !== me.toLowerCase();
  const { writeContractAsync, status, run, safe } = useTx();
  const [ethAmt, setEthAmt] = useState("1");
  const [usdcAmt, setUsdcAmt] = useState("100");
  const [wethAmt, setWethAmt] = useState("1");
  const [wdEth, setWdEth] = useState("0.1");
  const [repayAmt, setRepayAmt] = useState("100");
  const [floor, setFloor] = useState("1.5");

  const col = account?.[0];
  const dBase = account?.[1];
  const avail = account?.[2];
  const hf = account?.[5];
  const fl = account?.[6];

  const refresh = () => {
    refetchAcct();
    refetchDebt();
    refetchPaused();
  };

  return (
    <div className="card">
      <h2>2. Position and collateral (owner)</h2>
      <dl className="dl">
        <dt>Vault</dt>
        <dd>
          <Addr value={vault} full />
        </dd>
        <dt>Owner</dt>
        <dd>
          <Addr value={owner} /> {owner && me && !notOwner && <span className="ok">(you)</span>}
        </dd>
        <dt>Agent borrowing</dt>
        <dd>{paused === undefined ? "…" : paused ? <span className="bad">Paused</span> : <span className="ok">Active</span>}</dd>
      </dl>
      {notOwner && (
        <div className="info">
          You are not the owner of this vault. You can read it, supply collateral and repay debt, but withdrawing,
          changing the floor and pausing will be rejected.
        </div>
      )}
      <div className="warn">
        Liquidation risk: if health factor drops below 1, Aave can liquidate this vault's collateral. The floor only
        blocks new borrows and owner withdrawals — prices can still move against you.
      </div>
      <table>
        <tbody>
          <tr>
            <td>Health factor</td>
            <td className={hfClass(hf, fl)}>
              {formatHf(hf)} (floor {formatHf(fl)})
            </td>
          </tr>
          <tr>
            <td>Collateral (USD)</td>
            <td>{col !== undefined ? formatUnits(col, 8) : "…"}</td>
          </tr>
          <tr>
            <td>Debt (USD)</td>
            <td>{dBase !== undefined ? formatUnits(dBase, 8) : "…"}</td>
          </tr>
          <tr>
            <td>USDC debt (token)</td>
            <td>{debt !== undefined ? formatUnits(debt, 6) : "…"}</td>
          </tr>
          <tr>
            <td>Available to borrow (USD)</td>
            <td>{avail !== undefined ? formatUnits(avail, 8) : "…"}</td>
          </tr>
        </tbody>
      </table>

      <h3>Add collateral</h3>
      <div className="row">
        <label>
          Supply ETH
          <input value={ethAmt} onChange={(e) => setEthAmt(e.target.value)} />
        </label>
        <button
          onClick={safe(async () => {
            await run("Supply ETH", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "supplyETH",
                value: parseUnits(ethAmt, 18),
              }),
            );
            refresh();
          })}
        >
          Supply ETH
        </button>
        {weth && (
          <>
            <label>
              Supply WETH
              <input value={wethAmt} onChange={(e) => setWethAmt(e.target.value)} />
            </label>
            <button
              onClick={safe(async () => {
                const amt = parseUnits(wethAmt, 18);
                if (
                  await run("Approve WETH", () =>
                    writeContractAsync({ address: weth, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
                  )
                )
                  await run("Supply WETH", () =>
                    writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "supply", args: [weth, amt] }),
                  );
                refresh();
              })}
            >
              Approve + supply WETH
            </button>
          </>
        )}
      </div>
      {usdc && (
        <div className="row">
          <label>
            Supply USDC (optional collateral)
            <input value={usdcAmt} onChange={(e) => setUsdcAmt(e.target.value)} />
          </label>
          <button
            onClick={safe(async () => {
              const amt = parseUnits(usdcAmt, 6);
              if (
                await run("Approve USDC", () =>
                  writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
                )
              )
                await run("Supply USDC", () =>
                  writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "supply", args: [usdc, amt] }),
                );
              refresh();
            })}
          >
            Approve + supply USDC
          </button>
        </div>
      )}
      <Hint>
        Supplying moves the amount from your wallet into Aave V3 as collateral held by this vault. ETH is one
        transaction. WETH and USDC ask twice: first an approval for exactly that amount, then the supply.
      </Hint>
      <h3>Withdraw and repay</h3>
      <div className="row">
        <label>
          Withdraw ETH
          <input value={wdEth} onChange={(e) => setWdEth(e.target.value)} />
        </label>
        <button
          className="ghost"
          onClick={safe(async () => {
            await run("Withdraw ETH", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "withdrawETH",
                args: [owner ?? vault, parseUnits(wdEth, 18)],
              }),
            );
            refresh();
          })}
        >
          Withdraw ETH
        </button>
        {usdc && (
          <>
            <label>
              Repay USDC
              <input value={repayAmt} onChange={(e) => setRepayAmt(e.target.value)} />
            </label>
            <button
              onClick={safe(async () => {
                const amt = parseUnits(repayAmt, 6);
                if (
                  await run("Approve USDC", () =>
                    writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, amt] }),
                  )
                )
                  await run("Repay", () =>
                    writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "repay", args: [amt] }),
                  );
                refresh();
              })}
            >
              Approve + repay
            </button>
          </>
        )}
      </div>
      <Hint>
        Withdraw pulls ETH collateral out of Aave to the vault owner; it is rejected if it would push the health
        factor under your floor. Repay sends USDC from your wallet to Aave to reduce this vault's debt (approval, then
        repay).
      </Hint>
      <h3>Safety controls</h3>
      <div className="row">
        <label>
          Health-factor floor
          <input value={floor} onChange={(e) => setFloor(e.target.value)} />
        </label>
        <button
          className="ghost"
          onClick={safe(async () => {
            await run("Set floor", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "setHealthFactorFloor",
                args: [parseUnits(floor, 18)],
              }),
            );
            refresh();
          })}
        >
          Set floor
        </button>
        {paused ? (
          <button
            onClick={safe(async () => {
              await run("Unpause", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "unpause" }),
              );
              refresh();
            })}
          >
            Unpause
          </button>
        ) : (
          <button
            className="danger"
            onClick={safe(async () => {
              await run("Pause", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "pause" }),
              );
              refresh();
            })}
          >
            Pause agents
          </button>
        )}
      </div>
      <Hint>
        The floor is the lowest health factor an agent borrow or owner withdrawal may leave behind (1.5 is a common
        buffer; below 1 Aave liquidates). Pause blocks every agent borrow immediately; repayments still work.
      </Hint>
      {status}
    </div>
  );
}

function GrantAgent({ vault }: { vault: Address }) {
  const [agent, setAgent] = useState("");
  const [days, setDays] = useState("7");
  const [perTx, setPerTx] = useState("100");
  const [cap, setCap] = useState("500");
  const [hours, setHours] = useState("24");
  const [recipients, setRecipients] = useState("");
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const recipCount = recipients.split(/[\s,]+/).filter(Boolean).length;

  const submit = async () => {
    if (!isAddress(agent)) return fail("The agent address is not a valid address.");
    const recips = recipients.split(/[\s,]+/).filter(Boolean);
    if (recips.some((r) => !isAddress(r))) return fail("One of the recipient addresses is not valid.");
    const expiry = BigInt(Math.floor(Date.now() / 1000) + Math.round(Number(days) * 86400));
    const w = (fn: "grantAgent" | "setBudget" | "setRecipient", args: readonly unknown[]) =>
      writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: fn, args: args as never });
    if (!(await run("Grant agent", () => w("grantAgent", [agent, expiry])))) return;
    if (
      !(await run("Set budget", () =>
        w("setBudget", [agent, parseUnits(perTx, 6), parseUnits(cap, 6), BigInt(Math.round(Number(hours) * 3600))]),
      ))
    )
      return;
    for (const r of recips) if (!(await run(`Allow ${short(r)}`, () => w("setRecipient", [agent, r, true])))) return;
  };

  return (
    <div className="card">
      <h2>3. Grant an agent (owner)</h2>
      <p className="muted">
        The agent is a separate key (for example your bot's hot wallet). It never holds your collateral; it can only
        ask this vault to borrow USDC inside the limits below.
      </p>
      <div className="row">
        <label>
          Agent address
          <input value={agent} placeholder="0x… (the agent's hot key)" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <label style={{ flex: "0 1 110px" }}>
          Expires in (days)
          <input value={days} onChange={(e) => setDays(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Per-tx cap (USDC)
          <input value={perTx} onChange={(e) => setPerTx(e.target.value)} />
        </label>
        <label>
          Period cap (USDC)
          <input value={cap} onChange={(e) => setCap(e.target.value)} />
        </label>
        <label style={{ flex: "0 1 110px" }}>
          Period (hours)
          <input value={hours} onChange={(e) => setHours(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Allowlisted recipients (comma or space separated)
          <input value={recipients} placeholder="0x…" onChange={(e) => setRecipients(e.target.value)} />
        </label>
      </div>
      <button onClick={safe(submit)}>Grant agent with these limits</button>
      <Hint>
        You will confirm {2 + recipCount} transactions in a row: grant the agent until its expiry, set its caps (
        {perTx || "0"} USDC per borrow, {cap || "0"} USDC per {hours || "0"}h), then one per allowlisted recipient (
        {recipCount}). With no recipients the agent cannot borrow anywhere. No funds move.
      </Hint>
      {status}
    </div>
  );
}

function AgentView({ vault, usdc }: { vault: Address; usdc?: Address }) {
  const { address } = useAccount();
  const [lookup, setLookup] = useState("");
  const agent = (isAddress(lookup) ? lookup : address) as Address | undefined;
  const [to, setTo] = useState("");
  const [amt, setAmt] = useState("25");
  const [memo, setMemo] = useState("invoice");
  const [repayAmt, setRepayAmt] = useState("25");
  const { writeContractAsync, status, run, safe, fail } = useTx();

  const { data: rec, refetch: refetchAgent } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "agents",
    args: agent ? [agent] : undefined,
    query: { enabled: !!agent },
  });
  const { data: budget } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "getBudget",
    args: agent ? [agent] : undefined,
    query: { enabled: !!agent },
  });
  const { data: borrowable } = useReadContract({
    address: vault,
    abi: aaveGuardVaultAbi,
    functionName: "borrowableNow",
    args: agent ? [agent] : undefined,
    query: { enabled: !!agent },
  });

  const f = (n?: bigint) => (n === undefined ? "…" : formatUnits(n, 6));

  return (
    <div className="card">
      <h2>4. Agent: limits, borrow, repay</h2>
      <div className="row">
        <label>
          Agent to inspect (defaults to connected wallet)
          <input value={lookup} placeholder={address ?? "0x…"} onChange={(e) => setLookup(e.target.value)} />
        </label>
        {agent && rec && (
          <button
            className="danger"
            onClick={safe(async () => {
              await run("Revoke", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "revokeAgent", args: [agent] }),
              );
              refetchAgent();
            })}
          >
            Revoke agent
          </button>
        )}
      </div>
      {agent && rec && (
        <div className="muted">
          {rec[0] ? <span className="ok">active</span> : <span className="bad">inactive</span>}
          {rec[1] > 0n ? ` · expires ${new Date(Number(rec[1]) * 1000).toLocaleString()}` : ""}
          {` · outstanding ${f(rec[3])} USDC`}
        </div>
      )}
      {agent && rec && !rec[0] && rec[1] === 0n && (
        <Empty>This address has not been granted as an agent on this vault.</Empty>
      )}
      {budget && budget.period > 0n && (
        <table>
          <thead>
            <tr>
              <th>Per-tx cap</th>
              <th>Period cap</th>
              <th>Borrowed in window</th>
              <th>Borrowable now</th>
              <th>Window ends</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>{f(budget.perTxCap)}</td>
              <td>
                {f(budget.periodCap)} / {Number(budget.period) / 3600}h
              </td>
              <td>{f(budget.borrowedInWindow)}</td>
              <td>{borrowable ? f(borrowable[0]) : "…"}</td>
              <td>{borrowable && borrowable[1] > 0n ? new Date(Number(borrowable[1]) * 1000).toLocaleString() : "-"}</td>
            </tr>
          </tbody>
        </table>
      )}
      <h3>Borrow (agent key only)</h3>
      <div className="row">
        <label>
          Borrow to (must be allowlisted)
          <input value={to} placeholder="0x…" onChange={(e) => setTo(e.target.value)} />
        </label>
        <label style={{ flex: "0 1 140px" }}>
          Amount (USDC)
          <input value={amt} onChange={(e) => setAmt(e.target.value)} />
        </label>
        <label style={{ flex: "0 1 140px" }}>
          Memo
          <input value={memo} onChange={(e) => setMemo(e.target.value)} />
        </label>
        <button
          onClick={safe(async () => {
            if (!isAddress(to)) return fail("The recipient is not a valid address.");
            const memoBytes = pad(stringToHex(memo), { size: 32 });
            await run("Borrow", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "borrow",
                args: [to, parseUnits(amt, 6), memoBytes],
              }),
            );
            refetchAgent();
          })}
        >
          Borrow USDC
        </button>
      </div>
      <Hint>
        Borrows USDC from Aave against this vault's collateral and sends it straight to the recipient, with the memo
        recorded on-chain. It only succeeds from the granted agent key, to an allowlisted recipient, within the caps
        and above the health-factor floor. This increases the vault's debt.
      </Hint>
      {usdc && <h3>Repay</h3>}
      {usdc && (
        <div className="row">
          <label>
            Repay USDC (anyone can repay)
            <input value={repayAmt} onChange={(e) => setRepayAmt(e.target.value)} />
          </label>
          <button
            onClick={safe(async () => {
              const a = parseUnits(repayAmt, 6);
              if (
                await run("Approve USDC", () =>
                  writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [vault, a] }),
                )
              )
                await run("Repay", () =>
                  writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "repay", args: [a] }),
                );
              refetchAgent();
            })}
          >
            Approve + repay
          </button>
        </div>
      )}
      {usdc && (
        <Hint>
          Two confirmations: approve exactly this amount of USDC to the vault, then repay. USDC leaves your wallet and
          reduces the vault's Aave debt.
        </Hint>
      )}
      {status}
    </div>
  );
}
