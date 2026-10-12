// Market detail: outcomes, probability chart, trade (buy/sell with price-impact preview), P2P order book,
// activity, liquidity & complete sets, resolution (arbitrator report / reputation vote / timeout / redeem).
import { state, saveSetting } from "../state.js";
import {
  pm, book, oracle, INVALID, nameOf, sameAddr, withSigner, sendTx, ensureAllowance, ensureShareApproval, avatarColor,
} from "../chain.js";
import {
  fetchMarket, fetchPosition, fetchOrders, fetchRound, fetchReporter, fetchHistory, fetchOracleParams, phaseInfo,
  outcomeName, PHASE, SIDE, ORDER_STATUS, ROUND,
} from "../data.js";
import {
  esc, pct, fmtToken, fmtShares, fmtUnits, fmtDate, fmtRelative, fmtDuration, parseAmount, toInput, pricesFromPool,
  shortAddr, displayDecimals,
} from "../format.js";
import { $, $$, setHTML, seriesColor, withButton, toast } from "../ui.js";
import { ProbabilityChart } from "../chart.js";

const PRICE_SCALE = 10_000n;
const RANGES = { "1D": 86400, "1W": 7 * 86400, "1M": 30 * 86400, All: 0 };

function who(addr) {
  return `<span class="who"><span class="avatar" style="width:20px;height:20px;font-size:10px;background:${avatarColor(addr)}">${esc(nameOf(addr)[0] === "0" ? "?" : nameOf(addr)[0])}</span>${esc(nameOf(addr))}</span>`;
}

function impactClass(x) {
  const a = Math.abs(x);
  return a < 0.02 ? "impact-low" : a < 0.08 ? "impact-mid" : "impact-high";
}

export async function mount(root, idStr) {
  const id = Number(idStr);
  const ctx = {
    id,
    m: await fetchMarket(id),
    pos: null,
    orders: [],
    hist: null,
    round: null,
    reporter: null,
    oracleParams: null,
    selected: 0,
    mode: "buy",
    tab: "book",
    range: "All",
    bookOutcome: 0,
    showTable: false,
    quoteSeq: 0,
    quote: null,
    fill: null,
    reportPick: null,
  };
  const m0 = ctx.m;
  if (m0.phase === PHASE.Resolved) ctx.selected = m0.outcome;

  root.innerHTML = `
    <a class="back" href="#/">← All markets</a>
    <div class="detail-head">
      <div>
        <div class="meta-row" id="meta"></div>
        <h1 id="question" data-testid="market-question"></h1>
        <div class="facts" id="facts"></div>
      </div>
    </div>
    <div class="detail-grid">
      <div class="stack">
        <div class="card"><div class="outcomes" id="outcomes" data-testid="outcomes"></div></div>
        <div class="card chart-card">
          <div class="card-head">
            <h3>Probability over time</h3>
            <div class="row">
              <div class="seg" id="range">${Object.keys(RANGES).map((r) => `<button data-r="${r}">${r}</button>`).join("")}</div>
              <button class="btn sm" id="table-toggle" aria-pressed="false">Table view</button>
            </div>
          </div>
          <div id="chart"></div>
          <div id="chart-table" class="chart-table" hidden></div>
        </div>
        <div class="card">
          <div class="tabs" id="tabs">
            <button data-tab="book" data-testid="tab-book">Order book (P2P)<span class="count" id="count-book"></span></button>
            <button data-tab="activity" data-testid="tab-activity">Activity<span class="count" id="count-activity"></span></button>
            <button data-tab="liquidity" data-testid="tab-liquidity">Liquidity & sets</button>
            <button data-tab="rules" data-testid="tab-rules">Rules</button>
          </div>
          <div class="card-body" data-pane="book">
            <div class="row between wrap" style="margin-bottom:10px">
              <div class="chips" id="book-outcomes"></div>
              <span class="hint" id="book-note"></span>
            </div>
            <div class="book-grid" id="book-grid"></div>
            <div id="fill-box" style="margin-top:14px"></div>
            <hr class="divider">
            <div class="grid-2">
              <div id="ord-form-wrap">
                <h3 style="margin-bottom:10px">Place a limit order</h3>
                <div class="stack" style="gap:10px">
                  <div class="seg full" id="ord-side"><button data-side="0" class="active">Buy (bid)</button><button data-side="1">Sell (ask)</button></div>
                  <div class="grid-2">
                    <div class="field"><label for="ord-price">Price per share</label><input class="input" id="ord-price" inputmode="decimal" placeholder="0.45" data-testid="order-price"></div>
                    <div class="field"><label for="ord-amount">Shares</label><input class="input" id="ord-amount" inputmode="decimal" placeholder="100" data-testid="order-amount"></div>
                  </div>
                  <div class="field"><label for="ord-expiry">Expires</label>
                    <select class="input" id="ord-expiry">
                      <option value="close">At market close</option><option value="3600">In 1 hour</option><option value="86400">In 1 day</option>
                      <option value="604800">In 7 days</option><option value="0">Never (until resolution)</option>
                    </select></div>
                  <div class="quote" id="ord-preview"></div>
                  <button class="btn primary block" id="ord-submit" data-testid="order-submit">Place order</button>
                </div>
              </div>
              <div>
                <h3 style="margin-bottom:10px">My orders</h3>
                <div id="my-orders"></div>
              </div>
            </div>
          </div>
          <div class="card-body" data-pane="activity" hidden><div id="activity"></div></div>
          <div class="card-body" data-pane="liquidity" hidden><div id="liquidity"></div></div>
          <div class="card-body" data-pane="rules" hidden><div id="rules"></div></div>
        </div>
      </div>
      <aside class="side">
        <div class="card card-pad trade-card" id="trade" data-testid="trade-panel">
          <div class="row between" style="margin-bottom:12px"><h3>Trade</h3><span class="hint">AMM · instant</span></div>
          <div class="stack" style="gap:12px" id="trade-form">
            <div class="seg full" id="trade-mode"><button data-mode="buy" data-testid="mode-buy">Buy</button><button data-mode="sell" data-testid="mode-sell">Sell</button></div>
            <div class="outcome-pick" id="trade-outcomes"></div>
            <div class="field">
              <div class="row between"><label for="trade-amount" id="trade-label">Amount</label><span class="hint" id="trade-balance"></span></div>
              <div class="input-group"><input id="trade-amount" inputmode="decimal" placeholder="0.00" autocomplete="off" data-testid="trade-amount"><button class="max" id="trade-max" type="button">MAX</button><span class="suffix" id="trade-unit"></span></div>
              <div class="error-text" id="trade-error" data-testid="trade-error"></div>
            </div>
            <div class="quote" id="trade-quote" data-testid="trade-quote"></div>
            <div class="slip" id="slip">Max slippage ${[50, 100, 200, 500].map((b) => `<button data-bps="${b}">${b / 100}%</button>`).join("")}</div>
            <button class="btn primary lg block" id="trade-submit" data-testid="trade-submit">Buy</button>
          </div>
          <div id="trade-closed" class="res-banner info small" hidden data-testid="trade-closed"></div>
        </div>
        <div class="card card-pad" id="resolution" data-testid="resolution-panel"></div>
        <div class="card card-pad" id="position" data-testid="position-panel"></div>
      </aside>
    </div>`;

  const chart = new ProbabilityChart($("#chart", root));
  const el = (s) => $(s, root);

  // ------------------------------------------------------------------ static wiring

  $$("#range button", root).forEach((b) => {
    b.onclick = () => {
      ctx.range = b.dataset.r;
      paintChart();
    };
  });
  el("#table-toggle").onclick = () => {
    ctx.showTable = !ctx.showTable;
    el("#table-toggle").setAttribute("aria-pressed", String(ctx.showTable));
    paintChart();
  };
  $$("#tabs button", root).forEach((b) => {
    b.onclick = () => {
      ctx.tab = b.dataset.tab;
      paintTabs();
    };
  });
  $$("#trade-mode button", root).forEach((b) => {
    b.onclick = () => {
      ctx.mode = b.dataset.mode;
      el("#trade-amount").value = "";
      paintTrade();
      requote();
    };
  });
  el("#trade-outcomes").onclick = (e) => {
    const b = e.target.closest("[data-outcome]");
    if (!b) return;
    ctx.selected = Number(b.dataset.outcome);
    paintTrade();
    paintOutcomes();
    paintChart();
    requote();
  };
  el("#outcomes").onclick = (e) => {
    const r = e.target.closest("[data-outcome]");
    if (!r) return;
    ctx.selected = Number(r.dataset.outcome);
    ctx.bookOutcome = ctx.selected;
    paintOutcomes();
    paintTrade();
    paintChart();
    paintBook();
    requote();
  };
  let quoteTimer = null;
  el("#trade-amount").oninput = () => {
    clearTimeout(quoteTimer);
    quoteTimer = setTimeout(requote, 200);
  };
  el("#trade-max").onclick = () => {
    const m = ctx.m;
    if (ctx.mode === "buy") el("#trade-amount").value = toInput(state.balances[m.token.symbol] ?? 0n, m.token.decimals);
    else el("#trade-amount").value = toInput(ctx.pos?.balances[ctx.selected] ?? 0n, m.token.decimals);
    requote();
  };
  $$("#slip button", root).forEach((b) => {
    b.onclick = () => {
      state.settings.slippageBps = Number(b.dataset.bps);
      saveSetting("slippageBps", state.settings.slippageBps);
      paintTrade();
      requote();
    };
  });
  el("#trade-submit").onclick = (e) => withButton(e.currentTarget, submitTrade);

  // order book
  el("#book-outcomes").onclick = (e) => {
    const b = e.target.closest("[data-outcome]");
    if (!b) return;
    ctx.bookOutcome = Number(b.dataset.outcome);
    paintBook();
  };
  $$("#ord-side button", root).forEach((b) => {
    b.onclick = () => {
      $$("#ord-side button", root).forEach((x) => x.classList.toggle("active", x === b));
      paintOrderPreview();
    };
  });
  ["#ord-price", "#ord-amount", "#ord-expiry"].forEach((s) => (el(s).oninput = paintOrderPreview));
  el("#ord-submit").onclick = (e) => withButton(e.currentTarget, submitOrder);
  el("#book-grid").onclick = (e) => {
    const b = e.target.closest("[data-take]");
    if (!b) return;
    const o = ctx.orders.find((x) => x.id === Number(b.dataset.take));
    if (o) openFill(o);
  };
  el("#my-orders").onclick = (e) => {
    const b = e.target.closest("[data-cancel]");
    if (!b) return;
    withButton(b, () => sendTx(`Cancel order #${b.dataset.cancel}`, () => withSigner(book).cancelOrder(BigInt(b.dataset.cancel))));
  };

  // ------------------------------------------------------------------ painters

  function paintHeader() {
    const m = ctx.m;
    const ph = phaseInfo(m, ctx.round);
    setHTML(
      el("#meta"),
      `<span class="badge cat">${esc(m.category || "General")}</span>
       <span class="badge ${ph.key}" data-testid="phase-badge"><span class="bdot"></span>${esc(ph.text)}</span>
       <span class="badge token" title="${esc(m.token.name)}">${esc(m.token.symbol)} · ${m.token.decimals} decimals</span>
       ${m.isOracle ? '<span class="badge voting">Resolved by reputation-weighted vote</span>' : `<span class="badge closed">Arbitrator: ${esc(nameOf(m.arbitrator))}</span>`}
       <span class="badge closed">#${m.id}</span>`,
    );
    const q = el("#question");
    if (q.textContent !== m.question) q.textContent = m.question;
    const now = state.chain.time;
    setHTML(
      el("#facts"),
      `<span>Volume <b>${fmtToken(m.volume, m.token)}</b></span>
       <span>Collateral locked <b>${fmtToken(m.collateralLocked, m.token)}</b></span>
       <span>LP fee <b>${(m.feeBps / 100).toFixed(2)}%</b></span>
       <span>${now < m.closeTime ? "Closes" : "Closed"} <b>${fmtDate(m.closeTime)}</b> <span class="muted">(${fmtRelative(m.closeTime, now)})</span></span>
       <span>Resolution from <b>${fmtDate(m.resolutionTime)}</b></span>`,
    );
  }

  function paintOutcomes() {
    const m = ctx.m;
    const rows = m.labels
      .map((lab, i) => {
        const won = m.phase === PHASE.Resolved && m.outcome === i;
        return `<div class="outcome-row ${ctx.selected === i ? "selected" : ""}" data-outcome="${i}" data-testid="outcome-row-${i}">
          <div class="oname"><span class="keydot" style="background:${seriesColor(i)}"></span><span>${esc(lab)}</span>${won ? '<span class="win-tag">WINNER</span>' : ""}</div>
          <div class="oprice">${m.prices[i].toFixed(3)} ${esc(m.token.symbol)} / share</div>
          <div class="oprob" data-testid="prob-${i}">${pct(m.prices[i], 1)}</div>
        </div>`;
      })
      .join("");
    setHTML(el("#outcomes"), rows);
  }

  function chartDomain() {
    const m = ctx.m;
    const end = m.resolved ? Math.max(m.resolvedAt, m.createdAt + 1) : Math.max(state.chain.time, m.createdAt + 1);
    const span = RANGES[ctx.range];
    const start = span ? Math.max(m.createdAt, end - span) : m.createdAt;
    return { start, end };
  }

  function paintChart() {
    const m = ctx.m;
    $$("#range button", root).forEach((b) => b.classList.toggle("active", b.dataset.r === ctx.range));
    const points = ctx.hist ? ctx.hist.points : [{ t: m.createdAt, prices: m.prices }];
    const { start, end } = chartDomain();
    chart.setData({
      labels: m.labels,
      points: points.length ? points : [{ t: m.createdAt, prices: m.prices }],
      start,
      end,
      resolvedAt: m.resolved ? m.resolvedAt : 0,
      highlight: m.n > 2 ? ctx.selected : undefined,
    });
    const table = el("#chart-table");
    table.hidden = !ctx.showTable;
    if (ctx.showTable) {
      const rows = points
        .slice(-60)
        .reverse()
        .map((p) => `<tr><td class="nowrap">${fmtDate(p.t)}</td>${p.prices.map((x) => `<td class="r">${pct(x, 1)}</td>`).join("")}</tr>`)
        .join("");
      setHTML(
        table,
        `<table class="tbl"><thead><tr><th>Time</th>${m.labels.map((l) => `<th class="r">${esc(l)}</th>`).join("")}</tr></thead><tbody>${rows}</tbody></table>`,
      );
    }
  }

  function paintTabs() {
    $$("#tabs button", root).forEach((b) => b.classList.toggle("active", b.dataset.tab === ctx.tab));
    $$("[data-pane]", root).forEach((p) => (p.hidden = p.dataset.pane !== ctx.tab));
  }

  function paintTrade() {
    const m = ctx.m;
    const tradable = m.phase === PHASE.Trading && m.totalLpShares > 0n;
    $$("#trade-mode button", root).forEach((b) => b.classList.toggle("active", b.dataset.mode === ctx.mode));
    setHTML(
      el("#trade-outcomes"),
      m.labels
        .map(
          (lab, i) => `<button type="button" class="${ctx.selected === i ? "active" : ""}" data-outcome="${i}" data-testid="pick-${i}">
            <span class="l"><span class="keydot" style="background:${seriesColor(i)}"></span><i>${esc(lab)}</i></span><span class="p">${pct(m.prices[i], 0)}</span></button>`,
        )
        .join(""),
    );
    const t = m.token;
    const lab = m.labels[ctx.selected];
    el("#trade-label").textContent = ctx.mode === "buy" ? `Amount to spend` : `Shares of “${lab}” to sell`;
    el("#trade-unit").textContent = ctx.mode === "buy" ? t.symbol : "shares";
    const bal =
      ctx.mode === "buy"
        ? `Balance: ${fmtToken(state.balances[t.symbol] ?? 0n, t)}`
        : `You hold: ${fmtShares(ctx.pos?.balances[ctx.selected] ?? 0n, t)} shares`;
    el("#trade-balance").textContent = state.wallet.address ? bal : "";
    $$("#slip button", root).forEach((b) => b.classList.toggle("active", Number(b.dataset.bps) === state.settings.slippageBps));
    const submit = el("#trade-submit");
    if (!submit.querySelector(".spinner")) submit.textContent = `${ctx.mode === "buy" ? "Buy" : "Sell"} ${lab}`;
    const closed = el("#trade-closed");
    el("#trade-form").hidden = !tradable;
    closed.hidden = tradable;
    if (!tradable) {
      closed.innerHTML =
        m.totalLpShares === 0n && m.phase === PHASE.Trading
          ? "The AMM pool is empty. Add liquidity (Liquidity tab) to re-open trading."
          : m.resolved
            ? "The market is resolved — AMM trading is over. Redeem winning shares in the panel below."
            : "AMM trading closed at the close time. You can still trade shares peer-to-peer in the order book until the market resolves.";
    }
  }

  async function requote() {
    const m = ctx.m;
    const seq = ++ctx.quoteSeq;
    const t = m.token;
    const q = el("#trade-quote");
    const err = el("#trade-error");
    const submit = el("#trade-submit");
    const raw = el("#trade-amount").value;
    const amt = parseAmount(raw, t.decimals);
    err.textContent = "";
    ctx.quote = null;
    const i = ctx.selected;
    const p0 = m.prices[i];
    if (raw && amt === null) err.textContent = `Enter a valid amount (max ${t.decimals} decimals).`;
    const busy = !!submit.querySelector(".spinner");
    if (!amt || amt === 0n) {
      q.innerHTML = `<div class="qrow"><span>Current price</span><b>${p0.toFixed(3)} ${esc(t.symbol)}</b></div><div class="qrow"><span>Implied probability</span><b>${pct(p0, 1)}</b></div>`;
      if (!busy) submit.disabled = true;
      return;
    }
    try {
      if (ctx.mode === "buy") {
        const [shares, fee] = await pm.calcBuyAmount(m.id, i, amt);
        if (seq !== ctx.quoteSeq) return;
        const net = amt - fee;
        const pool = m.pool.map((b) => b + net);
        pool[i] -= shares;
        const newP = pricesFromPool(pool)[i];
        const avg = Number(amt) / Number(shares || 1n);
        const impact = (avg - p0) / p0;
        const profit = shares - amt;
        q.innerHTML = `
          <div class="qrow big"><span>Shares received</span><b data-testid="quote-shares">${fmtShares(shares, t)}</b></div>
          <div class="qrow"><span>Average price</span><b>${avg.toFixed(4)} ${esc(t.symbol)}</b></div>
          <div class="qrow"><span>Price impact</span><b class="${impactClass(impact)}" data-testid="quote-impact">${impact >= 0 ? "+" : ""}${(impact * 100).toFixed(2)}%</b></div>
          <div class="qrow"><span>Probability after trade</span><b>${pct(p0, 1)} → ${pct(newP, 1)}</b></div>
          <div class="qrow"><span>LP fee (${(m.feeBps / 100).toFixed(1)}%)</span><b>${fmtToken(fee, t)}</b></div>
          <div class="qrow"><span>Payout if “${esc(m.labels[i])}” wins</span><b class="good">${fmtToken(shares, t)} (${profit >= 0n ? "+" : ""}${((Number(profit) / Number(amt)) * 100).toFixed(0)}%)</b></div>`;
        const bal = state.balances[t.symbol] ?? 0n;
        if (state.wallet.address && amt > bal) err.textContent = `Insufficient ${t.symbol} balance (${fmtToken(bal, t)}). Use the faucet on the Wallet page.`;
        ctx.quote = { kind: "buy", amt, out: shares, min: (shares * BigInt(10_000 - state.settings.slippageBps)) / 10_000n };
      } else {
        const held = ctx.pos?.balances[i] ?? 0n;
        const [out, fee] = await pm.calcSellReturn(m.id, i, amt);
        if (seq !== ctx.quoteSeq) return;
        const gross = out + fee;
        const pool = m.pool.slice();
        pool[i] += amt;
        for (let k = 0; k < pool.length; k++) pool[k] -= gross;
        const newP = pool.every((b) => b > 0n) ? pricesFromPool(pool)[i] : p0;
        const avg = Number(out) / Number(amt);
        const impact = (p0 - avg) / p0;
        q.innerHTML = `
          <div class="qrow big"><span>You receive</span><b data-testid="quote-out">${fmtToken(out, t)}</b></div>
          <div class="qrow"><span>Average price</span><b>${avg.toFixed(4)} ${esc(t.symbol)}</b></div>
          <div class="qrow"><span>Price impact</span><b class="${impactClass(impact)}" data-testid="quote-impact">-${(Math.abs(impact) * 100).toFixed(2)}%</b></div>
          <div class="qrow"><span>Probability after trade</span><b>${pct(p0, 1)} → ${pct(newP, 1)}</b></div>
          <div class="qrow"><span>LP fee</span><b>${fmtToken(fee, t)}</b></div>`;
        if (amt > held) err.textContent = `You only hold ${fmtShares(held, t)} “${m.labels[i]}” shares.`;
        if (out === 0n) err.textContent = "Amount too small: it would return nothing after rounding and fees.";
        ctx.quote = { kind: "sell", amt, out, min: (out * BigInt(10_000 - state.settings.slippageBps)) / 10_000n };
      }
      if (!busy) submit.disabled = !state.wallet.address || !!err.textContent;
    } catch (e) {
      if (seq !== ctx.quoteSeq) return;
      q.innerHTML = `<div class="qrow"><span>Quote unavailable</span></div>`;
      err.textContent = "Could not compute a quote for this amount.";
      if (!busy) submit.disabled = true;
    }
  }

  async function submitTrade() {
    await requote();
    const m = ctx.m;
    const qte = ctx.quote;
    if (!qte) return;
    const lab = m.labels[ctx.selected];
    let r;
    if (qte.kind === "buy") {
      if (!(await ensureAllowance(m.token, pm.target, qte.amt))) return;
      r = await sendTx(`Buy ${lab}`, () => withSigner(pm).buy(m.id, ctx.selected, qte.amt, qte.min));
    } else {
      r = await sendTx(`Sell ${lab}`, () => withSigner(pm).sell(m.id, ctx.selected, qte.amt, qte.min));
    }
    if (r) {
      el("#trade-amount").value = "";
      requote();
    }
  }

  function paintPosition() {
    const m = ctx.m;
    const p = ctx.pos;
    const box = el("#position");
    if (!state.wallet.address || !p) {
      setHTML(box, `<h3>Your position</h3><p class="muted small" style="margin-top:6px">Connect a wallet to see your shares.</p>`);
      return;
    }
    const t = m.token;
    const held = p.balances.map((b, i) => ({ b, i })).filter((x) => x.b > 0n);
    const valueOf = (b, i) => (m.resolved ? (m.outcome === INVALID ? Number(b) / m.n : m.outcome === i ? Number(b) : 0) : Number(b) * m.prices[i]);
    const total = held.reduce((a, x) => a + valueOf(x.b, x.i), 0);
    const rows = held.length
      ? held
          .map(
            ({ b, i }) => `<div class="prow"><span><span class="keydot" style="background:${seriesColor(i)}"></span>${esc(m.labels[i])}</span>
              <b class="num" data-testid="pos-${i}">${fmtShares(b, t)} <span class="muted small">≈ ${fmtUnits(BigInt(Math.floor(valueOf(b, i))), t.decimals, displayDecimals(t))} ${esc(t.symbol)}</span></b></div>`,
          )
          .join("")
      : `<p class="muted small">No outcome shares in this market.</p>`;
    const lp =
      p.lpShares > 0n
        ? `<hr class="divider"><div class="prow"><span>LP shares</span><b class="num">${fmtShares(p.lpShares, t)} (${((Number(p.lpShares) / Number(m.totalLpShares || 1n)) * 100).toFixed(1)}%)</b></div>
           <div class="prow"><span>Unclaimed LP fees</span><b class="num">${fmtToken(p.pendingFees, t)}</b></div>
           ${p.pendingFees > 0n ? '<button class="btn sm" id="claim-fees" style="margin-top:6px">Claim fees</button>' : ""}`
        : "";
    const redeem =
      m.resolved && p.redeemable > 0n
        ? `<button class="btn good block" id="redeem-btn" style="margin-top:10px" data-testid="redeem-button">Redeem ${fmtToken(p.redeemable, t)}</button>`
        : "";
    setHTML(
      box,
      `<div class="row between"><h3>Your position</h3><span class="small muted">${held.length ? `≈ ${fmtUnits(BigInt(Math.floor(total)), t.decimals, displayDecimals(t))} ${esc(t.symbol)}` : ""}</span></div>
       <div class="position-list" style="margin-top:10px">${rows}${lp}</div>${redeem}`,
    );
    const rb = el("#redeem-btn");
    const redeemLabel = m.outcome === INVALID ? "Redeem pro-rata refund" : "Redeem winnings";
    if (rb) rb.onclick = (e) => withButton(e.currentTarget, () => sendTx(redeemLabel, () => withSigner(pm).redeem(m.id)));
    const cf = el("#claim-fees");
    if (cf) cf.onclick = (e) => withButton(e.currentTarget, () => sendTx("Claim LP fees", () => withSigner(pm).claimFees(m.id)));
  }

  // ------------------------------------------------------------------ resolution panel

  function timelineHTML() {
    const m = ctx.m;
    const now = state.chain.time;
    const deadline = m.resolutionTime + 7 * 86400;
    const steps = [
      { label: "Market opened", t: m.createdAt },
      { label: "Trading closes", t: m.closeTime },
      { label: m.isOracle ? "Reporter voting opens" : "Arbitrator may report", t: m.resolutionTime },
    ];
    if (m.isOracle && ctx.round) steps.push({ label: ctx.round.extended ? "Voting ends (extended)" : "Voting ends", t: ctx.round.votingEnd });
    if (m.resolved) steps.push({ label: m.outcome === INVALID ? "Resolved INVALID" : `Resolved: ${m.labels[m.outcome]}`, t: m.resolvedAt });
    else steps.push({ label: "Arbitration deadline (then invalid)", t: deadline });
    let nowIdx = steps.findIndex((s) => s.t > now);
    if (nowIdx === -1) nowIdx = steps.length;
    return `<div class="timeline">${steps
      .map(
        (s, k) => `<div class="tl-step ${k < nowIdx ? "done" : k === nowIdx ? "now" : ""}"><span class="tl-dot"></span><span>${esc(s.label)}</span><span class="tl-when" title="${fmtDate(s.t)}">${fmtDate(s.t, { year: false })}</span></div>`,
      )
      .join("")}</div>`;
  }

  function paintResolution() {
    const m = ctx.m;
    const box = el("#resolution");
    const me = state.wallet.address;
    const now = state.chain.time;
    let body = "";
    if (m.phase === PHASE.Resolved || m.phase === PHASE.Invalid) {
      body =
        m.phase === PHASE.Resolved
          ? `<div class="res-banner good" data-testid="resolved-banner"><b>Resolved: ${esc(m.labels[m.outcome])}</b><br>Each “${esc(m.labels[m.outcome])}” share redeems for 1 ${esc(m.token.symbol)}. Other shares are worth 0.</div>`
          : `<div class="res-banner bad" data-testid="resolved-banner"><b>Resolved as INVALID</b><br>Every share of any outcome redeems for 1/${m.n} ${esc(m.token.symbol)} (pro-rata refund — complete sets and LPs are made whole).</div>`;
      const timedOut = m.resolvedAt >= m.resolutionTime + 7 * 86400; // reports are only accepted before this deadline
      const by = timedOut
        ? "after the arbitrator missed the 7-day reporting deadline (permissionless timeout)"
        : `by ${esc(m.isOracle ? "the reputation oracle (reporter vote)" : nameOf(m.arbitrator))}`;
      body += `<p class="small text-2" style="margin-top:8px">Resolved ${fmtDate(m.resolvedAt)} ${by}.</p>`;
    } else if (m.phase === PHASE.TimedOut) {
      body = `<div class="res-banner bad"><b>The arbitrator missed the deadline.</b><br>No outcome was reported within 7 days of the resolution time, so anyone can now resolve the market as INVALID (pro-rata refund).</div>
        <button class="btn bad block" id="timeout-btn" style="margin-top:10px" data-testid="timeout-button">Resolve as invalid</button>`;
    } else if (m.isOracle) {
      body = voteHTML();
    } else if (m.phase === PHASE.Reporting) {
      if (sameAddr(me, m.arbitrator)) {
        body = `<div class="res-banner warn"><b>You are the arbitrator.</b> Report the real-world outcome. This is final.</div>
          <div class="report-grid" style="margin-top:10px">${m.labels
            .map((l, i) => `<button class="btn ${ctx.reportPick === i ? "primary" : ""}" data-report="${i}" data-testid="report-${i}">${esc(l)}</button>`)
            .join("")}<button class="btn ${ctx.reportPick === INVALID ? "bad" : ""}" data-report="${INVALID}" data-testid="report-invalid">Invalid / cancelled</button></div>
          <button class="btn primary block" id="report-submit" style="margin-top:10px" data-testid="report-submit" ${ctx.reportPick === null ? "disabled" : ""}>
            ${ctx.reportPick === null ? "Select the outcome to report" : `Report “${esc(outcomeName(m, ctx.reportPick))}”`}</button>`;
      } else {
        body = `<div class="res-banner warn">Waiting for the arbitrator <b>${esc(nameOf(m.arbitrator))}</b> (<span class="mono">${shortAddr(m.arbitrator)}</span>) to report. If nothing is reported by <b>${fmtDate(m.resolutionTime + 7 * 86400)}</b> the market becomes invalid.</div>`;
      }
    } else if (m.phase === PHASE.Closed) {
      body = `<div class="res-banner info">Trading is closed. ${m.isOracle ? "Reporters can vote" : `${esc(nameOf(m.arbitrator))} can report`} from <b>${fmtDate(m.resolutionTime)}</b> (${fmtRelative(m.resolutionTime, now)}).</div>`;
    } else {
      body = `<div class="res-banner info">Resolution by <b>${m.isOracle ? "reputation-weighted reporter vote" : `arbitrator ${esc(nameOf(m.arbitrator))}`}</b> after ${fmtDate(m.resolutionTime)}.</div>`;
    }
    setHTML(box, `<h3>Resolution</h3><div style="margin-top:10px">${timelineHTML()}</div><div style="margin-top:12px">${body}</div>`);
    wireResolution();
  }

  function voteHTML() {
    const m = ctx.m;
    const r = ctx.round;
    const me = state.wallet.address;
    const now = state.chain.time;
    if (!r) return `<p class="muted small">Loading vote…</p>`;
    const params = ctx.oracleParams;
    if (now < r.votingStart && r.voterCount === 0) {
      return `<div class="res-banner violet small" data-testid="vote-status">Resolved by <b>reputation-weighted reporter vote</b>.
        Voting opens ${fmtRelative(r.votingStart, now)} (${fmtDate(r.votingStart)}) and lasts ${fmtDuration(params?.votingPeriod ?? 86400)};
        a quorum of ${params ? params.quorumBps / 100 : 50}% of total reputation (currently ${r.requiredWeight} of ${r.snapshotTotal} rep) must vote.</div>`;
    }
    const labels = [...m.labels, "Invalid"];
    const maxW = r.tally.reduce((a, b) => (b > a ? b : a), 0n);
    const bars = r.tally
      .map((w, k) => {
        const share = r.totalWeight > 0n ? Number(w) / Number(r.totalWeight) : 0;
        const col = k === m.n ? "var(--muted)" : seriesColor(k);
        return `<div class="vote-bar"><span>${esc(labels[k])}</span><b class="num">${w.toString()} rep${w > 0n && w === maxW ? " ▲" : ""}</b>
          <div class="vb-track"><i style="width:${(share * 100).toFixed(1)}%;background:${col}"></i></div></div>`;
      })
      .join("");
    const qPct = r.requiredWeight > 0n ? Math.min(1, Number(r.totalWeight) / Number(r.requiredWeight)) : 0;
    const quorumMark = r.snapshotTotal > 0n ? Number(r.requiredWeight) / Number(r.snapshotTotal) : 0.5;
    const turnout = r.snapshotTotal > 0n ? Number(r.totalWeight) / Number(r.snapshotTotal) : 0;
    const open = now >= r.votingStart && now < r.votingEnd && r.status === ROUND.Pending && !m.resolved;
    const myVote = r.votes.find((v) => sameAddr(v.voter, me));
    const canVote = open && ctx.reporter?.registered && ctx.reporter.reputation > 0 && !myVote;
    let status;
    if (r.status !== ROUND.Pending) status = `Round closed (${["pending", "consensus", "no consensus → invalid", "voided"][r.status]}).`;
    else if (now < r.votingStart) status = `Voting opens ${fmtRelative(r.votingStart, now)} (${fmtDate(r.votingStart)}).`;
    else if (open) status = `Voting open — ends ${fmtRelative(r.votingEnd, now)} (${fmtDate(r.votingEnd)})${r.extended ? " · extended once" : ""}.`;
    else status = `Voting ended ${fmtRelative(r.votingEnd, now)}. Anyone can finalize.`;
    const votes = r.votes.length
      ? `<table class="tbl" style="margin-top:8px"><thead><tr><th>Reporter</th><th>Vote</th><th class="r">Weight</th></tr></thead><tbody>${r.votes
          .map((v) => `<tr><td>${who(v.voter)}</td><td>${esc(outcomeName(m, v.outcome))}</td><td class="r">${v.weight.toString()}</td></tr>`)
          .join("")}</tbody></table>`
      : `<p class="small muted" style="margin-top:6px">No votes yet.</p>`;
    let actions = "";
    if (canVote) {
      actions = `<div class="label" style="margin-top:12px">Cast your vote (weight = your reputation, ${ctx.reporter.reputation})</div>
        <div class="report-grid" style="margin-top:6px">${m.labels
          .map((l, i) => `<button class="btn" data-vote="${i}" data-testid="vote-${i}">${esc(l)}</button>`)
          .join("")}<button class="btn" data-vote="${INVALID}" data-testid="vote-invalid">Invalid</button></div>`;
    } else if (open && myVote) {
      actions = `<div class="res-banner violet small" style="margin-top:10px">You voted <b>${esc(outcomeName(m, myVote.outcome))}</b> with weight ${myVote.weight}.</div>`;
    } else if (open && me && !ctx.reporter?.registered) {
      actions = `<p class="small muted" style="margin-top:10px">Only registered reporters can vote. Switch to Eve, Frank, Grace or Heidi (local demo wallet).</p>`;
    }
    if (r.status === ROUND.Pending && now >= r.votingEnd && !m.resolved) {
      actions += `<button class="btn primary block" id="finalize-btn" style="margin-top:10px" data-testid="finalize-button">Finalize vote</button>
        <p class="hint" style="margin-top:6px">No quorum or a tie extends voting once by ${fmtDuration(params?.votingPeriod ?? 86400)}; if it is still undecided the market resolves INVALID.</p>`;
    }
    return `<div class="res-banner violet small" data-testid="vote-status">${esc(status)}</div>
      <div class="row between small" style="margin-top:12px"><span class="text-2">Quorum ${params ? params.quorumBps / 100 : 50}% of reputation</span><b class="num">${r.totalWeight} / ${r.requiredWeight} rep</b></div>
      <div class="quorum" style="margin-top:6px" title="turnout ${(turnout * 100).toFixed(0)}%"><i style="width:${(Math.min(1, turnout) * 100).toFixed(1)}%"></i><span class="qmark" style="left:${(quorumMark * 100).toFixed(1)}%"></span></div>
      <div class="hint" style="margin-top:4px">${qPct >= 1 ? "Quorum reached." : "Quorum not reached yet."}</div>
      <div class="vote-bars" style="margin-top:12px">${bars}</div>
      ${votes}${actions}`;
  }

  function wireResolution() {
    const m = ctx.m;
    const box = el("#resolution");
    $$("[data-report]", box).forEach((b) => {
      b.onclick = () => {
        ctx.reportPick = Number(b.dataset.report);
        paintResolution();
      };
    });
    const rs = $("#report-submit", box);
    if (rs)
      rs.onclick = (e) =>
        withButton(e.currentTarget, async () => {
          const pick = ctx.reportPick;
          const r = await sendTx(`Report “${outcomeName(m, pick)}”`, () => withSigner(pm).reportOutcome(m.id, pick));
          if (r) ctx.reportPick = null;
        });
    $$("[data-vote]", box).forEach((b) => {
      b.onclick = () =>
        withButton(b, () => sendTx(`Vote “${outcomeName(m, Number(b.dataset.vote))}”`, () => withSigner(oracle).vote(m.id, Number(b.dataset.vote))));
    });
    const fb = $("#finalize-btn", box);
    if (fb) fb.onclick = (e) => withButton(e.currentTarget, () => sendTx("Finalize vote", () => withSigner(oracle).finalize(m.id)));
    const tb = $("#timeout-btn", box);
    if (tb) tb.onclick = (e) => withButton(e.currentTarget, () => sendTx("Resolve as invalid (timeout)", () => withSigner(pm).resolveAfterTimeout(m.id)));
  }

  // ------------------------------------------------------------------ order book

  const priceStr = (bps) => (bps / 10_000).toFixed(4);

  function openOrdersFor(outcome) {
    const now = state.chain.time;
    return ctx.orders.filter((o) => o.outcome === outcome && o.status === ORDER_STATUS.Open && (o.expiry === 0 || o.expiry > now));
  }

  function paintBook() {
    const m = ctx.m;
    const t = m.token;
    const me = state.wallet.address;
    const now = state.chain.time;
    const allOpen = ctx.orders.filter((o) => o.status === ORDER_STATUS.Open && (o.expiry === 0 || o.expiry > now));
    el("#count-book").textContent = allOpen.length ? String(allOpen.length) : "";
    setHTML(
      el("#book-outcomes"),
      m.labels
        .map(
          (l, i) =>
            `<button class="chip ${ctx.bookOutcome === i ? "active" : ""}" data-outcome="${i}" data-testid="book-outcome-${i}"><span class="keydot" style="background:${seriesColor(i)};width:8px;height:8px;margin-right:5px"></span>${esc(l)} <span class="muted">(${openOrdersFor(i).length})</span></button>`,
        )
        .join(""),
    );
    el("#ord-form-wrap").hidden = m.resolved;
    el("#book-note").textContent = m.resolved
      ? "Market resolved: the book is closed. Cancel open orders to recover escrow."
      : `AMM price ${pct(m.prices[ctx.bookOutcome], 1)} · orders are fully escrowed on-chain`;
    const open = openOrdersFor(ctx.bookOutcome);
    const bids = open.filter((o) => o.side === SIDE.Buy).sort((a, b) => b.price - a.price || a.id - b.id);
    const asks = open.filter((o) => o.side === SIDE.Sell).sort((a, b) => a.price - b.price || a.id - b.id);
    const maxRem = Math.max(1, ...open.map((o) => Number(o.remaining)));
    const table = (list, side) =>
      list.length
        ? `<table class="tbl"><thead><tr><th>Price</th><th class="r">Shares</th><th>Maker</th><th></th></tr></thead><tbody>${list
            .map(
              (o) => `<tr class="depth" data-testid="order-row-${o.id}"><td class="num"><b>${priceStr(o.price)}</b> <span class="muted tiny">${(o.price / 100).toFixed(1)}%</span></td>
                <td class="r num" style="position:relative">${fmtShares(o.remaining, t)}<span class="depth-bar" style="width:${((Number(o.remaining) / maxRem) * 100).toFixed(0)}%;background:${side === "bid" ? "var(--good)" : "var(--bad)"}"></span></td>
                <td>${who(o.maker)}${o.expiry ? `<div class="tiny muted">expires ${fmtRelative(o.expiry, now)}</div>` : ""}</td>
                <td class="r">${sameAddr(o.maker, me) ? '<span class="tiny muted">yours</span>' : m.resolved ? "" : `<button class="btn sm" data-take="${o.id}" data-testid="take-${o.id}">${side === "bid" ? "Sell to" : "Buy"}</button>`}</td></tr>`,
            )
            .join("")}</tbody></table>`
        : `<p class="small muted" style="padding:10px 0">No ${side === "bid" ? "buy" : "sell"} orders for this outcome.</p>`;
    setHTML(
      el("#book-grid"),
      `<div class="book-side bids"><h4>Bids · buyers</h4>${table(bids, "bid")}</div><div class="book-side asks"><h4>Asks · sellers</h4>${table(asks, "ask")}</div>`,
    );
    // my orders (all statuses)
    const mine = ctx.orders.filter((o) => sameAddr(o.maker, me)).sort((a, b) => b.id - a.id);
    const statusText = (o) => {
      if (o.status === ORDER_STATUS.Filled) return '<span class="badge resolved">filled</span>';
      if (o.status === ORDER_STATUS.Cancelled) return '<span class="badge closed">cancelled</span>';
      if (o.expiry && o.expiry <= now) return '<span class="badge timedout">expired</span>';
      return o.remaining < o.amount ? '<span class="badge reporting">partially filled</span>' : '<span class="badge trading">open</span>';
    };
    setHTML(
      el("#my-orders"),
      !me
        ? '<p class="small muted">Connect a wallet to see your orders.</p>'
        : mine.length
          ? `<table class="tbl" data-testid="my-orders"><thead><tr><th>#</th><th>Order</th><th class="r">Filled</th><th>Status</th><th></th></tr></thead><tbody>${mine
              .map(
                (o) => `<tr data-testid="my-order-${o.id}"><td class="num">${o.id}</td><td>${o.side === SIDE.Buy ? "Buy" : "Sell"} ${esc(m.labels[o.outcome])} @ ${priceStr(o.price)}</td>
                  <td class="r num">${o.status === ORDER_STATUS.Cancelled ? "—" : fmtShares(o.amount - o.remaining, t)} / ${fmtShares(o.amount, t)}</td>
                  <td>${statusText(o)}</td>
                  <td class="r">${o.status === ORDER_STATUS.Open ? `<button class="btn sm" data-cancel="${o.id}" data-testid="cancel-${o.id}">Cancel</button>` : ""}</td></tr>`,
              )
              .join("")}</tbody></table>`
          : '<p class="small muted">You have no orders in this market.</p>',
    );
    paintOrderPreview();
  }

  function orderSide() {
    const b = $("#ord-side button.active", root);
    return Number(b ? b.dataset.side : 0);
  }

  function readOrderForm() {
    const m = ctx.m;
    const side = orderSide();
    const priceTxt = el("#ord-price").value.trim();
    const price = Number(priceTxt);
    const priceBps = Math.round(price * 10_000);
    const amount = parseAmount(el("#ord-amount").value, m.token.decimals);
    const exp = el("#ord-expiry").value;
    const now = state.chain.time;
    let expiry = 0;
    if (exp === "close") expiry = m.closeTime > now ? m.closeTime : 0;
    else if (exp !== "0") expiry = now + Number(exp);
    let error = "";
    if (priceTxt && (!(price > 0 && price < 1) || Math.abs(price * 10_000 - priceBps) > 1e-6)) error = "Price must be between 0.0001 and 0.9999 (4 decimals).";
    if (el("#ord-amount").value && amount === null) error = "Invalid share amount.";
    return { side, priceBps, amount, expiry, error, complete: priceTxt && amount && amount > 0n && !error };
  }

  function paintOrderPreview() {
    const m = ctx.m;
    const t = m.token;
    const f = readOrderForm();
    const outcome = m.labels[ctx.bookOutcome];
    let html = `<div class="qrow"><span>Outcome</span><b>${esc(outcome)}</b></div>`;
    if (f.complete) {
      if (f.side === SIDE.Buy) {
        const escrow = (f.amount * BigInt(f.priceBps) + PRICE_SCALE - 1n) / PRICE_SCALE;
        html += `<div class="qrow"><span>Collateral escrowed</span><b>${fmtToken(escrow, t)}</b></div>`;
      } else {
        const held = ctx.pos?.balances[ctx.bookOutcome] ?? 0n;
        html += `<div class="qrow"><span>Shares escrowed</span><b>${fmtShares(f.amount, t)} (you hold ${fmtShares(held, t)})</b></div>`;
        html += `<div class="qrow"><span>You receive if fully filled</span><b>${fmtToken((f.amount * BigInt(f.priceBps)) / PRICE_SCALE, t)}</b></div>`;
      }
      html += `<div class="qrow"><span>Expiry</span><b>${f.expiry ? fmtDate(f.expiry) : "until resolution"}</b></div>`;
    }
    if (f.error) html += `<div class="error-text">${esc(f.error)}</div>`;
    setHTML(el("#ord-preview"), html);
    el("#ord-submit").disabled = !f.complete || m.resolved || !state.wallet.address;
    el("#ord-submit").textContent = `${f.side === SIDE.Buy ? "Place buy order" : "Place sell order"} · ${outcome}`;
  }

  async function submitOrder() {
    const m = ctx.m;
    const f = readOrderForm();
    if (!f.complete) return;
    if (f.side === SIDE.Buy) {
      const escrow = (f.amount * BigInt(f.priceBps) + PRICE_SCALE - 1n) / PRICE_SCALE;
      if (!(await ensureAllowance(m.token, book.target, escrow))) return;
    } else if (!(await ensureShareApproval())) return;
    const r = await sendTx(`Place ${f.side === SIDE.Buy ? "buy" : "sell"} order`, () =>
      withSigner(book).placeOrder(m.id, ctx.bookOutcome, f.side, f.priceBps, f.amount, f.expiry),
    );
    if (r) {
      el("#ord-amount").value = "";
      paintOrderPreview();
    }
  }

  function openFill(o) {
    ctx.fill = { ...o };
    const m = ctx.m;
    const t = m.token;
    const box = el("#fill-box");
    const isAsk = o.side === SIDE.Sell;
    box.innerHTML = `<div class="fill-box" data-testid="fill-box">
      <div class="row between"><b>${isAsk ? "Buy" : "Sell"} ${esc(m.labels[o.outcome])} shares from ${esc(nameOf(o.maker))} · order #${o.id}</b><button class="btn sm ghost" id="fill-close">Close</button></div>
      <div class="grid-2" style="margin-top:10px">
        <div class="field"><label for="fill-amount">Shares (max ${fmtShares(o.remaining, t)})</label>
          <div class="input-group"><input id="fill-amount" inputmode="decimal" value="${toInput(o.remaining, t.decimals)}" data-testid="fill-amount"><button class="max" id="fill-max" type="button">MAX</button></div></div>
        <div class="quote" id="fill-preview"></div>
      </div>
      <button class="btn primary block" id="fill-submit" style="margin-top:10px" data-testid="fill-submit">${isAsk ? "Buy" : "Sell"} at ${priceStr(o.price)}</button>
    </div>`;
    const preview = () => {
      const amt = parseAmount($("#fill-amount", box).value, t.decimals) ?? 0n;
      const cost = isAsk ? (amt * BigInt(o.price) + PRICE_SCALE - 1n) / PRICE_SCALE : (amt * BigInt(o.price)) / PRICE_SCALE;
      $("#fill-preview", box).innerHTML = `<div class="qrow"><span>${isAsk ? "You pay" : "You receive"}</span><b>${fmtToken(cost, t)}</b></div>
        <div class="qrow"><span>AMM price now</span><b>${m.prices[o.outcome].toFixed(4)}</b></div>`;
    };
    preview();
    $("#fill-amount", box).oninput = preview;
    $("#fill-max", box).onclick = () => {
      $("#fill-amount", box).value = toInput(o.remaining, t.decimals);
      preview();
    };
    $("#fill-close", box).onclick = () => {
      ctx.fill = null;
      box.innerHTML = "";
    };
    $("#fill-submit", box).onclick = (e) =>
      withButton(e.currentTarget, async () => {
        const amt = parseAmount($("#fill-amount", box).value, t.decimals);
        if (!amt || amt === 0n) return toast.error("Enter a share amount");
        if (isAsk) {
          const cost = (amt * BigInt(o.price) + PRICE_SCALE - 1n) / PRICE_SCALE;
          if (!(await ensureAllowance(t, book.target, cost))) return;
        } else if (!(await ensureShareApproval())) return;
        const r = await sendTx(`Fill order #${o.id}`, () => withSigner(book).fillOrder(o.id, amt));
        if (r) {
          ctx.fill = null;
          box.innerHTML = "";
        }
      });
    box.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  // ------------------------------------------------------------------ activity

  function paintActivity() {
    const m = ctx.m;
    const t = m.token;
    const items = (ctx.hist?.activity || []).slice().reverse().slice(0, 60);
    el("#count-activity").textContent = ctx.hist?.activity.length ? String(ctx.hist.activity.length) : "";
    if (!items.length) {
      setHTML(el("#activity"), '<p class="small muted">No trades yet.</p>');
      return;
    }
    const rows = items
      .map((a) => {
        if (a.kind === "trade") {
          const avg = Number(a.collateral) / Number(a.shares || 1n);
          return `<tr><td class="nowrap tiny muted">${fmtDate(a.t)}</td><td>${who(a.trader)}</td>
            <td><span class="badge ${a.isBuy ? "trading" : "invalid"}">${a.isBuy ? "Bought" : "Sold"}</span> <span class="keydot" style="background:${seriesColor(a.outcome)}"></span> ${esc(m.labels[a.outcome])}</td>
            <td class="r num">${fmtShares(a.shares, t)}</td><td class="r num">${avg.toFixed(3)}</td><td class="r num">${fmtToken(a.collateral, t)}</td><td class="tiny muted">AMM</td></tr>`;
        }
        const o = ctx.orders.find((x) => x.id === a.orderId);
        const takerBuys = o ? o.side === SIDE.Sell : true;
        return `<tr><td class="nowrap tiny muted">${fmtDate(a.t)}</td><td>${who(a.taker)}</td>
          <td><span class="badge ${takerBuys ? "trading" : "invalid"}">${takerBuys ? "Bought" : "Sold"}</span> ${o ? `<span class="keydot" style="background:${seriesColor(o.outcome)}"></span> ${esc(m.labels[o.outcome])}` : ""}</td>
          <td class="r num">${fmtShares(a.shares, t)}</td><td class="r num">${o ? (o.price / 10_000).toFixed(3) : "—"}</td><td class="r num">${fmtToken(a.collateral, t)}</td><td class="tiny muted">P2P · ${esc(nameOf(a.maker))}</td></tr>`;
      })
      .join("");
    setHTML(
      el("#activity"),
      `<div style="max-height:420px;overflow:auto"><table class="tbl" data-testid="activity-table"><thead><tr><th>Time</th><th>Trader</th><th>Action</th><th class="r">Shares</th><th class="r">Avg price</th><th class="r">Amount</th><th>Venue</th></tr></thead><tbody>${rows}</tbody></table></div>`,
    );
  }

  // ------------------------------------------------------------------ liquidity & complete sets

  let liqBuilt = false;
  function buildLiquidity() {
    const m = ctx.m;
    el("#liquidity").innerHTML = `
      <div class="grid-2">
        <div class="stack" style="gap:10px">
          <h3>Pool</h3>
          <div id="pool-stats" class="quote"></div>
          <h3 style="margin-top:6px">Your liquidity</h3>
          <div id="my-lp" class="quote"></div>
        </div>
        <div class="stack" style="gap:14px">
          <div>
            <h3>Add liquidity</h3>
            <p class="hint">Deposit ${esc(m.token.symbol)}; you get LP shares and earn the ${(m.feeBps / 100).toFixed(1)}% trading fee. Tokens the pool doesn't need to keep prices unchanged are returned to you.</p>
            <div class="input-group" style="margin-top:8px"><input id="add-liq" inputmode="decimal" placeholder="0.00" data-testid="add-liquidity-amount"><span class="suffix">${esc(m.token.symbol)}</span></div>
            <div class="hint" id="add-liq-preview" style="margin-top:4px"></div>
            <button class="btn block" id="add-liq-btn" style="margin-top:8px" data-testid="add-liquidity-submit">Add liquidity</button>
          </div>
          <div>
            <h3>Remove liquidity</h3>
            <div class="row" style="margin-top:6px">${[25, 50, 100].map((p) => `<button class="chip" data-rm="${p}">${p}%</button>`).join("")}</div>
            <div class="input-group" style="margin-top:8px"><input id="rm-liq" inputmode="decimal" placeholder="LP shares" data-testid="remove-liquidity-amount"><span class="suffix">LP</span></div>
            <div class="hint" id="rm-liq-preview" style="margin-top:4px"></div>
            <button class="btn block" id="rm-liq-btn" style="margin-top:8px" data-testid="remove-liquidity-submit">Remove liquidity</button>
          </div>
          <div>
            <h3>Complete sets</h3>
            <p class="hint">1 ${esc(m.token.symbol)} ⇄ 1 share of every outcome. Minting sets is how P2P market makers get shares to sell; merging turns a full set back into collateral at any time.</p>
            <div class="input-group" style="margin-top:8px"><input id="set-amt" inputmode="decimal" placeholder="0.00" data-testid="set-amount"><span class="suffix">sets</span></div>
            <div class="row" style="margin-top:8px"><button class="btn grow" id="split-btn" data-testid="split-submit">Mint sets</button><button class="btn grow" id="merge-btn" data-testid="merge-submit">Merge sets</button></div>
          </div>
        </div>
      </div>`;
    const t = m.token;
    el("#add-liq").oninput = paintLiquidity;
    el("#rm-liq").oninput = paintLiquidity;
    $$("[data-rm]", el("#liquidity")).forEach((b) => {
      b.onclick = () => {
        const sh = ctx.pos?.lpShares ?? 0n;
        el("#rm-liq").value = toInput((sh * BigInt(b.dataset.rm)) / 100n, t.decimals);
        paintLiquidity();
      };
    });
    el("#add-liq-btn").onclick = (e) =>
      withButton(e.currentTarget, async () => {
        const amt = parseAmount(el("#add-liq").value, t.decimals);
        if (!amt) return;
        if (!(await ensureAllowance(t, pm.target, amt))) return;
        const r = await sendTx("Add liquidity", () => withSigner(pm).addLiquidity(ctx.m.id, amt, 0n));
        if (r) el("#add-liq").value = "";
      });
    el("#rm-liq-btn").onclick = (e) =>
      withButton(e.currentTarget, async () => {
        const sh = parseAmount(el("#rm-liq").value, t.decimals);
        if (!sh) return;
        const [col] = await pm.calcRemoveLiquidity(ctx.m.id, sh);
        const min = (col * BigInt(10_000 - state.settings.slippageBps)) / 10_000n;
        const r = await sendTx("Remove liquidity", () => withSigner(pm).removeLiquidity(ctx.m.id, sh, min));
        if (r) el("#rm-liq").value = "";
      });
    el("#split-btn").onclick = (e) =>
      withButton(e.currentTarget, async () => {
        const amt = parseAmount(el("#set-amt").value, t.decimals);
        if (!amt) return;
        if (!(await ensureAllowance(t, pm.target, amt))) return;
        await sendTx("Mint complete sets", () => withSigner(pm).splitPosition(ctx.m.id, amt));
      });
    el("#merge-btn").onclick = (e) =>
      withButton(e.currentTarget, async () => {
        const amt = parseAmount(el("#set-amt").value, t.decimals);
        if (!amt) return;
        await sendTx("Merge complete sets", () => withSigner(pm).mergePositions(ctx.m.id, amt));
      });
    liqBuilt = true;
  }

  async function paintLiquidity() {
    const m = ctx.m;
    const t = m.token;
    if (!liqBuilt) buildLiquidity();
    const poolRows = m.labels
      .map((l, i) => `<div class="qrow"><span><span class="keydot" style="background:${seriesColor(i)}"></span> ${esc(l)}</span><b>${fmtShares(m.pool[i], t)}</b></div>`)
      .join("");
    setHTML(
      el("#pool-stats"),
      `${poolRows}<hr class="divider" style="margin:6px 0"><div class="qrow"><span>Total LP shares</span><b>${fmtShares(m.totalLpShares, t)}</b></div>
       <div class="qrow"><span>Unclaimed fees (all LPs)</span><b>${fmtToken(m.feePool, t)}</b></div>`,
    );
    const p = ctx.pos;
    const my = p?.lpShares ?? 0n;
    let myHtml = `<div class="qrow"><span>LP shares</span><b data-testid="my-lp-shares">${fmtShares(my, t)}</b></div>
      <div class="qrow"><span>Share of pool</span><b>${m.totalLpShares > 0n ? ((Number(my) / Number(m.totalLpShares)) * 100).toFixed(2) : "0"}%</b></div>
      <div class="qrow"><span>Unclaimed fees</span><b>${fmtToken(p?.pendingFees ?? 0n, t)}</b></div>`;
    if (my > 0n) {
      try {
        const [col, toks] = await pm.calcRemoveLiquidity(m.id, my);
        const extra = Array.from(toks)
          .map((x, i) => (BigInt(x) > 0n ? `${fmtShares(BigInt(x), t)} ${esc(m.labels[i])}` : null))
          .filter(Boolean)
          .join(", ");
        myHtml += `<div class="qrow"><span>Withdrawable now</span><b>${fmtToken(col, t)}${extra ? ` + ${extra}` : ""}</b></div>`;
      } catch {
        /* ignore */
      }
    }
    setHTML(el("#my-lp"), myHtml);
    // previews
    const add = parseAmount(el("#add-liq").value, t.decimals);
    const canAdd = m.phase === PHASE.Trading;
    el("#add-liq-btn").disabled = !canAdd || !add || !state.wallet.address;
    if (!canAdd) el("#add-liq-preview").textContent = "Liquidity can only be added while trading is open.";
    else if (add) {
      const weight = m.pool.reduce((a, b) => (b > a ? b : a), 0n);
      const shares = m.totalLpShares === 0n || weight === 0n ? add : (add * m.totalLpShares) / weight;
      el("#add-liq-preview").textContent = `≈ ${fmtShares(shares, t)} LP shares`;
    } else el("#add-liq-preview").textContent = "";
    const rm = parseAmount(el("#rm-liq").value, t.decimals);
    el("#rm-liq-btn").disabled = !rm || rm > my || !state.wallet.address;
    if (rm && rm <= my) {
      try {
        const [col, toks] = await pm.calcRemoveLiquidity(m.id, rm);
        const extra = Array.from(toks).filter((x) => BigInt(x) > 0n).length;
        el("#rm-liq-preview").textContent = `You get ${fmtToken(col, t)}${extra ? " + leftover outcome shares" : ""} + your unclaimed fees.`;
      } catch {
        el("#rm-liq-preview").textContent = "";
      }
    } else el("#rm-liq-preview").textContent = rm && rm > my ? "More than your LP shares." : "";
    el("#split-btn").disabled = m.resolved || !state.wallet.address;
  }

  function paintRules() {
    const m = ctx.m;
    setHTML(
      el("#rules"),
      `<div class="stack small" style="gap:10px">
        <p><b>Question.</b> ${esc(m.question)}</p>
        <p><b>How it resolves.</b> ${
          m.isOracle
            ? `Registered reporters vote after ${fmtDate(m.resolutionTime)}. Votes are weighted by reputation; a quorum of reputation must vote and the heaviest outcome wins. No quorum or a tie extends voting once, then the market resolves INVALID.`
            : `The arbitrator <b>${esc(nameOf(m.arbitrator))}</b> (<span class="mono">${esc(m.arbitrator)}</span>) reports the outcome after ${fmtDate(m.resolutionTime)}. The report is final.`
        } If nothing is reported within 7 days after the resolution time, anyone can resolve the market as INVALID.</p>
        <p><b>Payouts.</b> Each share of the winning outcome redeems for 1 ${esc(m.token.symbol)}. INVALID pays 1/${m.n} ${esc(m.token.symbol)} per share of any outcome, so holders of complete sets (and LPs) get their collateral back.</p>
        <p><b>Pricing.</b> A constant-product market maker (Gnosis FPMM) quotes prices; they always sum to 100%. Every share is backed 1:1 by collateral held in the contract.</p>
        <p><b>Collateral.</b> ${esc(m.token.name)} · <span class="mono">${esc(m.collateral)}</span> · ${m.token.decimals} decimals. LP fee ${(m.feeBps / 100).toFixed(2)}%.</p>
        <p><b>Outcome token ids (ERC-1155).</b> ${m.labels.map((l, i) => `${esc(l)}: <span class="mono">${((BigInt(m.id) << 8n) | BigInt(i)).toString()}</span>`).join(" · ")}</p>
        <p class="muted">Created ${fmtDate(m.createdAt)} by ${esc(nameOf(m.creator))}.</p>
      </div>`,
    );
  }

  // ------------------------------------------------------------------ refresh

  async function refresh() {
    const me = state.wallet.address;
    const [m, pos, orders, hist] = await Promise.all([
      fetchMarket(id),
      me ? fetchPosition(id, me) : Promise.resolve(null),
      fetchOrders(id),
      fetchHistory(id),
    ]);
    ctx.m = m;
    ctx.pos = pos;
    ctx.orders = orders;
    ctx.hist = hist;
    if (m.isOracle) {
      const [round, reporter, params] = await Promise.all([fetchRound(id, m.n), fetchReporter(me), fetchOracleParams()]);
      ctx.round = round;
      ctx.reporter = reporter;
      ctx.oracleParams = params;
    }
    paintHeader();
    paintOutcomes();
    paintChart();
    paintTabs();
    paintTrade();
    paintPosition();
    paintResolution();
    paintBook();
    paintActivity();
    paintLiquidity();
    paintRules();
    requote();
  }

  ctx.bookOutcome = ctx.selected;
  await refresh();
  return {
    refresh,
    unmount() {
      chart.destroy();
    },
  };
}
