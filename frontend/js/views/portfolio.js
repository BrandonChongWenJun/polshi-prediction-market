// Portfolio: outcome positions, redeemable winnings, LP positions and open P2P orders of the connected account.
import { state } from "../state.js";
import { pm, book, withSigner, sendTx, tokens } from "../chain.js";
import { fetchMarkets, fetchPosition, fetchOrders, phaseInfo, PHASE, SIDE, ORDER_STATUS } from "../data.js";
import { esc, pct, fmtToken, fmtShares, fmtUnits, displayDecimals } from "../format.js";
import { $, setHTML, seriesColor, withButton } from "../ui.js";

export async function mount(root) {
  root.innerHTML = `
    <div class="page-head"><div><h1>Portfolio</h1><p>Your outcome shares, winnings, liquidity positions and open peer-to-peer orders across all markets.</p></div></div>
    <div class="tiles" id="p-tiles"></div>
    <div class="stack">
      <div class="card"><div class="card-head"><h3>Redeemable winnings</h3></div><div class="card-body" id="p-redeem"></div></div>
      <div class="card"><div class="card-head"><h3>Outcome positions</h3></div><div class="card-body" id="p-positions"></div></div>
      <div class="card"><div class="card-head"><h3>Liquidity positions</h3></div><div class="card-body" id="p-lp"></div></div>
      <div class="card"><div class="card-head"><h3>Open orders</h3></div><div class="card-body" id="p-orders"></div></div>
    </div>`;

  root.addEventListener("click", (e) => {
    const r = e.target.closest("[data-redeem]");
    if (r) return withButton(r, () => sendTx(`Redeem market #${r.dataset.redeem}`, () => withSigner(pm).redeem(BigInt(r.dataset.redeem))));
    const f = e.target.closest("[data-claim]");
    if (f) return withButton(f, () => sendTx(`Claim fees #${f.dataset.claim}`, () => withSigner(pm).claimFees(BigInt(f.dataset.claim))));
    const c = e.target.closest("[data-cancel]");
    if (c) return withButton(c, () => sendTx(`Cancel order #${c.dataset.cancel}`, () => withSigner(book).cancelOrder(BigInt(c.dataset.cancel))));
  });

  const refresh = async () => {
    const me = state.wallet.address;
    if (!me) {
      setHTML($("#p-tiles", root), "");
      ["#p-redeem", "#p-positions", "#p-lp", "#p-orders"].forEach((s) => setHTML($(s, root), '<p class="muted">Connect a wallet to see your portfolio.</p>'));
      return;
    }
    const markets = await fetchMarkets();
    const [positions, orderLists] = await Promise.all([
      Promise.all(markets.map((m) => fetchPosition(m.id, me))),
      Promise.all(markets.map((m) => fetchOrders(m.id))),
    ]);
    const now = state.chain.time;
    const posRows = [];
    const redeemRows = [];
    const lpRows = [];
    const orderRows = [];
    const valueByToken = {};
    markets.forEach((m, k) => {
      const p = positions[k];
      const t = m.token;
      const link = `<a href="#/market/${m.id}">${esc(m.question)}</a>`;
      const ph = phaseInfo(m);
      p.balances.forEach((b, i) => {
        if (b === 0n) return;
        let value;
        if (m.resolved) value = m.outcome === 255 ? Number(b) / m.n : m.outcome === i ? Number(b) : 0;
        else value = Number(b) * m.prices[i];
        valueByToken[t.symbol] = (valueByToken[t.symbol] || 0) + value;
        posRows.push(`<tr data-testid="position-${m.id}-${i}"><td>${link}</td><td class="nowrap"><span class="keydot" style="background:${seriesColor(i)}"></span> ${esc(m.labels[i])}</td>
          <td class="r">${fmtShares(b, t)}</td><td class="r">${m.resolved ? "—" : pct(m.prices[i], 1)}</td>
          <td class="r">${fmtUnits(BigInt(Math.floor(value)), t.decimals, displayDecimals(t))} ${esc(t.symbol)}</td>
          <td><span class="badge ${ph.key}">${esc(ph.text)}</span></td></tr>`);
      });
      if (p.redeemable > 0n) {
        redeemRows.push(`<tr><td>${link}</td><td><span class="badge ${ph.key}">${esc(ph.text)}</span></td><td class="r"><b>${fmtToken(p.redeemable, t)}</b></td>
          <td class="r"><button class="btn good sm" data-redeem="${m.id}" data-testid="portfolio-redeem-${m.id}">Redeem</button></td></tr>`);
      }
      if (p.lpShares > 0n) {
        lpRows.push(`<tr><td>${link}</td><td class="r">${fmtShares(p.lpShares, t)}</td><td class="r">${((Number(p.lpShares) / Number(m.totalLpShares || 1n)) * 100).toFixed(1)}%</td>
          <td class="r">${fmtToken(p.pendingFees, t)}</td>
          <td class="r">${p.pendingFees > 0n ? `<button class="btn sm" data-claim="${m.id}" data-testid="portfolio-claim-${m.id}">Claim fees</button>` : ""} <a class="btn sm" href="#/market/${m.id}">Manage</a></td></tr>`);
      }
      orderLists[k]
        .filter((o) => o.maker.toLowerCase() === me.toLowerCase() && o.status === ORDER_STATUS.Open)
        .forEach((o) => {
          const expired = o.expiry && o.expiry <= now;
          orderRows.push(`<tr><td>${link}</td><td>${o.side === SIDE.Buy ? "Buy" : "Sell"} <span class="keydot" style="background:${seriesColor(o.outcome)}"></span> ${esc(m.labels[o.outcome])}</td>
            <td class="r">${(o.price / 10_000).toFixed(4)}</td><td class="r">${fmtShares(o.remaining, t)} / ${fmtShares(o.amount, t)}</td>
            <td>${expired ? '<span class="badge timedout">expired</span>' : m.resolved ? '<span class="badge closed">market resolved</span>' : '<span class="badge trading">open</span>'}</td>
            <td class="r"><button class="btn sm" data-cancel="${o.id}">Cancel</button></td></tr>`);
        });
    });
    const valueText = Object.entries(valueByToken)
      .map(([sym, v]) => {
        const t = tokens.find((x) => x.symbol === sym);
        return `${fmtUnits(BigInt(Math.floor(v)), t.decimals, displayDecimals(t))} ${sym}`;
      })
      .join(" · ");
    setHTML(
      $("#p-tiles", root),
      `<div class="card tile"><div class="t-label">Positions</div><div class="t-value">${posRows.length}</div><div class="t-sub">${esc(valueText || "no open positions")}</div></div>
       <div class="card tile"><div class="t-label">Redeemable</div><div class="t-value">${redeemRows.length}</div><div class="t-sub">resolved markets with winnings</div></div>
       <div class="card tile"><div class="t-label">LP positions</div><div class="t-value">${lpRows.length}</div><div class="t-sub">earning trading fees</div></div>
       <div class="card tile"><div class="t-label">Open orders</div><div class="t-value">${orderRows.length}</div><div class="t-sub">escrowed in the order book</div></div>`,
    );
    const tbl = (head, rows, empty) =>
      rows.length ? `<table class="tbl"><thead><tr>${head}</tr></thead><tbody>${rows.join("")}</tbody></table>` : `<p class="muted small">${empty}</p>`;
    setHTML($("#p-redeem", root), tbl("<th>Market</th><th>Result</th><th class='r'>Payout</th><th></th>", redeemRows, "Nothing to redeem right now."));
    setHTML(
      $("#p-positions", root),
      tbl("<th>Market</th><th>Outcome</th><th class='r'>Shares</th><th class='r'>Price</th><th class='r'>Value</th><th>Status</th>", posRows, "You hold no outcome shares."),
    );
    setHTML($("#p-lp", root), tbl("<th>Market</th><th class='r'>LP shares</th><th class='r'>Pool share</th><th class='r'>Unclaimed fees</th><th></th>", lpRows, "You are not providing liquidity."));
    setHTML($("#p-orders", root), tbl("<th>Market</th><th>Order</th><th class='r'>Price</th><th class='r'>Remaining</th><th>Status</th><th></th>", orderRows, "No open orders."));
  };
  await refresh();
  return { refresh, unmount() {} };
}
