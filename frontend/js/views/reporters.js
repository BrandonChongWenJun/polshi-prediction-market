// Reputation oracle: parameters, reporter leaderboard, vote-resolved markets, admin registry.
import { state } from "../state.js";
import { oracle, cfg, withSigner, sendTx, nameOf, sameAddr, avatarColor } from "../chain.js";
import { fetchReporters, fetchOracleParams, fetchMarkets, fetchRound, phaseInfo, PHASE, ROUND } from "../data.js";
import { esc, fmtDuration, fmtRelative, shortAddr } from "../format.js";
import { $, setHTML, withButton } from "../ui.js";

const { ethers } = window;

export async function mount(root) {
  root.innerHTML = `
    <div class="page-head"><div><h1>Reporters & reputation</h1>
      <p>Markets can opt out of a single trusted arbitrator and be resolved by registered reporters instead. Each vote is weighted by the reporter's reputation; agreeing with the final consensus earns reputation, disagreeing loses it.</p></div></div>
    <div class="tiles" id="r-tiles"></div>
    <div class="detail-grid">
      <div class="stack">
        <div class="card"><div class="card-head"><h3>Leaderboard</h3></div><div class="card-body" id="r-board"></div></div>
        <div class="card"><div class="card-head"><h3>Vote-resolved markets</h3></div><div class="card-body" id="r-markets"></div></div>
      </div>
      <div class="side">
        <div class="card card-pad" id="r-rules"></div>
        <div class="card card-pad" id="r-admin"></div>
      </div>
    </div>`;

  const refresh = async () => {
    const [params, reps, markets] = await Promise.all([fetchOracleParams(), fetchReporters(), fetchMarkets()]);
    const oracleMarkets = markets.filter((m) => m.isOracle);
    const rounds = await Promise.all(oracleMarkets.map((m) => fetchRound(m.id, m.n)));
    const now = state.chain.time;
    const me = state.wallet.address;
    const maxRep = Math.max(params.maxRep / 4, ...reps.list.map((r) => r.reputation));
    const sorted = reps.list.slice().sort((a, b) => Number(b.registered) - Number(a.registered) || b.reputation - a.reputation);
    const openVotes = oracleMarkets.filter((m, i) => rounds[i].status === ROUND.Pending && now >= rounds[i].votingStart && !m.resolved).length;
    setHTML(
      $("#r-tiles", root),
      `<div class="card tile"><div class="t-label">Active reporters</div><div class="t-value">${reps.active}</div><div class="t-sub">max 50 (bounded loops)</div></div>
       <div class="card tile"><div class="t-label">Total reputation</div><div class="t-value">${reps.total.toString()}</div><div class="t-sub">sum over registered reporters</div></div>
       <div class="card tile"><div class="t-label">Vote-resolved markets</div><div class="t-value">${oracleMarkets.length}</div><div class="t-sub">${openVotes} voting now</div></div>
       <div class="card tile"><div class="t-label">Quorum</div><div class="t-value">${params.quorumBps / 100}%</div><div class="t-sub">of total reputation</div></div>`,
    );
    setHTML(
      $("#r-board", root),
      sorted.length
        ? `<table class="tbl" data-testid="reporter-table"><thead><tr><th>#</th><th>Reporter</th><th>Reputation</th><th class="r">Votes</th><th class="r">Correct</th><th class="r">Accuracy</th><th>Status</th></tr></thead><tbody>${sorted
            .map(
              (r, i) => `<tr data-testid="reporter-${nameOf(r.address)}"><td>${i + 1}</td>
                <td><span class="who"><span class="avatar" style="width:24px;height:24px;font-size:11px;background:${avatarColor(r.address)}">${esc(nameOf(r.address)[0])}</span><b>${esc(nameOf(r.address))}</b> <span class="mono tiny muted">${shortAddr(r.address)}</span></span></td>
                <td><div class="row"><div class="rep-bar grow"><i style="width:${((r.reputation / maxRep) * 100).toFixed(1)}%"></i></div><b class="num" data-testid="rep-${nameOf(r.address)}">${r.reputation}</b></div></td>
                <td class="r">${r.votesCast}</td><td class="r">${r.correctVotes}</td><td class="r">${r.votesCast ? `${Math.round((r.correctVotes / r.votesCast) * 100)}%` : "—"}</td>
                <td>${r.registered ? '<span class="badge trading">registered</span>' : '<span class="badge closed">removed</span>'}</td></tr>`,
            )
            .join("")}</tbody></table>`
        : '<p class="muted">No reporters registered yet.</p>',
    );
    setHTML(
      $("#r-markets", root),
      oracleMarkets.length
        ? `<table class="tbl"><thead><tr><th>Market</th><th>Status</th><th class="r">Turnout</th><th>Window</th></tr></thead><tbody>${oracleMarkets
            .map((m, i) => {
              const r = rounds[i];
              const ph = phaseInfo(m, r);
              let win = "";
              if (m.resolved) win = "closed";
              else if (now < r.votingStart) win = `opens ${fmtRelative(r.votingStart, now)}`;
              else if (now < r.votingEnd) win = `ends ${fmtRelative(r.votingEnd, now)}`;
              else win = "ended — finalize";
              return `<tr><td><a href="#/market/${m.id}">${esc(m.question)}</a></td><td><span class="badge ${ph.key}">${esc(ph.text)}</span></td>
                <td class="r">${r.totalWeight} / ${r.requiredWeight}</td><td class="small">${esc(win)}</td></tr>`;
            })
            .join("")}</tbody></table>`
        : '<p class="muted">No market uses the reputation oracle yet. Pick “Reputation-weighted reporter vote” when creating one.</p>',
    );
    setHTML(
      $("#r-rules", root),
      `<h3>Mechanism</h3>
       <div class="quote" style="margin-top:10px">
         <div class="qrow"><span>Starting reputation</span><b>${params.initial}</b></div>
         <div class="qrow"><span>Voting window</span><b>${fmtDuration(params.votingPeriod)} (+${fmtDuration(params.votingPeriod)} once)</b></div>
         <div class="qrow"><span>Quorum</span><b>${params.quorumBps / 100}% of total reputation</b></div>
         <div class="qrow"><span>Vote with consensus</span><b class="good">+${params.reward} rep</b></div>
         <div class="qrow"><span>Vote against consensus</span><b class="bad">−${params.slashBps / 100}% of rep</b></div>
         <div class="qrow"><span>Reputation cap</span><b>${params.maxRep}</b></div>
       </div>
       <p class="small text-2" style="margin-top:10px">No quorum or a tie: voting is extended once; if still undecided the market resolves INVALID and nobody's reputation changes. If nobody finalizes before the market's 7-day arbitration deadline, the round is voided and the market becomes INVALID.</p>`,
    );
    const isOwner = sameAddr(me, params.owner);
    const candidates = cfg.demoAccounts.filter((a) => !reps.list.some((r) => r.registered && sameAddr(r.address, a.address)));
    setHTML(
      $("#r-admin", root),
      `<h3>Registry admin</h3>
       <p class="small text-2" style="margin-top:6px">Owner: <b>${esc(nameOf(params.owner))}</b>. Registration is permissioned (Sybil resistance) and capped at 50 reporters.</p>
       ${
         isOwner
           ? `<div class="field" style="margin-top:10px"><label for="r-addr">Reporter address</label>
                <input class="input mono" id="r-addr" placeholder="0x…" list="r-cands" data-testid="reporter-address">
                <datalist id="r-cands">${candidates.map((a) => `<option value="${a.address}">${esc(a.name)}</option>`).join("")}</datalist></div>
              <div class="row" style="margin-top:10px"><button class="btn primary grow" id="r-register" data-testid="reporter-register">Register</button><button class="btn grow" id="r-remove">Remove</button></div>`
           : '<p class="small muted" style="margin-top:8px">Switch to the owner account (Alice) to register or remove reporters.</p>'
       }`,
    );
    const reg = $("#r-register", root);
    if (reg && !reg.onclick) {
      reg.onclick = (e) =>
        withButton(e.currentTarget, async () => {
          const a = $("#r-addr", root).value.trim();
          if (!ethers.isAddress(a)) return;
          await sendTx(`Register ${nameOf(a)}`, () => withSigner(oracle).registerReporter(a));
        });
      $("#r-remove", root).onclick = (e) =>
        withButton(e.currentTarget, async () => {
          const a = $("#r-addr", root).value.trim();
          if (!ethers.isAddress(a)) return;
          await sendTx(`Remove ${nameOf(a)}`, () => withSigner(oracle).removeReporter(a));
        });
    }
  };
  await refresh();
  return { refresh, unmount() {} };
}
