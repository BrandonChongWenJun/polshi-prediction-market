// Dev tools (local chain 31337 only): fast-forward chain time with evm_increaseTime + evm_mine and jump straight
// to the next market deadline (close / resolution / voting end / arbitration timeout).
import { state } from "../state.js";
import { increaseTime } from "../chain.js";
import { fetchMarkets, fetchRound, PHASE } from "../data.js";
import { esc, fmtDate, fmtDuration } from "../format.js";
import { $, setHTML, toast, withButton } from "../ui.js";

let root = null;
let open = false;
let updating = false;

async function jump(seconds, label) {
  if (seconds <= 0) return;
  await increaseTime(seconds);
  toast.success(`Time travel: +${fmtDuration(seconds)}`, label || `Chain time is now ${fmtDate(state.chain.time)}`);
}

async function deadlines() {
  const now = state.chain.time;
  const markets = await fetchMarkets();
  const out = [];
  for (const m of markets) {
    if (m.resolved) continue;
    const short = m.question.length > 60 ? m.question.slice(0, 59) + "…" : m.question;
    if (m.closeTime > now) out.push({ t: m.closeTime, text: `#${m.id} trading closes`, q: short });
    if (m.resolutionTime > now) out.push({ t: m.resolutionTime, text: `#${m.id} ${m.isOracle ? "voting opens" : "reporting opens"}`, q: short });
    if (m.isOracle && m.phase !== PHASE.Trading) {
      const r = await fetchRound(m.id, m.n);
      if (r.votingEnd > now && r.status === 0) out.push({ t: r.votingEnd, text: `#${m.id} voting ends`, q: short });
    }
    const dl = m.resolutionTime + 7 * 86400;
    if (dl > now) out.push({ t: dl, text: `#${m.id} arbitration deadline`, q: short });
  }
  return out.sort((a, b) => a.t - b.t).slice(0, 12);
}

function render() {
  if (!root) return;
  root.innerHTML = `<button class="dev-fab" id="dev-fab" data-testid="devtools-toggle" aria-expanded="${open}"><svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><circle cx="12" cy="13" r="8" stroke="currentColor" stroke-width="2" fill="none"/><path d="M12 9v4l2.5 2.5M9 2h6" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/></svg>Dev tools</button>
    ${
      open
        ? `<div class="dev-panel" data-testid="devtools-panel">
      <div class="row between"><b>Chain clock</b><span class="tiny muted">anvil · evm_increaseTime</span></div>
      <div class="dp-time" id="dev-time" data-testid="devtools-time"></div>
      <div class="tiny muted" id="dev-block"></div>
      <div class="grid-4" style="margin-top:10px">
        <button class="btn sm" data-dt="3600" data-testid="ff-1h">+1 h</button><button class="btn sm" data-dt="86400" data-testid="ff-1d">+1 day</button>
        <button class="btn sm" data-dt="604800" data-testid="ff-7d">+7 days</button><button class="btn sm" data-dt="2592000">+30 days</button>
      </div>
      <div class="row" style="margin-top:8px"><input class="input" id="dev-hours" inputmode="decimal" placeholder="hours" style="width:110px" data-testid="ff-hours"><button class="btn sm" id="dev-go" data-testid="ff-go">Fast-forward</button></div>
      <div class="label" style="margin-top:12px">Jump to next deadline</div>
      <div class="deadlines" id="dev-deadlines"></div>
    </div>`
        : ""
    }`;
  $("#dev-fab", root).onclick = () => {
    open = !open;
    render();
  };
  if (!open) return;
  root.querySelectorAll("[data-dt]").forEach((b) => (b.onclick = () => withButton(b, () => jump(Number(b.dataset.dt)))));
  $("#dev-go", root).onclick = (e) =>
    withButton(e.currentTarget, () => {
      const h = Number($("#dev-hours", root).value);
      if (h > 0) return jump(Math.round(h * 3600));
    });
  $("#dev-deadlines", root).onclick = (e) => {
    const b = e.target.closest("[data-jump]");
    if (b) withButton(b, () => jump(Number(b.dataset.jump) - state.chain.time + 1, "Jumped just past the deadline"));
  };
  update();
}

async function update() {
  if (!root || !open || updating) return;
  updating = true;
  try {
    const now = state.chain.time;
    const t = $("#dev-time", root);
    if (t) t.textContent = fmtDate(now);
    const b = $("#dev-block", root);
    if (b) b.textContent = `block #${state.chain.block} · one block is mined every second`;
    const list = await deadlines();
    setHTML(
      $("#dev-deadlines", root),
      list.length
        ? list
            .map(
              (d) => `<div class="deadline"><span class="dl-text" title="${esc(d.q)}"><b>${esc(d.text)}</b> <span class="muted">· in ${fmtDuration(d.t - now)}</span></span>
                <button class="btn sm" data-jump="${d.t}">Jump</button></div>`,
            )
            .join("")
        : '<p class="small muted">No upcoming deadlines.</p>',
    );
  } finally {
    updating = false;
  }
}

export function mount(container) {
  root = container;
  render();
}

export function refresh() {
  update();
}
