// Entry point: boot, hash router, polling loop (chain clock + data refresh), theme, dev tools.
import { state, bus } from "./state.js";
import { toast, $, $$ } from "./ui.js";
import { esc, fmtDate } from "./format.js";

function fatal(msg) {
  document.getElementById("app").innerHTML = `<div class="card card-pad" style="max-width:640px;margin:60px auto">
    <h2>Cannot start the app</h2><p class="text-2" style="margin-top:8px">${msg}</p></div>`;
}

if (!window.ethers) {
  fatal("ethers.js failed to load (frontend/vendor/ethers.umd.min.js).");
  throw new Error("ethers missing");
}
if (!window.APP_CONFIG) {
  fatal("<code>frontend/config.js</code> is missing. Start the stack with <code>./run.sh</code>, which deploys the contracts and generates it.");
  throw new Error("config missing");
}

const chain = await import("./chain.js");
const wallet = await import("./wallet.js");
const views = {
  markets: await import("./views/markets.js"),
  market: await import("./views/market.js"),
  portfolio: await import("./views/portfolio.js"),
  create: await import("./views/create.js"),
  reporters: await import("./views/reporters.js"),
  wallet: await import("./views/wallet.js"),
};
const devtools = await import("./views/devtools.js");

const ROUTES = [
  { re: /^#\/market\/(\d+)$/, view: "market", nav: "markets" },
  { re: /^#\/portfolio$/, view: "portfolio", nav: "portfolio" },
  { re: /^#\/create$/, view: "create", nav: "create" },
  { re: /^#\/reporters$/, view: "reporters", nav: "reporters" },
  { re: /^#\/wallet$/, view: "wallet", nav: "wallet" },
  { re: /^(#\/?)?$/, view: "markets", nav: "markets" },
];

let current = null;
let routeSeq = 0;

async function route() {
  const hash = location.hash || "#/";
  const r = ROUTES.find((x) => x.re.test(hash)) || ROUTES[ROUTES.length - 1];
  const params = (hash.match(r.re) || []).slice(1);
  const seq = ++routeSeq;
  if (current?.instance?.unmount) current.instance.unmount();
  current = null;
  const app = document.getElementById("app");
  // every view renders into its own container: async work of a view that was navigated away from keeps
  // operating on its (now detached) DOM instead of touching the next view's elements
  const root = document.createElement("div");
  root.className = "view";
  app.replaceChildren(root);
  root.innerHTML = '<div class="loading">Loading…</div>';
  $$("#nav a").forEach((a) => a.classList.toggle("active", a.dataset.route === r.nav));
  try {
    const instance = await views[r.view].mount(root, ...params);
    if (seq !== routeSeq) {
      instance?.unmount?.();
      return;
    }
    current = { name: r.view, instance };
    window.scrollTo({ top: 0 });
  } catch (e) {
    console.error(e);
    root.innerHTML = `<div class="card card-pad"><h2>Something went wrong</h2><p class="text-2" style="margin-top:6px">${esc(chain.decodeError(e))}</p></div>`;
  }
}

// ------------------------------------------------------------------------------------------------ polling

let refreshing = false;
let pending = false;
let lastBlock = -1;

async function refreshAll(force = false) {
  if (refreshing) {
    pending = true;
    return;
  }
  refreshing = true;
  try {
    const b = await chain.refreshClock();
    state.chain.ok = true;
    renderClock();
    if (force || b.number !== lastBlock) {
      lastBlock = b.number;
      await wallet.refreshBalances();
      if (current?.instance?.refresh) await current.instance.refresh();
      devtools.refresh();
    }
  } catch (e) {
    state.chain.ok = false;
    renderClock();
    console.warn("refresh failed", e);
  } finally {
    refreshing = false;
    if (pending) {
      pending = false;
      setTimeout(() => refreshAll(true), 0);
    }
  }
}

function renderClock() {
  const pill = document.getElementById("chain-pill");
  pill.classList.toggle("stale", !state.chain.ok);
  document.getElementById("chain-name").textContent = chain.cfg.chainName;
  document.getElementById("chain-clock").textContent = state.chain.ok
    ? `${fmtDate(state.chain.time)} · #${state.chain.block}`
    : "RPC unreachable";
  const banner = document.getElementById("banner");
  const w = state.wallet;
  let msg = "";
  if (!state.chain.ok) msg = `Cannot reach the RPC at ${chain.cfg.rpcUrl}. Is ./run.sh still running?`;
  else if (w.mode === "injected" && !w.chainOk) msg = `Your wallet is on the wrong network. Please switch to ${chain.cfg.chainName} (chainId ${chain.cfg.chainId}).`;
  banner.hidden = !msg;
  if (msg) {
    banner.innerHTML = `${esc(msg)}${w.mode === "injected" && !w.chainOk ? ' <button class="btn sm" id="banner-switch">Switch network</button>' : ""}`;
    const b = document.getElementById("banner-switch");
    if (b) b.onclick = () => wallet.switchInjectedChain();
  }
}

// ------------------------------------------------------------------------------------------------ theme

document.getElementById("theme-toggle").onclick = () => {
  const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  try {
    localStorage.setItem("polshi.theme", next);
  } catch {
    /* ignore */
  }
  bus.emit("theme");
};

// ------------------------------------------------------------------------------------------------ boot

bus.on("wallet", async () => {
  wallet.renderWalletWidget();
  renderClock();
  await refreshAll(true);
});
bus.on("balances", () => wallet.renderWalletWidget());
bus.on("tx", () => refreshAll(true));

window.addEventListener("hashchange", route);

try {
  await chain.refreshClock();
} catch {
  state.chain.ok = false;
}
renderClock();
await wallet.restoreWallet();
wallet.renderWalletWidget();
if (chain.isLocalChain) devtools.mount(document.getElementById("devtools"));
await route();
await refreshAll(true);
setInterval(() => refreshAll(false), 1500);

if (!state.wallet.address && !chain.isLocalChain) {
  toast.info("Connect a wallet", "Use the wallet button (top right) to connect MetaMask.");
}
