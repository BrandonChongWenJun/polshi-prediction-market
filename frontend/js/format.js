// Formatting helpers. All on-chain amounts are bigint base units; decimals come from the collateral token.
const { ethers } = window;

/** HTML-escape untrusted text (market questions, labels, names) before it goes into innerHTML templates. */
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

/** Number of fraction digits worth showing for a token amount. */
export function displayDecimals(token) {
  return token && token.symbol === "WETH" ? 4 : 2;
}

/** bigint base units -> localized string with at most `maxFrac` decimals (never rounds a non-zero value to 0). */
export function fmtUnits(value, decimals, maxFrac = 2, minFrac = 0) {
  if (value === undefined || value === null) return "—";
  const v = BigInt(value);
  const n = Number(ethers.formatUnits(v, decimals));
  const floor = 10 ** -maxFrac;
  if (v !== 0n && Math.abs(n) < floor) return `${n < 0 ? "-" : ""}<${floor.toFixed(maxFrac)}`;
  return n.toLocaleString("en-US", { minimumFractionDigits: minFrac, maximumFractionDigits: maxFrac });
}

export function fmtToken(value, token, { symbol = true, frac } = {}) {
  if (!token) return fmtUnits(value, 18, 4);
  const s = fmtUnits(value, token.decimals, frac ?? displayDecimals(token));
  return symbol ? `${s} ${token.symbol}` : s;
}

/** Shares have the collateral's decimals (1 share redeems for at most 1 collateral unit). */
export function fmtShares(value, token) {
  return fmtUnits(value, token ? token.decimals : 18, token && token.symbol === "WETH" ? 4 : 2);
}

/** Parse a user-typed decimal string into base units; returns null if invalid. */
export function parseAmount(text, decimals) {
  const s = String(text ?? "").trim().replace(/,/g, "");
  if (!s || !/^\d*\.?\d*$/.test(s) || s === ".") return null;
  const [whole, frac = ""] = s.split(".");
  if (frac.length > decimals) return null;
  try {
    return ethers.parseUnits(`${whole || "0"}.${frac || "0"}`, decimals);
  } catch {
    return null;
  }
}

/** Exact decimal string (for "Max" buttons). */
export function toInput(value, decimals) {
  let s = ethers.formatUnits(BigInt(value), decimals);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
}

export function pct(p, digits = 1) {
  if (p === undefined || p === null || Number.isNaN(p)) return "—";
  const v = p * 100;
  if (v > 0 && v < 0.1) return "<0.1%";
  if (v < 100 && v > 99.9) return ">99.9%";
  return `${v.toFixed(digits)}%`;
}

/** Probability as a price: 0.62 -> "0.620" */
export function price(p, digits = 3) {
  return Number(p).toFixed(digits);
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function fmtDate(ts, { time = true, year = true } = {}) {
  if (!ts) return "—";
  const d = new Date(Number(ts) * 1000);
  const base = `${d.getDate()} ${MONTHS[d.getMonth()]}${year ? ` ${d.getFullYear()}` : ""}`;
  if (!time) return base;
  return `${base}, ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function fmtDuration(seconds) {
  let s = Math.max(0, Math.round(Math.abs(seconds)));
  const d = Math.floor(s / 86400);
  s -= d * 86400;
  const h = Math.floor(s / 3600);
  s -= h * 3600;
  const m = Math.floor(s / 60);
  if (d > 0) return h ? `${d}d ${h}h` : `${d}d`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

/** "in 3d 4h" / "2h 5m ago" relative to chain time. */
export function fmtRelative(ts, now) {
  const delta = Number(ts) - Number(now);
  return delta >= 0 ? `in ${fmtDuration(delta)}` : `${fmtDuration(delta)} ago`;
}

export function shortAddr(a) {
  if (!a) return "—";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

/** Implied probabilities from AMM pool balances: p_i = (1/b_i) / sum_k (1/b_k). */
export function pricesFromPool(pool) {
  const nums = pool.map((b) => Number(b));
  if (nums.some((b) => b <= 0)) return nums.map(() => 1 / nums.length);
  const inv = nums.map((b) => 1 / b);
  const sum = inv.reduce((a, b) => a + b, 0);
  return inv.map((x) => x / sum);
}

export function compact(n) {
  const v = Number(n);
  if (Math.abs(v) >= 1e6) return `${(v / 1e6).toFixed(1)}M`;
  if (Math.abs(v) >= 1e4) return `${(v / 1e3).toFixed(1)}K`;
  return v.toLocaleString("en-US", { maximumFractionDigits: 2 });
}
