// Wallet page: balances, demo faucets (mock USDT / DAI), wrap & unwrap ETH <-> WETH, allowances overview.
import { state } from "../state.js";
import { tokens, pm, book, withSigner, sendTx, readProvider, nameOf, cfg } from "../chain.js";
import { esc, fmtUnits, fmtToken, parseAmount, shortAddr } from "../format.js";
import { $, setHTML, withButton } from "../ui.js";

const { ethers } = window;

export async function mount(root) {
  root.innerHTML = `
    <div class="page-head"><div><h1>Wallet</h1><p>Balances of the connected account, demo faucets and ETH ⇄ WETH wrapping. Collateral tokens keep their native decimals end to end (USDT has 6, DAI and WETH 18).</p></div></div>
    <div class="detail-grid">
      <div class="card"><div class="card-head"><h3 id="w-title">Balances</h3></div><div class="card-body" id="w-balances"></div></div>
      <div class="side">
        <div class="card card-pad" id="w-faucet"></div>
        <div class="card card-pad" id="w-wrap"></div>
      </div>
    </div>`;

  const wethT = tokens.find((t) => t.kind === "weth");
  let built = false;

  function build() {
    setHTML(
      $("#w-faucet", root),
      `<h3>Faucet</h3><p class="small text-2" style="margin-top:6px">Mock stablecoins for the demo (anyone can mint on the local chain / testnet mocks).</p>
       <div class="stack" style="gap:8px;margin-top:10px">${tokens
         .filter((t) => t.kind === "faucet")
         .map((t) => `<button class="btn block" data-faucet="${t.symbol}" data-testid="faucet-${t.symbol}">Get 10,000 ${esc(t.symbol)}</button>`)
         .join("")}</div>`,
    );
    setHTML(
      $("#w-wrap", root),
      wethT
        ? `<h3>Wrap ETH</h3><p class="small text-2" style="margin-top:6px">WETH is an ERC-20 version of ETH, usable as market collateral.</p>
           <div class="input-group" style="margin-top:10px"><input id="w-amt" inputmode="decimal" value="1" data-testid="wrap-amount"><span class="suffix">ETH</span></div>
           <div class="row" style="margin-top:8px"><button class="btn primary grow" id="w-wrap-btn" data-testid="wrap-button">Wrap → WETH</button><button class="btn grow" id="w-unwrap-btn">Unwrap</button></div>`
        : "",
    );
    root.addEventListener("click", (e) => {
      const f = e.target.closest("[data-faucet]");
      if (f) {
        const t = tokens.find((x) => x.symbol === f.dataset.faucet);
        withButton(f, () => sendTx(`Faucet: 10,000 ${t.symbol}`, () => withSigner(t.contract).faucet()));
      }
    });
    if (wethT) {
      $("#w-wrap-btn", root).onclick = (e) =>
        withButton(e.currentTarget, async () => {
          const v = parseAmount($("#w-amt", root).value, 18);
          if (!v) return;
          await sendTx(`Wrap ${ethers.formatEther(v)} ETH`, () => withSigner(wethT.contract).deposit({ value: v }));
        });
      $("#w-unwrap-btn", root).onclick = (e) =>
        withButton(e.currentTarget, async () => {
          const v = parseAmount($("#w-amt", root).value, 18);
          if (!v) return;
          await sendTx(`Unwrap ${ethers.formatEther(v)} WETH`, () => withSigner(wethT.contract).withdraw(v));
        });
    }
    built = true;
  }

  const refresh = async () => {
    const me = state.wallet.address;
    $("#w-title", root).textContent = me ? `Balances · ${nameOf(me)} (${shortAddr(me)})` : "Balances";
    if (!built) build();
    if (!me) {
      setHTML($("#w-balances", root), '<p class="muted">Connect a wallet (top right) to see balances.</p>');
      return;
    }
    const [eth, allowances] = await Promise.all([
      readProvider.getBalance(me),
      Promise.all(tokens.map((t) => Promise.all([t.contract.allowance(me, pm.target), t.contract.allowance(me, book.target)]))),
    ]);
    const approvedBook = await pm.isApprovedForAll(me, book.target);
    const allowanceText = (a, t) => (a === ethers.MaxUint256 ? "unlimited" : a === 0n ? "—" : fmtToken(a, t));
    setHTML(
      $("#w-balances", root),
      `<table class="tbl" data-testid="balances-table"><thead><tr><th>Asset</th><th>Contract</th><th class="r">Decimals</th><th class="r">Balance</th><th class="r">Allowance → market</th><th class="r">Allowance → order book</th></tr></thead><tbody>
        <tr><td><b>ETH</b></td><td class="muted small">native</td><td class="r">18</td><td class="r"><b>${fmtUnits(eth, 18, 4)}</b></td><td class="r">—</td><td class="r">—</td></tr>
        ${tokens
          .map(
            (t, i) => `<tr><td><b>${esc(t.symbol)}</b><div class="tiny muted">${esc(t.name)}</div></td><td class="mono small nowrap">${shortAddr(t.address)}</td><td class="r">${t.decimals}</td>
              <td class="r"><b data-testid="wallet-bal-${t.symbol}">${fmtToken(state.balances[t.symbol] ?? 0n, t, { symbol: false })}</b></td>
              <td class="r small">${allowanceText(allowances[i][0], t)}</td><td class="r small">${allowanceText(allowances[i][1], t)}</td></tr>`,
          )
          .join("")}
      </tbody></table>
      <p class="small text-2" style="margin-top:12px">Outcome shares (ERC-1155) — order book operator approval: <b>${approvedBook ? "granted" : "not granted"}</b>. The app requests exact-amount ERC-20 approvals when you trade (USDT's non-zero → non-zero approval rule is handled by resetting to 0 first).</p>
      <p class="small text-2" style="margin-top:6px">Network: ${esc(cfg.chainName)} (chainId ${cfg.chainId}) · RPC <span class="mono">${esc(cfg.rpcUrl)}</span></p>`,
    );
  };
  await refresh();
  return { refresh, unmount() {} };
}
