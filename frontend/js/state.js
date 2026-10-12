// Shared application state and a tiny event bus.

export const state = {
  chain: { time: 0, block: 0, updatedAt: 0, ok: true },
  wallet: { mode: null, address: null, signer: null, chainOk: true },
  balances: {}, // symbol -> bigint, plus ETH
  settings: { slippageBps: 100 },
};

const listeners = new Map();

export const bus = {
  on(event, fn) {
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(fn);
    return () => listeners.get(event).delete(fn);
  },
  emit(event, payload) {
    for (const fn of listeners.get(event) || []) {
      try {
        fn(payload);
      } catch (e) {
        console.error(`listener for ${event} failed`, e);
      }
    }
  },
};

export function loadSetting(key, fallback) {
  try {
    const v = localStorage.getItem(`wc.${key}`);
    return v === null ? fallback : JSON.parse(v);
  } catch {
    return fallback;
  }
}

export function saveSetting(key, value) {
  try {
    localStorage.setItem(`wc.${key}`, JSON.stringify(value));
  } catch {
    /* private mode */
  }
}
