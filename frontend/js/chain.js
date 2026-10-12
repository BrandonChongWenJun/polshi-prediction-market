// Chain access: config, read provider, contracts, custom-error decoding, transactions, allowances, dev tools.
import { state, bus } from "./state.js";
import { toast } from "./ui.js";
import { fmtUnits } from "./format.js";

const { ethers } = window;

export const cfg = window.APP_CONFIG;

export const readProvider = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId, {
  staticNetwork: ethers.Network.from(cfg.chainId),
  pollingInterval: 1000,
});

const C = cfg.contracts;
export const pm = new ethers.Contract(C.PredictionMarket.address, C.PredictionMarket.abi, readProvider);
export const book = new ethers.Contract(C.OrderBook.address, C.OrderBook.abi, readProvider);
export const oracle = new ethers.Contract(C.ReputationOracle.address, C.ReputationOracle.abi, readProvider);
export const ORACLE_ADDRESS = C.ReputationOracle.address;
export const INVALID = 255;
export const isLocalChain = cfg.chainId === 31337;

export const tokens = cfg.tokens.map((t) => ({
  ...t,
  contract: new ethers.Contract(t.address, t.abi, readProvider),
}));

export function tokenByAddress(addr) {
  if (!addr) return undefined;
  const a = addr.toLowerCase();
  return tokens.find((t) => t.address.toLowerCase() === a);
}

export function tokenBySymbol(sym) {
  return tokens.find((t) => t.symbol === sym);
}

export function sameAddr(a, b) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

// ------------------------------------------------------------------------------------------------ names

const NAME_BY_ADDR = new Map(cfg.demoAccounts.map((a) => [a.address.toLowerCase(), a.name]));
NAME_BY_ADDR.set(ORACLE_ADDRESS.toLowerCase(), "Reputation Oracle");
NAME_BY_ADDR.set(C.OrderBook.address.toLowerCase(), "Order Book");

export function nameOf(addr) {
  if (!addr) return "—";
  return NAME_BY_ADDR.get(addr.toLowerCase()) || `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function knownName(addr) {
  return addr ? NAME_BY_ADDR.get(addr.toLowerCase()) : undefined;
}

const AVATAR_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#b07d00", "#d4588a", "#008300", "#4a3aa7", "#e34948", "#0f7c8c", "#6b5b3e"];
export function avatarColor(addr) {
  const idx = cfg.demoAccounts.findIndex((a) => sameAddr(a.address, addr));
  if (idx >= 0) return AVATAR_COLORS[idx % AVATAR_COLORS.length];
  const h = parseInt((addr || "0x0").slice(2, 8), 16) || 0;
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

// ------------------------------------------------------------------------------------------------ errors

function collectErrorFragments() {
  const seen = new Set();
  const frags = [];
  const abis = [C.PredictionMarket.abi, C.OrderBook.abi, C.ReputationOracle.abi, ...cfg.tokens.map((t) => t.abi)];
  for (const abi of abis) {
    for (const item of abi) {
      if (item.type !== "error") continue;
      const sig = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
      if (seen.has(sig)) continue;
      seen.add(sig);
      frags.push(item);
    }
  }
  return frags;
}
const errorIface = new ethers.Interface(collectErrorFragments());

const ts = (t) => {
  const d = new Date(Number(t) * 1000);
  return d.toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
};

/** Human-readable messages for every custom error the contracts can raise. */
const FRIENDLY = {
  // PredictionMarket
  CollateralNotAllowed: () => "This collateral token is not on the allow-list.",
  InvalidCollateral: () => "Invalid collateral token.",
  InvalidOutcomeCount: (a) => `A market needs 2–8 outcomes (got ${a[0]}).`,
  InvalidTimes: () => "Close time must be in the future and resolution time must be at or after the close time.",
  InvalidArbitrator: () => "An arbitrator address is required.",
  FeeTooHigh: (a) => `Fee too high: ${Number(a[0]) / 100}% (max ${Number(a[1]) / 100}%).`,
  LiquidityTooLow: () => "Initial liquidity is below the minimum for this collateral.",
  InvalidText: () => "Question (1–280 chars), category (≤32) and outcome labels (1–48 chars) have length limits.",
  InvalidOdds: () => "Initial odds must be ≥1% each and sum to exactly 100%.",
  MarketNotFound: (a) => `Market #${a[0]} does not exist.`,
  TradingClosed: (a) => `Trading closed at ${ts(a[1])}.`,
  MarketAlreadyResolved: () => "The market is already resolved.",
  MarketNotResolved: () => "The market is not resolved yet.",
  InvalidOutcome: (a) => `Invalid outcome index ${a[0]}.`,
  ZeroAmount: () => "Amount too small — it rounds to zero.",
  SlippageExceeded: () => "Price moved beyond your slippage tolerance. Refresh the quote or raise the tolerance.",
  NoLiquidity: () => "The pool has no liquidity — add liquidity before trading.",
  InsufficientLpShares: () => "You don't have that many LP shares.",
  NotArbitrator: () => "Only this market's arbitrator can report the outcome.",
  ResolutionTooEarly: (a) => `Too early: the outcome can be reported from ${ts(a[0])}.`,
  ReportingWindowClosed: () => "The arbitration window has closed — resolve the market as invalid instead.",
  ReportingWindowOpen: (a) => `The arbitrator can still report until ${ts(a[0])}.`,
  NothingToRedeem: () => "Nothing to redeem: you hold no winning shares in this market.",
  NothingToClaim: () => "No fees to claim yet.",
  FeeOnTransferNotSupported: () => "Fee-on-transfer tokens are not supported.",
  EnforcedPause: () => "The protocol is paused by the admin (exits remain available).",
  // OrderBook
  MarketResolved: () => "The market is resolved; the order book is closed.",
  InvalidPrice: () => "Price must be between 0.0001 and 0.9999 per share.",
  InvalidExpiry: () => "Expiry must be in the future.",
  OrderNotFound: (a) => `Order #${a[0]} does not exist.`,
  OrderNotOpen: (a) => `Order #${a[0]} is no longer open (filled or cancelled).`,
  OrderExpired: (a) => `Order #${a[0]} expired at ${ts(a[1])}.`,
  NotMaker: () => "Only the maker can cancel this order.",
  SelfFill: () => "You cannot fill your own order.",
  FillExceedsRemaining: (a) => `Only ${a[1]} base units remain in this order.`,
  FillTooSmall: () => "Fill too small: the payout rounds to zero.",
  UnexpectedTokenTransfer: () => "Direct token transfers to the order book are rejected.",
  // ReputationOracle
  InvalidParameters: () => "Invalid parameters.",
  AlreadyRegistered: () => "That address is already a registered reporter.",
  NotRegistered: () => "Only registered reporters can vote (ask the oracle admin to register you).",
  TooManyReporters: () => "The reporter registry is full.",
  NoReputation: () => "Your reputation is zero, so your vote would carry no weight.",
  NotOracleMarket: () => "This market is not resolved by the reputation oracle.",
  RoundAlreadyFinalized: () => "Voting on this market has already been finalized.",
  VotingNotStarted: (a) => `Voting opens at ${ts(a[0])}.`,
  VotingClosed: (a) => `Voting closed at ${ts(a[0])}.`,
  VotingStillOpen: (a) => `Voting is still open until ${ts(a[0])}.`,
  AlreadyVoted: () => "You have already voted on this market.",
  // OpenZeppelin / tokens
  OwnableUnauthorizedAccount: () => "Only the contract owner (admin) can do this.",
  ReentrancyGuardReentrantCall: () => "Re-entrant call blocked.",
  ERC1155InsufficientBalance: () => "You don't hold enough outcome shares.",
  ERC1155MissingApprovalForAll: () => "The order book is not approved to move your shares.",
  ERC20InsufficientBalance: () => "Insufficient token balance.",
  ERC20InsufficientAllowance: () => "Token allowance too low — approve first.",
  SafeERC20FailedOperation: () => "Token transfer failed (check balance and allowance).",
  InsufficientBalance: () => "Insufficient token balance.",
  InsufficientAllowance: () => "Token allowance too low — approve first.",
  ApproveFromNonZero: () => "USDT requires resetting the allowance to 0 before changing it.",
};

function findRevertData(err, depth = 0) {
  if (!err || depth > 6) return null;
  if (typeof err === "string") return /^0x[0-9a-fA-F]{8,}$/.test(err) ? err : null;
  if (typeof err !== "object") return null;
  for (const key of ["data", "revert", "error", "info", "cause", "payload"]) {
    const v = err[key];
    if (typeof v === "string" && /^0x[0-9a-fA-F]{8,}$/.test(v)) return v;
    if (v && typeof v === "object") {
      if (key === "revert" && v.args && v.name) continue;
      const found = findRevertData(v, depth + 1);
      if (found) return found;
    }
  }
  // ethers wraps JSON-RPC errors as a JSON body string
  if (typeof err.body === "string") {
    try {
      return findRevertData(JSON.parse(err.body), depth + 1);
    } catch {
      /* ignore */
    }
  }
  return null;
}

/** Turn any error (ethers, JSON-RPC, wallet) into a short human-readable message. */
export function decodeError(err) {
  if (!err) return "Unknown error";
  const code = err.code ?? err.info?.error?.code ?? err.error?.code;
  if (code === "ACTION_REJECTED" || code === 4001) return "You rejected the request in your wallet.";
  const data = findRevertData(err);
  if (data) {
    try {
      const parsed = errorIface.parseError(data);
      if (parsed) {
        const fn = FRIENDLY[parsed.name];
        return fn ? fn(parsed.args) : `${parsed.name}(${parsed.args.map(String).join(", ")})`;
      }
    } catch {
      /* not one of ours */
    }
    if (data.startsWith("0x08c379a0")) {
      try {
        return ethers.AbiCoder.defaultAbiCoder().decode(["string"], "0x" + data.slice(10))[0];
      } catch {
        /* ignore */
      }
    }
    if (data.startsWith("0x4e487b71")) return "The transaction hit an arithmetic check (panic).";
  }
  if (err.revert?.name) {
    const fn = FRIENDLY[err.revert.name];
    return fn ? fn(err.revert.args) : err.revert.name;
  }
  const msg = err.shortMessage || err.info?.error?.message || err.reason || err.message || String(err);
  return msg.length > 220 ? msg.slice(0, 220) + "…" : msg;
}

// ------------------------------------------------------------------------------------------------ transactions

let busyCount = 0;
export function isBusy() {
  return busyCount > 0;
}

/**
 * Sends a transaction with pending / confirmed / failed feedback.
 * @param {string} label  human label ("Buy Yes")
 * @param {() => Promise<any>} build  returns an ethers TransactionResponse (e.g. contract.connect(signer).buy(...))
 * @returns receipt, or null on failure (the error is shown to the user)
 */
export async function sendTx(label, build) {
  if (!state.wallet.signer) {
    toast.error("No wallet connected", "Pick a demo account or connect MetaMask first.");
    return null;
  }
  const t = toast.pending(label, "Waiting for signature…");
  busyCount++;
  bus.emit("busy");
  try {
    const tx = await build();
    t.update(label, `Pending · ${tx.hash.slice(0, 10)}…`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error("Transaction reverted");
    t.success(label, `Confirmed in block ${receipt.blockNumber}`);
    return receipt;
  } catch (e) {
    console.warn(label, e);
    t.error(`${label} failed`, decodeError(e));
    return null;
  } finally {
    busyCount--;
    bus.emit("busy");
    bus.emit("tx");
  }
}

/** Signer-connected contract instance. */
export function withSigner(contract) {
  return contract.connect(state.wallet.signer);
}

/**
 * Makes sure `spender` may pull `amount` of `token` from the connected account (exact-amount approval).
 * USDT rejects non-zero -> non-zero allowance changes, so a non-zero leftover allowance is reset to 0 first.
 */
export async function ensureAllowance(token, spender, amount) {
  const owner = state.wallet.address;
  const current = await token.contract.allowance(owner, spender);
  if (current >= amount) return true;
  const label = `Approve ${fmtUnits(amount, token.decimals, 6)} ${token.symbol}`;
  if (current > 0n && token.symbol === "USDT") {
    const r0 = await sendTx(`Reset ${token.symbol} allowance`, () => withSigner(token.contract).approve(spender, 0n));
    if (!r0) return false;
  }
  const r = await sendTx(label, () => withSigner(token.contract).approve(spender, amount));
  return !!r;
}

/** Makes sure the order book may move the connected account's ERC1155 outcome shares (escrow / fills). */
export async function ensureShareApproval() {
  const ok = await pm.isApprovedForAll(state.wallet.address, book.target);
  if (ok) return true;
  const r = await sendTx("Allow order book to escrow your shares", () =>
    withSigner(pm).setApprovalForAll(book.target, true),
  );
  return !!r;
}

// ------------------------------------------------------------------------------------------------ chain clock & dev tools

export async function refreshClock() {
  const b = await readProvider.getBlock("latest");
  state.chain.time = b.timestamp;
  state.chain.block = b.number;
  state.chain.updatedAt = Date.now();
  return b;
}

/** Local anvil only: move chain time forward and mine a block. */
export async function increaseTime(seconds) {
  await readProvider.send("evm_increaseTime", [Math.floor(seconds)]);
  await readProvider.send("evm_mine", []);
  await refreshClock();
  bus.emit("tx");
}
