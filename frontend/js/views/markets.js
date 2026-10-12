// Market list: stat tiles, filters, market cards with live odds.
import { state } from "../state.js";
import { tokens, nameOf } from "../chain.js";
import { fetchMarkets, phaseInfo, PHASE } from "../data.js";
import { esc, pct, fmtToken, fmtRelative, fmtDate } from "../format.js";
import { $, $$, setHTML, seriesColor } from "../ui.js";

const filters = { status: "all", token: "all", q: "" };

function statusOf(m) {
  if (m.phase === PHASE.Trading) return "trading";
  if (m.phase === PHASE.Resolved || m.phase === PHASE.Invalid) return "resolved";
  return "resolving";
}

function oddsRows(m, max = 3) {
  const order = m.labels.map((l, i) => i);
  if (m.n > max) order.sort((a, b) => m.prices[b] - m.prices[a]);
  const shown = order.slice(0, max);
  const rows = shown
    .map((i) => {
      const winner = m.phase === PHASE.Resolved && m.outcome === i;
      return `<div class="odds-row ${winner ? "winner" : ""}">
        <div class="o-label"><span class="keydot" style="background:${seriesColor(i)}"></span><span>${esc(m.labels[i])}</span>${winner ? '<span class="win-tag">WON</span>' : ""}</div>
        <div class="o-pct">${pct(m.prices[i], 0)}</div>
        <div class="o-bar"><i style="width:${(m.prices[i] * 100).toFixed(1)}%;background:${seriesColor(i)}"></i></div>
      </div>`;
    })
    .join("");
  const more = m.n > max ? `<div class="tiny muted">+${m.n - max} more outcome${m.n - max > 1 ? "s" : ""}</div>` : "";
  return rows + more;
}

function timeNote(m) {
  const now = state.chain.time;
  switch (m.phase) {
    case PHASE.Trading:
      return `Closes <b>${fmtRelative(m.closeTime, now)}</b>`;
    case PHASE.Closed:
      return `Resolves <b>${fmtRelative(m.resolutionTime, now)}</b>`;
    case PHASE.Reporting:
      return m.isOracle ? "Reporters are voting" : `Waiting for <b>${esc(nameOf(m.arbitrator))}</b>`;
    case PHASE.TimedOut:
      return "Can be resolved as invalid";
    default:
      return `Resolved ${fmtDate(m.resolvedAt, { time: false })}`;
  }
}

function card(m) {
  const ph = phaseInfo(m);
  return `<a class="card market-card" href="#/market/${m.id}" data-testid="market-card-${m.id}">
    <div class="mc-top">
      <span class="badge cat">${esc(m.category || "General")}</span>
      <span class="badge ${ph.key}"><span class="bdot"></span>${esc(ph.text)}</span>
      <span class="badge token" title="${esc(m.token?.name || "")}">${esc(m.token?.symbol || "?")}</span>
      ${m.isOracle ? '<span class="badge voting" title="Resolved by reputation-weighted reporter vote">Vote-resolved</span>' : ""}
    </div>
    <div class="mc-q">${esc(m.question)}</div>
    <div class="odds-list">${oddsRows(m)}</div>
    <div class="mc-foot">
      <span>Vol <b>${fmtToken(m.volume, m.token)}</b></span>
      <span>Liquidity <b>${fmtToken(m.collateralLocked, m.token)}</b></span>
      <span class="grow"></span>
      <span>${timeNote(m)}</span>
    </div>
  </a>`;
}

export async function mount(root) {
  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Prediction markets</h1>
        <p>Buy and sell outcome shares. Each share pays 1 unit of collateral if its outcome happens, so its price is the crowd's probability.</p>
      </div>
      <a class="btn primary" href="#/create" data-testid="create-market-link">+ Create market</a>
    </div>
    <div class="tiles" id="tiles"></div>
    <div class="filters">
      <div class="seg" id="f-status">
        <button data-v="all">All</button><button data-v="trading">Trading</button><button data-v="resolving">Resolving</button><button data-v="resolved">Resolved</button>
      </div>
      <select class="input" id="f-token" aria-label="Collateral">
        <option value="all">All collateral</option>
        ${tokens.map((t) => `<option value="${t.address}">${esc(t.symbol)} (${t.decimals} decimals)</option>`).join("")}
      </select>
      <input class="input search" id="f-q" placeholder="Search questions…" aria-label="Search markets" value="${esc(filters.q)}">
    </div>
    <div class="market-grid" id="grid" data-testid="market-grid"></div>`;

  let markets = [];
  const paintFilters = () => {
    $$("#f-status button", root).forEach((b) => b.classList.toggle("active", b.dataset.v === filters.status));
    $("#f-token", root).value = filters.token;
  };
  const paint = () => {
    const q = filters.q.trim().toLowerCase();
    const list = markets
      .filter((m) => filters.status === "all" || statusOf(m) === filters.status)
      .filter((m) => filters.token === "all" || m.collateral.toLowerCase() === filters.token.toLowerCase())
      .filter((m) => !q || m.question.toLowerCase().includes(q) || (m.category || "").toLowerCase().includes(q))
      .sort((a, b) => {
        const rank = { trading: 0, resolving: 1, resolved: 2 };
        return rank[statusOf(a)] - rank[statusOf(b)] || b.id - a.id;
      });
    setHTML($("#grid", root), list.length ? list.map(card).join("") : '<div class="empty card">No markets match these filters.</div>');
    const count = (s) => markets.filter((m) => statusOf(m) === s).length;
    const tradingVol = tokens
      .map((t) => {
        const vol = markets.filter((m) => m.collateral.toLowerCase() === t.address.toLowerCase()).reduce((a, m) => a + m.volume, 0n);
        return vol > 0n ? fmtToken(vol, t, { frac: t.symbol === "WETH" ? 2 : 0 }) : null;
      })
      .filter(Boolean)
      .join(" · ");
    setHTML(
      $("#tiles", root),
      `<div class="card tile"><div class="t-label">Markets</div><div class="t-value" data-testid="tile-markets">${markets.length}</div><div class="t-sub">${esc(tradingVol ? `volume ${tradingVol}` : `${tokens.length} collateral tokens`)}</div></div>
       <div class="card tile"><div class="t-label">Trading now</div><div class="t-value">${count("trading")}</div><div class="t-sub">AMM open for buys & sells</div></div>
       <div class="card tile"><div class="t-label">Resolving</div><div class="t-value">${count("resolving")}</div><div class="t-sub">closed, awaiting outcome</div></div>
       <div class="card tile"><div class="t-label">Resolved</div><div class="t-value">${count("resolved")}</div><div class="t-sub">winners redeem 1:1</div></div>`,
    );
  };

  $$("#f-status button", root).forEach(
    (b) =>
      (b.onclick = () => {
        filters.status = b.dataset.v;
        paintFilters();
        paint();
      }),
  );
  $("#f-token", root).onchange = (e) => {
    filters.token = e.target.value;
    paint();
  };
  $("#f-q", root).oninput = (e) => {
    filters.q = e.target.value;
    paint();
  };

  const refresh = async () => {
    markets = await fetchMarkets();
    paint();
  };
  paintFilters();
  await refresh();
  return { refresh, unmount() {} };
}
