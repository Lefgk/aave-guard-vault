import { useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, pad, parseUnits, stringToHex, type Address } from "viem";
import { aaveGuardVaultAbi, aaveGuardVaultFactoryAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
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
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <div className="wrap">
      <h1>Aave Guard Vault</h1>
      <div className="muted">
        Supply ETH, WETH or USDC to Aave V3. Agents borrow USDC to allowlisted destinations within caps, only if the
        health factor stays above your floor. Prototype — not audited. Ethereum, Base and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.factory && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the factory address is empty. Core flows stay disabled until
            you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>), which writes the address into{" "}
            <code>web/src/deployments.json</code>. You can still paste an existing vault address below after connecting.
          </div>
        )}
        {deployments[chainId]?.live && dep.factory && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited. Collateral on Aave can be liquidated if health
            factor falls below 1. Only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

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
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

function VaultPicker(props: {
  owner: Address;
  factory?: Address;
  vault: string;
  setVault: (v: Address | "") => void;
}) {
  const { owner, factory, vault, setVault } = props;
  const { data: vaults, refetch } = useReadContract({
    address: factory,
    abi: aaveGuardVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run } = useTx();
  return (
    <div className="card">
      <h2>1. Vault</h2>
      {!factory && (
        <div className="warn">
          <strong>Not deployed yet.</strong> No factory address for this chain. Deploy first (see DEPLOY.md), or set
          VITE_FACTORY_* in web/.env.
        </div>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={async () => {
            if (
              await run("Create vault", () =>
                writeContractAsync({ address: factory!, abi: aaveGuardVaultFactoryAbi, functionName: "createVault" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setVault(list[list.length - 1]);
            }
          }}
        >
          Create new vault
        </button>
        <label>
          Or use vault address
          <input value={vault} placeholder="0x…" onChange={(e) => setVault(e.target.value as Address)} />
        </label>
      </div>
      {vaults && vaults.length > 0 && (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "" : "ghost"} onClick={() => setVault(v)}>
              {short(v)}
            </button>
          ))}
        </div>
      )}
      <div className="muted">{status}</div>
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
  const { writeContractAsync, status, run } = useTx();
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
      <h2>2. Position</h2>
      <div className="muted">
        Vault <code>{vault}</code> · owner <code>{short(owner)}</code> ·{" "}
        {paused ? <span className="bad">PAUSED</span> : <span className="ok">active</span>}
      </div>
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

      <div className="row" style={{ marginTop: 8 }}>
        <label>
          Supply ETH
          <input value={ethAmt} onChange={(e) => setEthAmt(e.target.value)} />
        </label>
        <button
          onClick={async () => {
            await run("Supply ETH", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "supplyETH",
                value: parseUnits(ethAmt, 18),
              }),
            );
            refresh();
          }}
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
              onClick={async () => {
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
              }}
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
            onClick={async () => {
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
            }}
          >
            Approve + supply USDC
          </button>
        </div>
      )}
      <div className="row">
        <label>
          Withdraw ETH
          <input value={wdEth} onChange={(e) => setWdEth(e.target.value)} />
        </label>
        <button
          className="ghost"
          onClick={async () => {
            await run("Withdraw ETH", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "withdrawETH",
                args: [owner ?? vault, parseUnits(wdEth, 18)],
              }),
            );
            refresh();
          }}
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
              onClick={async () => {
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
              }}
            >
              Approve + repay
            </button>
          </>
        )}
      </div>
      <div className="row">
        <label>
          Health-factor floor
          <input value={floor} onChange={(e) => setFloor(e.target.value)} />
        </label>
        <button
          className="ghost"
          onClick={async () => {
            await run("Set floor", () =>
              writeContractAsync({
                address: vault,
                abi: aaveGuardVaultAbi,
                functionName: "setHealthFactorFloor",
                args: [parseUnits(floor, 18)],
              }),
            );
            refresh();
          }}
        >
          Set floor
        </button>
        {paused ? (
          <button
            onClick={async () => {
              await run("Unpause", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "unpause" }),
              );
              refresh();
            }}
          >
            Unpause
          </button>
        ) : (
          <button
            className="danger"
            onClick={async () => {
              await run("Pause", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "pause" }),
              );
              refresh();
            }}
          >
            Pause agents
          </button>
        )}
      </div>
      <div className="muted">{status}</div>
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
  const { writeContractAsync, status, run } = useTx();

  const submit = async () => {
    if (!isAddress(agent)) return alert("Agent address is invalid");
    const recips = recipients.split(/[\s,]+/).filter(Boolean);
    if (recips.some((r) => !isAddress(r))) return alert("A recipient address is invalid");
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
      <button onClick={submit}>Grant + set caps + allowlist</button>
      <div className="muted">{status}</div>
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
  const { writeContractAsync, status, run } = useTx();

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
      <h2>4. Agent: caps, borrow, repay</h2>
      <div className="row">
        <label>
          Agent to inspect (defaults to connected wallet)
          <input value={lookup} placeholder={address ?? "0x…"} onChange={(e) => setLookup(e.target.value)} />
        </label>
        {agent && rec && (
          <button
            className="danger"
            onClick={async () => {
              await run("Revoke", () =>
                writeContractAsync({ address: vault, abi: aaveGuardVaultAbi, functionName: "revokeAgent", args: [agent] }),
              );
              refetchAgent();
            }}
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
      <div className="row" style={{ marginTop: 8 }}>
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
          onClick={async () => {
            if (!isAddress(to)) return alert("Recipient is invalid");
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
          }}
        >
          Borrow USDC
        </button>
      </div>
      {usdc && (
        <div className="row">
          <label>
            Repay USDC (anyone can repay)
            <input value={repayAmt} onChange={(e) => setRepayAmt(e.target.value)} />
          </label>
          <button
            onClick={async () => {
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
            }}
          >
            Approve + repay
          </button>
        </div>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}
