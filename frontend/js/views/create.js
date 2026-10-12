// Create-market form: question, outcomes (2-8), times (validated against chain time), arbitrator or reputation vote,
// collateral selector (USDT 6 dp / DAI / WETH), initial liquidity, optional initial odds and LP fee.
import { state } from "../state.js";
import { pm, cfg, tokens, ORACLE_ADDRESS, withSigner, sendTx, ensureAllowance, nameOf, sameAddr } from "../chain.js";
import { esc, pct, fmtToken, fmtDate, fmtDuration, parseAmount } from "../format.js";
import { $, $$, setHTML, seriesColor, withButton } from "../ui.js";

const { ethers } = window;
const CATEGORIES = ["Crypto", "Sports", "Politics", "Tech", "Economics", "Weather", "Campus"];

function toLocalInput(ts) {
  const d = new Date(ts * 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function fromLocalInput(v) {
  const t = new Date(v).getTime();
  return Number.isFinite(t) ? Math.floor(t / 1000) : null;
}

export async function mount(root) {
  // collateral allow-list and minimum initial liquidity straight from the contract
  const [cAddrs, cAllowed, cMins] = await pm.getCollaterals();
  const minLiq = new Map();
  const allowed = new Set();
  Array.from(cAddrs).forEach((a, i) => {
    minLiq.set(a.toLowerCase(), BigInt(cMins[i]) || 1n);
    if (cAllowed[i]) allowed.add(a.toLowerCase());
  });
  const usable = tokens.filter((t) => allowed.has(t.address.toLowerCase()));
  const now = state.chain.time || Math.floor(Date.now() / 1000);
  const hour = 3600;
  const close0 = Math.ceil((now + 7 * 86400) / hour) * hour;
  const f = {
    question: "",
    category: "Crypto",
    outcomes: ["Yes", "No"],
    odds: null, // null = uniform, else array of percentages
    close: close0,
    resolution: close0 + 86400,
    mode: "arbitrator",
    arbitrator: cfg.demoAccounts.find((a) => a.name === "Dave")?.address || "",
    token: (usable[0] || tokens[0]).address,
    liquidity: "1000",
    feeBps: 200,
  };

  root.innerHTML = `
    <div class="page-head"><div><h1>Create a market</h1><p>Open a question about a future event. You seed the automated market maker with liquidity (and become its first LP), pick who resolves it, and choose the collateral token.</p></div></div>
    <div class="create-grid">
      <div class="card">
        <div class="form-section">
          <h3>Question</h3>
          <div class="field"><label for="c-question">What will traders predict? <span class="muted" id="c-qcount"></span></label>
            <textarea class="input" id="c-question" rows="2" maxlength="280" placeholder="Will ETH close above $5,000 on 31 Dec 2026 (UTC)?" data-testid="create-question"></textarea>
            <span class="hint">Be specific about the source and the deadline — the arbitrator resolves exactly this text.</span></div>
          <div class="field" style="margin-top:12px"><label for="c-category">Category</label>
            <div class="row wrap"><input class="input" id="c-category" maxlength="32" style="max-width:220px" data-testid="create-category">
            <div class="chips" id="c-cats">${CATEGORIES.map((c) => `<button type="button" class="chip" data-cat="${c}">${c}</button>`).join("")}</div></div></div>
        </div>
        <div class="form-section">
          <div class="row between"><h3>Outcomes</h3><div class="chips"><button type="button" class="chip" id="c-yesno">Yes / No</button><button type="button" class="chip" id="c-add" data-testid="create-add-outcome">+ Add outcome</button></div></div>
          <p class="hint" style="margin:-4px 0 10px">2–8 mutually exclusive outcomes. Optionally set starting odds (they must add up to 100%, each ≥ 1%).</p>
          <label class="row small" style="margin-bottom:10px"><input type="checkbox" id="c-odds-on" data-testid="create-odds-toggle"> Set initial odds (default: equal)</label>
          <div class="outcome-inputs" id="c-outcomes"></div>
        </div>
        <div class="form-section">
          <h3>Timing</h3>
          <div class="grid-2">
            <div class="field"><label for="c-close">Trading closes</label><input class="input" type="datetime-local" id="c-close" data-testid="create-close"></div>
            <div class="field"><label for="c-resolution">Outcome can be reported from</label><input class="input" type="datetime-local" id="c-resolution" data-testid="create-resolution"></div>
          </div>
          <p class="hint" style="margin-top:8px" id="c-timehint"></p>
        </div>
        <div class="form-section">
          <h3>Resolution</h3>
          <div class="choice">
            <label class="opt"><input type="radio" name="c-mode" value="arbitrator" checked data-testid="create-mode-arbitrator"><span><b>Trusted arbitrator</b><span class="small text-2">A named address (person, multisig or contract) reports the outcome. If it stays silent for 7 days the market becomes invalid and everyone is refunded pro-rata.</span></span></label>
            <label class="opt"><input type="radio" name="c-mode" value="oracle" data-testid="create-mode-oracle"><span><b>Reputation-weighted reporter vote</b><span class="small text-2">Registered reporters vote; votes are weighted by reputation, which grows when they agree with the final consensus and is slashed otherwise. Quorum and tie handling built in.</span></span></label>
          </div>
          <div class="field" id="c-arb-field" style="margin-top:12px"><label for="c-arbitrator">Arbitrator address</label>
            <div class="row wrap"><input class="input mono" id="c-arbitrator" placeholder="0x…" style="flex:1;min-width:260px" data-testid="create-arbitrator">
            <select class="input" id="c-arb-pick" style="width:auto">${cfg.demoAccounts.length ? `<option value="">Demo accounts…</option>${cfg.demoAccounts.map((a) => `<option value="${a.address}">${esc(a.name)} — ${esc(a.role)}</option>`).join("")}` : '<option value="">—</option>'}</select></div></div>
        </div>
        <div class="form-section">
          <h3>Collateral & liquidity</h3>
          <div class="token-pick" id="c-tokens" data-testid="create-tokens"></div>
          <div class="grid-2" style="margin-top:12px">
            <div class="field"><label for="c-liquidity">Initial liquidity</label>
              <div class="input-group"><input id="c-liquidity" inputmode="decimal" data-testid="create-liquidity"><span class="suffix" id="c-liq-unit"></span></div>
              <span class="hint" id="c-liq-hint"></span></div>
            <div class="field"><label for="c-fee">LP trading fee</label>
              <select class="input" id="c-fee">${[0, 50, 100, 200, 300, 500].map((b) => `<option value="${b}" ${b === 200 ? "selected" : ""}>${b / 100}%</option>`).join("")}</select>
              <span class="hint">Paid by traders to liquidity providers (max 5%).</span></div>
          </div>
        </div>
      </div>
      <div class="side">
        <div class="card card-pad">
          <h3>Preview</h3>
          <div id="c-preview" style="margin-top:10px"></div>
          <div id="c-errors" class="error-text" style="margin-top:10px" data-testid="create-errors"></div>
          <button class="btn primary lg block" id="c-submit" style="margin-top:12px" data-testid="create-submit">Create market</button>
          <p class="hint" style="margin-top:8px">You'll approve the collateral first (exact amount), then create. You become the first liquidity provider.</p>
        </div>
      </div>
    </div>`;

  const el = (s) => $(s, root);
  el("#c-category").value = f.category;
  el("#c-close").value = toLocalInput(f.close);
  el("#c-resolution").value = toLocalInput(f.resolution);
  el("#c-arbitrator").value = f.arbitrator;
  el("#c-liquidity").value = f.liquidity;

  function renderOutcomes() {
    const oddsOn = !!f.odds;
    setHTML(
      el("#c-outcomes"),
      f.outcomes
        .map(
          (o, i) => `<div class="outcome-input">
            <span class="keydot" style="background:${seriesColor(i)}"></span>
            <input class="input" data-oi="${i}" value="${esc(o)}" maxlength="48" placeholder="Outcome ${i + 1}" data-testid="create-outcome-${i}">
            ${oddsOn ? `<div class="input-group"><input data-odd="${i}" value="${f.odds[i]}" inputmode="decimal" style="font-size:15px;padding:8px 10px" data-testid="create-odd-${i}" aria-label="Initial probability of outcome ${i + 1}"><span class="suffix">%</span></div>` : "<span></span>"}
            <button type="button" class="btn sm ghost" data-rm="${i}" ${f.outcomes.length <= 2 ? "disabled" : ""} aria-label="Remove outcome">✕</button>
          </div>`,
        )
        .join(""),
    );
    el("#c-add").disabled = f.outcomes.length >= 8;
  }

  function renderTokens() {
    setHTML(
      el("#c-tokens"),
      usable
        .map((t) => {
          const bal = state.balances[t.symbol] ?? 0n;
          return `<button type="button" class="${sameAddr(t.address, f.token) ? "active" : ""}" data-token="${t.address}" data-testid="create-token-${t.symbol}">
            <b>${esc(t.symbol)}</b><span>${t.decimals} decimals · bal ${fmtToken(bal, t, { symbol: false })}</span></button>`;
        })
        .join(""),
    );
    const t = tokens.find((x) => sameAddr(x.address, f.token));
    el("#c-liq-unit").textContent = t.symbol;
  }

  function uniformOdds(n) {
    const base = Math.floor(10000 / n) / 100;
    const arr = Array(n).fill(base);
    arr[n - 1] = Math.round((100 - base * (n - 1)) * 100) / 100;
    return arr;
  }

  function validate() {
    const errs = [];
    const t = tokens.find((x) => sameAddr(x.address, f.token));
    const chainNow = state.chain.time;
    const q = f.question.trim();
    if (!q) errs.push("Enter a question.");
    if (new TextEncoder().encode(f.question).length > 280) errs.push("Question is longer than 280 bytes.");
    if (new TextEncoder().encode(f.category).length > 32) errs.push("Category is longer than 32 bytes.");
    f.outcomes.forEach((o, i) => {
      if (!o.trim()) errs.push(`Outcome ${i + 1} needs a label.`);
      else if (new TextEncoder().encode(o).length > 48) errs.push(`Outcome ${i + 1} label is too long.`);
    });
    if (new Set(f.outcomes.map((o) => o.trim().toLowerCase())).size !== f.outcomes.length) errs.push("Outcome labels must be distinct.");
    if (!f.close || f.close <= chainNow) errs.push(`Trading must close after the current chain time (${fmtDate(chainNow)}).`);
    if (!f.resolution || f.resolution < f.close) errs.push("Resolution time must be at or after the close time.");
    if (f.mode === "arbitrator" && !ethers.isAddress(f.arbitrator)) errs.push("Enter a valid arbitrator address.");
    const liq = parseAmount(f.liquidity, t.decimals);
    if (!liq) errs.push("Enter the initial liquidity.");
    const min = minLiq.get(t.address.toLowerCase()) ?? 1n;
    if (liq && liq < min) errs.push(`Minimum initial liquidity is ${fmtToken(min, t)}.`);
    if (liq && state.wallet.address && liq > (state.balances[t.symbol] ?? 0n)) errs.push(`Insufficient ${t.symbol} balance (get some on the Wallet page).`);
    let oddsBps = [];
    if (f.odds) {
      oddsBps = f.odds.map((x) => Math.round(Number(x) * 100));
      if (oddsBps.some((x) => !Number.isFinite(x) || x < 100)) errs.push("Each initial probability must be at least 1%.");
      const sum = oddsBps.reduce((a, b) => a + b, 0);
      if (sum !== 10000) errs.push(`Initial odds add up to ${(sum / 100).toFixed(2)}%, not 100%.`);
    }
    if (!state.wallet.address) errs.push("Connect a wallet.");
    return { errs, t, liq, oddsBps };
  }

  function renderPreview() {
    const { errs, t, liq } = validate();
    const chainNow = state.chain.time;
    const probs = f.odds ? f.odds.map((x) => Number(x) / 100) : f.outcomes.map(() => 1 / f.outcomes.length);
    const arbText = f.mode === "oracle" ? "Reputation-weighted reporter vote" : `${nameOf(f.arbitrator)}${ethers.isAddress(f.arbitrator) ? "" : " (invalid)"}`;
    setHTML(
      el("#c-preview"),
      `<div class="card market-card" style="box-shadow:none;cursor:default">
         <div class="mc-top"><span class="badge cat">${esc(f.category || "General")}</span><span class="badge trading"><span class="bdot"></span>Trading</span><span class="badge token">${esc(t.symbol)}</span></div>
         <div class="mc-q">${esc(f.question || "Your question appears here")}</div>
         <div class="odds-list">${f.outcomes
           .map(
             (o, i) => `<div class="odds-row"><div class="o-label"><span class="keydot" style="background:${seriesColor(i)}"></span><span>${esc(o || `Outcome ${i + 1}`)}</span></div>
               <div class="o-pct">${pct(probs[i] || 0, 0)}</div><div class="o-bar"><i style="width:${((probs[i] || 0) * 100).toFixed(1)}%;background:${seriesColor(i)}"></i></div></div>`,
           )
           .join("")}</div>
       </div>
       <div class="quote" style="margin-top:12px">
         <div class="qrow"><span>Resolution</span><b>${esc(arbText)}</b></div>
         <div class="qrow"><span>Trading closes</span><b>${f.close ? `${fmtDate(f.close)}` : "—"}</b></div>
         <div class="qrow"><span>Time until close</span><b>${f.close && f.close > chainNow ? fmtDuration(f.close - chainNow) : "—"}</b></div>
         <div class="qrow"><span>Report from</span><b>${f.resolution ? fmtDate(f.resolution) : "—"}</b></div>
         <div class="qrow"><span>Liquidity</span><b>${liq ? fmtToken(liq, t) : "—"}</b></div>
         <div class="qrow"><span>LP fee</span><b>${f.feeBps / 100}%</b></div>
       </div>`,
    );
    setHTML(el("#c-errors"), errs.length ? `<ul style="margin:0;padding-left:18px">${errs.map((e) => `<li>${esc(e)}</li>`).join("")}</ul>` : "");
    el("#c-submit").disabled = errs.length > 0;
    el("#c-arb-field").hidden = f.mode !== "arbitrator";
    el("#c-qcount").textContent = `(${f.question.length}/280)`;
    el("#c-timehint").textContent = `Chain time now: ${fmtDate(chainNow)}. Times are entered in your local timezone.`;
    el("#c-liq-hint").textContent = `Minimum ${fmtToken(minLiq.get(t.address.toLowerCase()) ?? 1n, t, { frac: 4 })}. Your balance: ${fmtToken(state.balances[t.symbol] ?? 0n, t)}.`;
    $$("#c-cats .chip", root).forEach((c) => c.classList.toggle("active", c.dataset.cat === f.category));
  }

  // ---- events
  el("#c-question").oninput = (e) => {
    f.question = e.target.value;
    renderPreview();
  };
  el("#c-category").oninput = (e) => {
    f.category = e.target.value;
    renderPreview();
  };
  el("#c-cats").onclick = (e) => {
    const c = e.target.closest("[data-cat]");
    if (!c) return;
    f.category = c.dataset.cat;
    el("#c-category").value = f.category;
    renderPreview();
  };
  el("#c-outcomes").oninput = (e) => {
    const oi = e.target.dataset.oi;
    const od = e.target.dataset.odd;
    if (oi !== undefined) f.outcomes[Number(oi)] = e.target.value;
    if (od !== undefined) f.odds[Number(od)] = e.target.value;
    renderPreview();
  };
  el("#c-outcomes").onclick = (e) => {
    const b = e.target.closest("[data-rm]");
    if (!b || b.disabled) return;
    f.outcomes.splice(Number(b.dataset.rm), 1);
    if (f.odds) f.odds = uniformOdds(f.outcomes.length);
    renderOutcomes();
    renderPreview();
  };
  el("#c-add").onclick = () => {
    if (f.outcomes.length >= 8) return;
    f.outcomes.push("");
    if (f.odds) f.odds = uniformOdds(f.outcomes.length);
    renderOutcomes();
    renderPreview();
    const inputs = $$("[data-oi]", root);
    inputs[inputs.length - 1].focus();
  };
  el("#c-yesno").onclick = () => {
    f.outcomes = ["Yes", "No"];
    if (f.odds) f.odds = uniformOdds(2);
    renderOutcomes();
    renderPreview();
  };
  el("#c-odds-on").onchange = (e) => {
    f.odds = e.target.checked ? uniformOdds(f.outcomes.length) : null;
    renderOutcomes();
    renderPreview();
  };
  el("#c-close").oninput = (e) => {
    f.close = fromLocalInput(e.target.value);
    renderPreview();
  };
  el("#c-resolution").oninput = (e) => {
    f.resolution = fromLocalInput(e.target.value);
    renderPreview();
  };
  $$('input[name="c-mode"]', root).forEach((r) => {
    r.onchange = () => {
      f.mode = r.value;
      renderPreview();
    };
  });
  el("#c-arbitrator").oninput = (e) => {
    f.arbitrator = e.target.value.trim();
    renderPreview();
  };
  el("#c-arb-pick").onchange = (e) => {
    if (!e.target.value) return;
    f.arbitrator = e.target.value;
    el("#c-arbitrator").value = f.arbitrator;
    e.target.value = "";
    renderPreview();
  };
  el("#c-tokens").onclick = (e) => {
    const b = e.target.closest("[data-token]");
    if (!b) return;
    f.token = b.dataset.token;
    const t = tokens.find((x) => sameAddr(x.address, f.token));
    f.liquidity = t.symbol === "WETH" ? "2" : "1000";
    el("#c-liquidity").value = f.liquidity;
    renderTokens();
    renderPreview();
  };
  el("#c-liquidity").oninput = (e) => {
    f.liquidity = e.target.value;
    renderPreview();
  };
  el("#c-fee").onchange = (e) => {
    f.feeBps = Number(e.target.value);
    renderPreview();
  };
  el("#c-submit").onclick = (e) =>
    withButton(e.currentTarget, async () => {
      const { errs, t, liq, oddsBps } = validate();
      if (errs.length) return;
      if (!(await ensureAllowance(t, pm.target, liq))) return;
      const params = {
        question: f.question.trim(),
        category: f.category.trim(),
        outcomeLabels: f.outcomes.map((o) => o.trim()),
        closeTime: f.close,
        resolutionTime: f.resolution,
        arbitrator: f.mode === "oracle" ? ORACLE_ADDRESS : f.arbitrator,
        collateral: t.address,
        initialLiquidity: liq,
        initialOddsBps: f.odds ? oddsBps : [],
        feeBps: f.feeBps,
      };
      const receipt = await sendTx("Create market", () => withSigner(pm).createMarket(params));
      if (!receipt) return;
      const created = receipt.logs
        .map((l) => {
          try {
            return pm.interface.parseLog(l);
          } catch {
            return null;
          }
        })
        .find((x) => x && x.name === "MarketCreated");
      if (created) location.hash = `#/market/${created.args.marketId}`;
    });

  renderOutcomes();
  renderTokens();
  renderPreview();

  return {
    refresh() {
      renderTokens();
      renderPreview();
    },
    unmount() {},
  };
}
