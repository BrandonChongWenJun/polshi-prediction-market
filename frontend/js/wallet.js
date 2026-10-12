// Wallet modes: (1) any EIP-1193 injected wallet (MetaMask), (2) local demo wallet over anvil's unlocked accounts.
import { state, bus, loadSetting, saveSetting } from "./state.js";
import { cfg, isLocalChain, readProvider, tokens, avatarColor, nameOf, sameAddr } from "./chain.js";
import { toast, $, $$ } from "./ui.js";
import { esc, shortAddr, fmtUnits } from "./format.js";

const { ethers } = window;
const CHAIN_HEX = "0x" + cfg.chainId.toString(16);

let localProvider = null;
function getLocalProvider() {
  if (!localProvider) {
    localProvider = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId, {
      staticNetwork: ethers.Network.from(cfg.chainId),
      pollingInterval: 400,
    });
  }
  return localProvider;
}

function setWallet(mode, address, signer, chainOk = true) {
  state.wallet = { mode, address, signer, chainOk };
  saveSetting("wallet", { mode, address });
  bus.emit("wallet");
}

/** Local demo wallet: signs with anvil's unlocked account via eth_sendTransaction. */
export async function useLocalAccount(address) {
  const provider = getLocalProvider();
  const signer = await provider.getSigner(address);
  setWallet("local", ethers.getAddress(address), signer);
}

async function ensureChain() {
  const current = await window.ethereum.request({ method: "eth_chainId" });
  if (String(current).toLowerCase() === CHAIN_HEX) return true;
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_HEX }] });
  } catch (e) {
    const code = e?.code ?? e?.data?.originalError?.code;
    if (code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: CHAIN_HEX,
            chainName: cfg.chainName,
            rpcUrls: [cfg.rpcUrl],
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          },
        ],
      });
    } else {
      throw e;
    }
  }
  const after = await window.ethereum.request({ method: "eth_chainId" });
  return String(after).toLowerCase() === CHAIN_HEX;
}

let injectedListeners = false;
function attachInjectedListeners() {
  if (injectedListeners || !window.ethereum?.on) return;
  injectedListeners = true;
  window.ethereum.on("accountsChanged", async (accounts) => {
    if (state.wallet.mode !== "injected") return;
    if (!accounts || accounts.length === 0) {
      setWallet(null, null, null);
      toast.info("Wallet disconnected");
      return;
    }
    await refreshInjected();
    toast.info("Account changed", shortAddr(accounts[0]));
  });
  window.ethereum.on("chainChanged", async () => {
    if (state.wallet.mode !== "injected") return;
    await refreshInjected();
  });
}

async function refreshInjected() {
  const provider = new ethers.BrowserProvider(window.ethereum, "any");
  const accounts = await window.ethereum.request({ method: "eth_accounts" });
  if (!accounts || accounts.length === 0) {
    setWallet(null, null, null);
    return;
  }
  const chainId = await window.ethereum.request({ method: "eth_chainId" });
  const chainOk = String(chainId).toLowerCase() === CHAIN_HEX;
  const signer = chainOk ? await provider.getSigner(accounts[0]) : null;
  setWallet("injected", ethers.getAddress(accounts[0]), signer, chainOk);
}

/** Injected wallet (MetaMask or any EIP-1193 provider): request accounts and the right chain. */
export async function connectInjected() {
  if (!window.ethereum) {
    toast.error("No browser wallet found", "Install MetaMask, or use the local demo wallet.");
    return false;
  }
  try {
    await window.ethereum.request({ method: "eth_requestAccounts" });
    const ok = await ensureChain();
    attachInjectedListeners();
    await refreshInjected();
    if (!ok) toast.error("Wrong network", `Switch your wallet to ${cfg.chainName} (chainId ${cfg.chainId}).`);
    return true;
  } catch (e) {
    toast.error("Could not connect wallet", e?.message || String(e));
    return false;
  }
}

export async function switchInjectedChain() {
  try {
    await ensureChain();
    await refreshInjected();
  } catch (e) {
    toast.error("Network switch failed", e?.message || String(e));
  }
}

export function disconnect() {
  setWallet(null, null, null);
}

/** Restore the previous session (local account or already-authorised injected wallet). */
export async function restoreWallet() {
  const saved = loadSetting("wallet", null);
  if (saved?.mode === "injected" && window.ethereum) {
    try {
      const accounts = await window.ethereum.request({ method: "eth_accounts" });
      if (accounts && accounts.length) {
        attachInjectedListeners();
        await refreshInjected();
        return;
      }
    } catch {
      /* fall through */
    }
  }
  if (isLocalChain && cfg.demoAccounts.length) {
    const addr =
      saved?.mode === "local" && cfg.demoAccounts.some((a) => sameAddr(a.address, saved.address))
        ? saved.address
        : cfg.demoAccounts[1]?.address || cfg.demoAccounts[0].address;
    await useLocalAccount(addr);
  }
}

// ------------------------------------------------------------------------------------------------ balances

export async function refreshBalances() {
  const addr = state.wallet.address;
  if (!addr) {
    state.balances = {};
    return;
  }
  const [eth, ...vals] = await Promise.all([
    readProvider.getBalance(addr),
    ...tokens.map((t) => t.contract.balanceOf(addr)),
  ]);
  const b = { ETH: BigInt(eth) };
  tokens.forEach((t, i) => (b[t.symbol] = BigInt(vals[i])));
  state.balances = b;
  bus.emit("balances");
}

// ------------------------------------------------------------------------------------------------ header widget

function avatar(addr, size = 30) {
  const name = nameOf(addr);
  const letter = /^0x/.test(name) ? "?" : name[0];
  return `<span class="avatar" style="background:${avatarColor(addr)};width:${size}px;height:${size}px">${esc(letter)}</span>`;
}
export { avatar };

let menuOpen = false;
let menuTab = null; // "local" | "injected" (defaults to the active wallet mode)

export function renderWalletWidget() {
  const root = document.getElementById("wallet");
  if (!root) return;
  const w = state.wallet;
  const label = w.address ? nameOf(w.address) : "Connect wallet";
  const sub = w.address ? shortAddr(w.address) : w.mode === "injected" ? "wrong network" : "not connected";
  const modeTitle = w.mode === "injected" ? "Browser wallet (EIP-1193)" : "Local demo wallet (anvil unlocked account)";
  const markup = `
    <button class="wallet-btn" id="wallet-btn" data-testid="wallet-button" aria-haspopup="true" aria-expanded="${menuOpen}" title="${esc(modeTitle)}" data-mode="${esc(w.mode || "")}">
      ${w.address ? avatar(w.address) : '<span class="avatar" style="background:var(--muted)">?</span>'}
      <span class="who"><b data-testid="current-account">${esc(label)}</b><span>${esc(sub)}</span></span>
      <svg viewBox="0 0 20 20" width="14" height="14" aria-hidden="true"><path d="M5 7.5l5 5 5-5" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/></svg>
    </button>
    ${menuOpen ? menuHTML() : ""}`;
  if (root.__markup === markup) return; // unchanged: keep the DOM (and any in-flight clicks) intact
  root.__markup = markup;
  root.innerHTML = markup;
  $("#wallet-btn", root).onclick = (e) => {
    e.stopPropagation();
    menuOpen = !menuOpen;
    menuTab = null;
    renderWalletWidget();
  };
  if (menuOpen) wireMenu(root);
}

function localListHTML() {
  const w = state.wallet;
  if (!isLocalChain) {
    return `<p class="small muted" style="margin-top:10px">The local demo wallet is only available on the local anvil chain.</p>`;
  }
  return `<div class="account-list" role="listbox" aria-label="Demo accounts">
    ${cfg.demoAccounts
      .map(
        (a) => `<button class="account-item ${w.mode === "local" && sameAddr(a.address, w.address) ? "active" : ""}" data-addr="${a.address}" data-testid="account-${a.name}" role="option">
          ${avatar(a.address, 28)}
          <span class="meta"><b>${esc(a.name)}</b><span>${esc(a.role)}</span></span>
          <span class="addr">${shortAddr(a.address)}</span>
        </button>`,
      )
      .join("")}
  </div>`;
}

function injectedHTML() {
  const w = state.wallet;
  const connected = w.mode === "injected" && w.address;
  return `<div style="margin-top:12px" class="stack">
    <p class="small text-2">Use MetaMask or any EIP-1193 browser wallet. The app asks it to switch to <b>${esc(cfg.chainName)}</b> (chainId ${cfg.chainId}) and follows account / network changes.</p>
    ${
      connected
        ? `<div class="row between"><span class="small">Connected: <b class="mono">${shortAddr(w.address)}</b></span>
           <button class="btn sm" id="wm-disconnect">Disconnect</button></div>
           ${w.chainOk ? "" : '<button class="btn primary block" id="wm-switch">Switch network</button>'}`
        : `<button class="btn primary block" id="wm-connect" data-testid="connect-injected" ${window.ethereum ? "" : "disabled"}>${window.ethereum ? "Connect browser wallet" : "No browser wallet detected"}</button>`
    }
  </div>`;
}

function menuHTML() {
  const w = state.wallet;
  const tab = menuTab || (w.mode === "injected" || !isLocalChain ? "injected" : "local");
  const bal = state.balances;
  const balances = w.address
    ? `<div class="balances-mini">
        <div>ETH<b>${fmtUnits(bal.ETH ?? 0n, 18, 3)}</b></div>
        ${tokens.map((t) => `<div>${esc(t.symbol)}<b data-testid="bal-${t.symbol}">${fmtUnits(bal[t.symbol] ?? 0n, t.decimals, t.symbol === "WETH" ? 4 : 2)}</b></div>`).join("")}
      </div>`
    : "";
  return `
    <div class="wallet-menu" id="wallet-menu" data-testid="wallet-menu">
      <div class="seg full" role="tablist">
        <button data-tab="local" class="${tab === "local" ? "active" : ""}" data-testid="mode-local" ${isLocalChain ? "" : "disabled"}>Demo accounts</button>
        <button data-tab="injected" class="${tab === "injected" ? "active" : ""}" data-testid="mode-injected">Browser wallet</button>
      </div>
      ${tab === "local" ? localListHTML() : injectedHTML()}
      ${balances}
      <div class="row between" style="margin-top:12px">
        <a href="#/wallet" class="small" id="wm-faucet">Faucet & balances →</a>
        <span class="tiny muted">${esc(cfg.chainName)} · ${cfg.chainId}</span>
      </div>
    </div>`;
}

function close() {
  menuOpen = false;
  menuTab = null;
  renderWalletWidget();
}

function wireMenu(root) {
  const menu = $("#wallet-menu", root);
  menu.onclick = (e) => e.stopPropagation();
  $$("[data-tab]", menu).forEach((b) => {
    b.onclick = () => {
      menuTab = b.dataset.tab;
      renderWalletWidget();
    };
  });
  $$(".account-item", menu).forEach((b) => {
    b.onclick = async () => {
      close();
      await useLocalAccount(b.dataset.addr);
      toast.info(`Switched to ${nameOf(b.dataset.addr)}`, "Local demo wallet (anvil unlocked account)");
    };
  });
  const c = $("#wm-connect", menu);
  if (c) c.onclick = async () => {
    close();
    await connectInjected();
  };
  const d = $("#wm-disconnect", menu);
  if (d) d.onclick = () => {
    close();
    disconnect();
  };
  const s = $("#wm-switch", menu);
  if (s) s.onclick = () => switchInjectedChain();
  const f = $("#wm-faucet", menu);
  if (f) f.onclick = () => close();
}

document.addEventListener("click", () => {
  if (menuOpen) close();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && menuOpen) close();
});
