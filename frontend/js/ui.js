// UI primitives: toasts, DOM helpers, badges.
import { esc } from "./format.js";

const ICONS = {
  pending: '<span class="spinner" style="width:14px;height:14px;border:2px solid var(--accent);border-right-color:transparent;border-radius:50%;display:inline-block;animation:spin .7s linear infinite"></span>',
  success: '<svg viewBox="0 0 20 20" width="18" height="18"><circle cx="10" cy="10" r="9" fill="var(--good)"/><path d="M6 10.5l2.5 2.5L14 7.5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  error: '<svg viewBox="0 0 20 20" width="18" height="18"><circle cx="10" cy="10" r="9" fill="var(--bad)"/><path d="M7 7l6 6M13 7l-6 6" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>',
  info: '<svg viewBox="0 0 20 20" width="18" height="18"><circle cx="10" cy="10" r="9" fill="var(--accent)"/><path d="M10 9v5M10 6.2v.1" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>',
};

function makeToast(kind, title, msg, timeout) {
  const box = document.getElementById("toasts");
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.setAttribute("role", kind === "error" ? "alert" : "status");
  el.dataset.kind = kind;
  const render = (k, t, m) => {
    el.className = `toast ${k}`;
    el.dataset.kind = k;
    el.innerHTML = `<div class="t-icon">${ICONS[k] || ICONS.info}</div>
      <div class="grow"><div class="t-title">${esc(t)}</div>${m ? `<div class="t-msg">${esc(m)}</div>` : ""}</div>
      <button class="t-close" aria-label="Dismiss">×</button>`;
    el.querySelector(".t-close").onclick = () => el.remove();
  };
  render(kind, title, msg);
  box.appendChild(el);
  while (box.children.length > 5) box.firstElementChild.remove();
  let timer = null;
  const arm = (ms) => {
    clearTimeout(timer);
    if (ms) timer = setTimeout(() => el.remove(), ms);
  };
  arm(timeout);
  return {
    el,
    update(t, m) {
      render("pending", t, m);
    },
    success(t, m) {
      render("success", t, m);
      arm(4500);
    },
    error(t, m) {
      render("error", t, m);
      arm(12000);
    },
  };
}

export const toast = {
  pending: (title, msg) => makeToast("pending", title, msg, 0),
  success: (title, msg) => makeToast("success", title, msg, 4500),
  error: (title, msg) => makeToast("error", title, msg, 12000),
  info: (title, msg) => makeToast("info", title, msg, 5000),
};

/** Build an element from an HTML string. */
export function html(str) {
  const t = document.createElement("template");
  t.innerHTML = str.trim();
  return t.content.firstElementChild;
}

export function $(sel, root = document) {
  return root.querySelector(sel);
}

export function $$(sel, root = document) {
  return Array.from(root.querySelectorAll(sel));
}

/** Replace innerHTML only when it changed (avoids flicker and keeps focus stable). */
export function setHTML(el, str) {
  if (!el) return;
  if (el.__html !== str) {
    el.innerHTML = str;
    el.__html = str;
  }
}

export function setText(el, str) {
  if (el && el.textContent !== str) el.textContent = str;
}

export function seriesColor(i) {
  return `var(--s${(i % 8) + 1})`;
}

/** Run an async click handler with the button disabled + spinner while it runs. */
export async function withButton(btn, fn) {
  if (!btn || btn.disabled) return;
  const original = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = `<span class="spinner"></span>${original}`;
  try {
    return await fn();
  } finally {
    btn.disabled = false;
    btn.innerHTML = original;
  }
}
