#!/usr/bin/env python3
"""End-to-end smoke test: drives the real UI (local demo wallet mode + a mocked EIP-1193 wallet) against a freshly
started ./run.sh and asserts on the on-screen outcomes of every main user flow, including the bonus features.

Flows covered
  1. market list with live odds (9 seeded markets)                       -> 01_markets.png
  2. market detail: probability chart, buy with price-impact preview    -> 02_trade_quote.png / 03_after_buy.png
  3. sell back part of the position (exact-input sell, slippage-protected)
  4. BONUS 1 P2P order book: place ask, partial fill by another user, cancel remainder -> 04_orderbook.png
  5. decoded custom-error revert (filling an order cancelled in another tab)          -> 05_decoded_error.png
  6. new user: faucet, create a 3-outcome USDT market (approval flow)   -> 06_created_market.png
  7. BONUS 2 multi-collateral: wrap ETH, trade the WETH market (18 dp), create a WETH market that is resolved by
     reputation vote with custom initial odds (70/30)                   -> 07_weth_trade.png / 07b_weth_vote_market.png
  8. liquidity: add and fully remove liquidity; mint and merge complete sets
  9. arbitrator reports -> winner redeems                                -> 08_reported.png
 10. arbitrator timeout -> resolve as invalid -> pro-rata redemption    -> 09_invalid.png
 11. BONUS 3 reputation-weighted vote: three reporters vote, dev-tools fast-forward, finalize,
     reputation leaderboard updated; the admin registers a new reporter -> 10_vote.png / 11_reporters.png
 12. injected-wallet (MetaMask-style) mode incl. network switch         -> 12_injected_wallet.png
 13. portfolio (claim LP fees), dark theme and phone-width layout      -> 13_portfolio.png / 14_dark_market.png /
                                                                           15_mobile_market.png

Usage
  python e2e/smoke_test.py                 # starts a fresh ./run.sh (ports 8554/5554), runs, stops it
  python e2e/smoke_test.py --no-start      # use an already running ./run.sh (fresh state expected)
Requires Playwright for Python with Chromium (in this environment: <scratchpad>/pw e2e/smoke_test.py).
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
import traceback

from playwright.sync_api import Page, sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "e2e", "screenshots")
ANVIL_PORT = int(os.environ.get("ANVIL_PORT", "8554"))
WEB_PORT = int(os.environ.get("WEB_PORT", "5554"))
BASE = f"http://127.0.0.1:{WEB_PORT}/"
RPC = f"http://127.0.0.1:{ANVIL_PORT}"
IVAN = "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f"

PASSED: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)
    PASSED.append(msg)
    print(f"  ✓ {msg}")


# ------------------------------------------------------------------------------------------------ stack


def start_stack() -> subprocess.Popen:
    env = dict(os.environ, ANVIL_PORT=str(ANVIL_PORT), WEB_PORT=str(WEB_PORT))
    proc = subprocess.Popen(
        [os.path.join(ROOT, "run.sh")], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=True,
    )
    deadline = time.time() + 300
    assert proc.stdout is not None
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError("run.sh exited before becoming ready")
            continue
        print("  [run.sh]", line.rstrip())
        if line.startswith("READY"):
            return proc
    raise RuntimeError("run.sh did not become ready in time")


def stop_stack(proc: subprocess.Popen | None) -> None:
    if not proc:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass


# ------------------------------------------------------------------------------------------------ UI helpers


class UI:
    def __init__(self, page: Page, tag: str = ""):
        self.page = page
        self.tag = tag
        self.errors: list[str] = []
        page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e.message} @ {(e.stack or '').splitlines()[1:3]}"))
        page.on("console", lambda m: m.type == "error" and self.errors.append(f"console: {m.text}"))

    def goto(self, hash_: str) -> None:
        self.page.goto(BASE + hash_)
        self.page.wait_for_selector("#app .loading", state="detached", timeout=20000)

    def shot(self, name: str, full: bool = True) -> None:
        if full:
            self.page.evaluate("window.scrollTo(0, 0)")
        self.page.wait_for_timeout(400)
        self.page.screenshot(path=os.path.join(SHOTS, f"{name}.png"), full_page=full)

    def clear_toasts(self) -> None:
        self.page.evaluate("document.querySelectorAll('.toast').forEach(t => t.remove())")

    def switch_account(self, name: str) -> None:
        cur = self.page.get_by_test_id("current-account").inner_text()
        if cur == name:
            return
        self.page.get_by_test_id("wallet-button").click()
        self.page.get_by_test_id("mode-local").click()
        self.page.get_by_test_id(f"account-{name}").click()
        self.page.wait_for_function(
            "n => document.querySelector('[data-testid=current-account]')?.textContent === n", arg=name, timeout=10000
        )
        self.page.wait_for_timeout(1200)  # let the view refresh for the new account
        self.clear_toasts()

    def wait_tx(self, label: str, timeout: int = 45000) -> None:
        """Wait until a success toast containing `label` appears; fail fast on any error toast."""
        self.page.wait_for_function(
            """(label) => [...document.querySelectorAll('.toast')].some(t =>
                   t.dataset.kind === 'error' || (t.dataset.kind === 'success' && t.textContent.includes(label)))""",
            arg=label,
            timeout=timeout,
        )
        err = self.page.evaluate(
            "() => [...document.querySelectorAll('.toast')].filter(t => t.dataset.kind === 'error').map(t => t.textContent).join(' | ')"
        )
        if err:
            raise AssertionError(f"transaction '{label}' failed: {err}")
        self.page.wait_for_timeout(700)

    def wait_error_toast(self, timeout: int = 30000) -> str:
        self.page.wait_for_function(
            "() => [...document.querySelectorAll('.toast')].some(t => t.dataset.kind === 'error')", timeout=timeout
        )
        return self.page.evaluate(
            "() => [...document.querySelectorAll('.toast')].filter(t => t.dataset.kind === 'error').map(t => t.textContent).join(' | ')"
        )

    def text(self, testid: str) -> str:
        return self.page.get_by_test_id(testid).inner_text()

    def num(self, testid: str) -> float:
        return parse_num(self.text(testid))

    def wait_text_change(self, testid: str, old: str, timeout: int = 15000) -> str:
        self.page.wait_for_function(
            "([id, old]) => { const e = document.querySelector(`[data-testid='${id}']`); return e && e.textContent !== old; }",
            arg=[testid, old],
            timeout=timeout,
        )
        return self.text(testid)

    def wait_for(self, js: str, arg=None, timeout: int = 20000) -> None:
        self.page.wait_for_function(js, arg=arg, timeout=timeout)


def parse_num(s: str) -> float:
    m = re.search(r"-?[\d,]*\.?\d+", s.replace(" ", ""))
    return float(m.group(0).replace(",", "")) if m else float("nan")


INJECTED_WALLET = """
(() => {
  const RPC = '%RPC%';
  let account = '%ACCOUNT%';
  const listeners = {};
  let chainId = '0x1';            // start on the wrong network to exercise wallet_switchEthereumChain
  let id = 0;
  async function rpc(method, params) {
    const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
    const j = await r.json();
    if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; }
    return j.result;
  }
  const emit = (ev, arg) => (listeners[ev] || []).forEach(f => { try { f(arg); } catch (e) {} });
  window.__walletLog = [];
  window.__setAccount = (a) => { account = a; emit('accountsChanged', [a]); };   // simulate the user switching accounts
  window.ethereum = {
    isMetaMask: true,
    async request({ method, params }) {
      window.__walletLog.push(method);
      switch (method) {
        case 'eth_requestAccounts': case 'eth_accounts': return [account];
        case 'eth_chainId': return chainId;
        case 'net_version': return String(parseInt(chainId, 16));
        case 'wallet_switchEthereumChain': chainId = params[0].chainId; setTimeout(() => emit('chainChanged', chainId), 0); return null;
        case 'wallet_addEthereumChain': return null;
        case 'eth_sendTransaction': params[0].from = account; return rpc(method, params);
        default: return rpc(method, params);
      }
    },
    on(ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); },
    removeListener(ev, fn) { listeners[ev] = (listeners[ev] || []).filter(f => f !== fn); },
  };
})();
"""


# ------------------------------------------------------------------------------------------------ flows


def run(browser) -> None:
    ctx = browser.new_context(viewport={"width": 1440, "height": 1000})
    ctx.add_init_script("localStorage.setItem('wc.theme', 'light')")
    page = ctx.new_page()
    ui = UI(page, "main")

    # 1 ---------------------------------------------------------------- market list
    print("[1] market list")
    ui.goto("#/")
    page.wait_for_selector("[data-testid=market-card-9]", timeout=20000)
    check(page.locator("[data-testid^=market-card-]").count() == 9, "market list shows the 9 seeded markets")
    check(ui.text("tile-markets") == "9", "stat tile counts 9 markets")
    check("%" in page.get_by_test_id("market-card-1").inner_text(), "market cards show live odds")
    ui.switch_account("Bob")
    check(ui.text("current-account") == "Bob", "local demo wallet switched to Bob")
    ui.shot("01_markets")

    # 2 ---------------------------------------------------------------- buy with preview
    print("[2] buy with price-impact preview")
    ui.goto("#/market/1")
    page.wait_for_selector("[data-testid=prob-chart] path[data-series]")
    check(page.locator("[data-testid=prob-chart] path[data-series]").count() == 2, "probability chart draws one line per outcome")
    p_before = ui.text("prob-0")
    pos_before = ui.num("pos-0") if page.get_by_test_id("pos-0").count() else 0.0
    page.get_by_test_id("pick-0").click()
    page.get_by_test_id("trade-amount").fill("250")
    page.wait_for_function("() => document.querySelector('[data-testid=quote-shares]')")
    impact = ui.text("quote-impact")
    check("%" in impact and ui.num("quote-shares") > 250, f"buy quote shows shares ({ui.text('quote-shares')}) and price impact ({impact})")
    ui.shot("02_trade_quote", full=False)
    ui.clear_toasts()
    page.get_by_test_id("trade-submit").click()
    ui.wait_tx("Buy Yes")
    p_after = ui.wait_text_change("prob-0", p_before)
    check(parse_num(p_after) > parse_num(p_before), f"buying Yes raised its probability {p_before} -> {p_after}")
    page.wait_for_function("([b]) => { const e = document.querySelector('[data-testid=pos-0]'); return e && parseFloat(e.textContent.replace(/,/g,'')) > b; }", arg=[pos_before])
    check(ui.num("pos-0") > pos_before, "position panel shows the new Yes shares")
    ui.shot("03_after_buy")

    # 3 ---------------------------------------------------------------- sell
    print("[3] sell")
    held = ui.num("pos-0")
    page.get_by_test_id("mode-sell").click()
    page.get_by_test_id("trade-amount").fill("100")
    page.wait_for_function("() => document.querySelector('[data-testid=quote-out]')")
    check(ui.num("quote-out") > 0, f"sell quote shows collateral out ({ui.text('quote-out')})")
    ui.clear_toasts()
    page.get_by_test_id("trade-submit").click()
    ui.wait_tx("Sell Yes")
    page.wait_for_function("([h]) => parseFloat(document.querySelector('[data-testid=pos-0]')?.textContent.replace(/,/g,'')) < h - 99", arg=[held])
    check(abs(ui.num("pos-0") - (held - 100)) < 0.02, "selling 100 shares reduced the position by exactly 100")

    # 4 ---------------------------------------------------------------- P2P order book
    print("[4] peer-to-peer order book")
    page.get_by_test_id("tab-book").click()
    page.get_by_test_id("book-outcome-0").click()
    page.locator("#ord-side button[data-side='1']").click()
    page.get_by_test_id("order-price").fill("0.45")
    page.get_by_test_id("order-amount").fill("50")
    ui.clear_toasts()
    page.get_by_test_id("order-submit").click()
    ui.wait_tx("Place sell order")
    page.wait_for_selector("[data-testid^=my-order-]")
    first = page.locator("[data-testid^=my-order-]").first
    order_id = int(first.get_attribute("data-testid").split("-")[-1])
    check("open" in first.inner_text(), f"ask #{order_id} (50 Yes @ 0.45) is escrowed and open")
    ui.switch_account("Frank")
    page.get_by_test_id("tab-book").click()
    page.get_by_test_id("book-outcome-0").click()
    page.get_by_test_id(f"take-{order_id}").click()
    page.get_by_test_id("fill-amount").fill("20")
    ui.clear_toasts()
    page.get_by_test_id("fill-submit").click()
    ui.wait_tx(f"Fill order #{order_id}")
    page.wait_for_function("id => document.querySelector(`[data-testid=order-row-${id}]`)?.textContent.includes('30')", arg=order_id)
    check(True, f"Frank partially filled 20 of order #{order_id}; 30 remain in the book")
    ui.switch_account("Bob")
    page.get_by_test_id("tab-book").click()
    page.wait_for_function("id => document.querySelector(`[data-testid=my-order-${id}]`)?.textContent.includes('partially')", arg=order_id)
    ui.shot("04_orderbook")
    ui.clear_toasts()
    page.get_by_test_id(f"cancel-{order_id}").click()
    ui.wait_tx(f"Cancel order #{order_id}")
    page.wait_for_function("id => document.querySelector(`[data-testid=my-order-${id}]`)?.textContent.includes('cancelled')", arg=order_id)
    check(True, f"Bob cancelled the remainder of order #{order_id} (escrow refunded)")

    # 5 ---------------------------------------------------------------- decoded custom error
    print("[5] decoded custom-error revert")
    page.locator("#ord-side button[data-side='1']").click()
    page.get_by_test_id("order-price").fill("0.46")
    page.get_by_test_id("order-amount").fill("10")
    ui.clear_toasts()
    page.get_by_test_id("order-submit").click()
    ui.wait_tx("Place sell order")
    page.wait_for_selector("[data-testid^=my-order-]")
    stale_id = int(page.locator("[data-testid^=my-order-]").first.get_attribute("data-testid").split("-")[-1])
    page2 = ctx.new_page()
    ui2 = UI(page2, "second")
    ui2.goto("#/market/1")
    ui2.switch_account("Frank")
    page2.get_by_test_id("tab-book").click()
    page2.get_by_test_id("book-outcome-0").click()
    page2.get_by_test_id(f"take-{stale_id}").click()  # Frank opens the fill form ...
    ui.clear_toasts()
    page.get_by_test_id(f"cancel-{stale_id}").click()  # ... while Bob cancels the order in the other tab
    ui.wait_tx(f"Cancel order #{stale_id}")
    ui2.clear_toasts()
    page2.get_by_test_id("fill-submit").click()
    err = ui2.wait_error_toast()
    check("no longer open" in err, f"stale fill reverted with a decoded custom error: “{err.strip()[:90]}”")
    ui2.shot("05_decoded_error", full=False)
    page2.close()

    # 6 ---------------------------------------------------------------- new user creates a market
    print("[6] faucet + create market")
    ui.switch_account("Judy")
    ui.goto("#/wallet")
    ui.clear_toasts()
    page.get_by_test_id("faucet-USDT").click()
    ui.wait_tx("Faucet: 10,000 USDT")
    page.wait_for_function("() => document.querySelector('[data-testid=wallet-bal-USDT]')?.textContent.startsWith('10,000')")
    check(True, "Judy received 10,000 USDT (6 decimals) from the faucet")
    ui.goto("#/create")
    page.get_by_test_id("create-question").fill("Who will win the SC4053 demo-day popular vote?")
    page.get_by_test_id("create-outcome-0").fill("Team Red")
    page.get_by_test_id("create-outcome-1").fill("Team Blue")
    page.get_by_test_id("create-add-outcome").click()
    page.get_by_test_id("create-outcome-2").fill("Team Green")
    page.get_by_test_id("create-token-USDT").click()
    page.get_by_test_id("create-liquidity").fill("500")
    page.wait_for_function("() => !document.querySelector('[data-testid=create-submit]').disabled")
    ui.clear_toasts()
    page.get_by_test_id("create-submit").click()
    ui.wait_tx("Create market", timeout=60000)
    page.wait_for_url(re.compile(r".*#/market/10$"), timeout=20000)
    page.wait_for_function("() => document.querySelector('[data-testid=market-question]')?.textContent.includes('demo-day')")
    check(page.locator("[data-testid^=outcome-row-]").count() == 3, "new 3-outcome market #10 opened after approve + create")
    ui.shot("06_created_market")

    # 7 ---------------------------------------------------------------- WETH market (18 decimals)
    print("[7] multi-collateral: WETH market")
    ui.goto("#/wallet")
    page.get_by_test_id("wrap-amount").fill("2")
    ui.clear_toasts()
    page.get_by_test_id("wrap-button").click()
    ui.wait_tx("Wrap 2.0 ETH")
    page.wait_for_function("() => document.querySelector('[data-testid=wallet-bal-WETH]')?.textContent.startsWith('2')")
    check(True, "Judy wrapped 2 ETH into WETH")
    ui.goto("#/market/3")
    page.get_by_test_id("pick-0").click()
    page.get_by_test_id("trade-amount").fill("0.25")
    page.wait_for_function("() => document.querySelector('[data-testid=quote-shares]')")
    ui.clear_toasts()
    page.get_by_test_id("trade-submit").click()
    ui.wait_tx("Buy Yes")
    page.wait_for_selector("[data-testid=pos-0]")
    weth_shares = ui.text("pos-0")
    check(re.match(r"^0\.\d{4}", weth_shares) is not None, f"WETH position shown with 18-dp precision ({weth_shares.split()[0]} shares)")
    ui.shot("07_weth_trade")
    ui.goto("#/create")
    page.get_by_test_id("create-question").fill("Will the SC4053 final exam be held in the Sports Hall?")
    page.get_by_test_id("create-token-WETH").click()
    page.get_by_test_id("create-liquidity").fill("0.5")
    page.get_by_test_id("create-mode-oracle").check()
    page.get_by_test_id("create-odds-toggle").check()
    page.get_by_test_id("create-odd-0").fill("70")
    page.get_by_test_id("create-odd-1").fill("30")
    page.wait_for_function("() => !document.querySelector('[data-testid=create-submit]').disabled")
    ui.clear_toasts()
    page.get_by_test_id("create-submit").click()
    ui.wait_tx("Create market", timeout=60000)
    page.wait_for_url(re.compile(r".*#/market/11$"), timeout=20000)
    page.wait_for_function("() => document.querySelector('[data-testid=prob-0]')?.textContent.startsWith('70')")
    check("reputation-weighted" in page.locator("#meta").inner_text(), "WETH market #11 is resolved by reputation vote and opened at the chosen 70% odds")
    ui.shot("07b_weth_vote_market")

    # 8 ---------------------------------------------------------------- liquidity
    print("[8] add / remove liquidity")
    ui.goto("#/market/1")
    page.get_by_test_id("tab-liquidity").click()
    page.get_by_test_id("add-liquidity-amount").fill("200")
    ui.clear_toasts()
    page.get_by_test_id("add-liquidity-submit").click()
    ui.wait_tx("Add liquidity")
    page.wait_for_function("() => parseFloat(document.querySelector('[data-testid=my-lp-shares]')?.textContent.replace(/,/g,'')) > 0")
    lp = ui.text("my-lp-shares")
    check(parse_num(lp) > 0, f"Judy received {lp} LP shares")
    page.locator("#liquidity [data-rm='100']").click()
    ui.clear_toasts()
    page.get_by_test_id("remove-liquidity-submit").click()
    ui.wait_tx("Remove liquidity")
    page.wait_for_function("() => parseFloat(document.querySelector('[data-testid=my-lp-shares]')?.textContent.replace(/,/g,'')) === 0")
    check(True, "Judy withdrew all liquidity (LP shares back to 0)")
    no_before = ui.num("pos-1") if page.get_by_test_id("pos-1").count() else 0.0
    page.get_by_test_id("set-amount").fill("5")
    ui.clear_toasts()
    page.get_by_test_id("split-submit").click()
    ui.wait_tx("Mint complete sets")
    page.wait_for_function("([b]) => parseFloat(document.querySelector('[data-testid=pos-1]')?.textContent.replace(/,/g,'')) >= b + 5 - 1e-6", arg=[no_before])
    ui.clear_toasts()
    page.get_by_test_id("merge-submit").click()
    ui.wait_tx("Merge complete sets")
    page.wait_for_function("([b]) => { const e = document.querySelector('[data-testid=pos-1]'); const v = e ? parseFloat(e.textContent.replace(/,/g,'')) : 0; return Math.abs(v - b) < 0.01; }", arg=[no_before])
    check(True, "minted 5 complete sets (1 USDT -> 1 Yes + 1 No) and merged them back")

    # 9 ---------------------------------------------------------------- arbitrator reports, winner redeems
    print("[9] arbitrator report + redeem")
    ui.switch_account("Dave")
    ui.goto("#/market/5")
    page.get_by_test_id("report-0").click()
    ui.clear_toasts()
    page.get_by_test_id("report-submit").click()
    ui.wait_tx("Report")
    page.wait_for_function("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Resolved')")
    check("Yes" in ui.text("phase-badge"), "arbitrator Dave resolved the quiz market to Yes")
    ui.switch_account("Bob")
    page.wait_for_selector("[data-testid=redeem-button]")
    payout = ui.text("redeem-button")
    ui.clear_toasts()
    page.get_by_test_id("redeem-button").click()
    ui.wait_tx("Redeem winnings")
    page.wait_for_selector("[data-testid=redeem-button]", state="detached")
    check(True, f"Bob redeemed his winning shares ({payout})")
    ui.shot("08_reported")
    ui.switch_account("Carol")
    ui.goto("#/market/6")
    page.wait_for_selector("[data-testid=redeem-button]")
    ui.clear_toasts()
    page.get_by_test_id("redeem-button").click()
    ui.wait_tx("Redeem winnings")
    check(True, "Carol redeemed her Team Beta winnings in the DAI hackathon market")

    # 10 --------------------------------------------------------------- arbitrator timeout -> invalid
    print("[10] arbitrator timeout -> invalid")
    ui.switch_account("Bob")
    ui.goto("#/market/8")
    ui.clear_toasts()
    page.get_by_test_id("timeout-button").click()
    ui.wait_tx("Resolve as invalid")
    page.wait_for_function("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Invalid')")
    check(True, "market with an absent arbitrator resolved INVALID after the 7-day timeout")
    page.wait_for_selector("[data-testid=redeem-button]")
    ui.clear_toasts()
    page.get_by_test_id("redeem-button").click()
    ui.wait_tx("Redeem pro-rata refund")
    check(True, "Bob got his pro-rata (1/N per share) refund")
    ui.shot("09_invalid")

    # 11 --------------------------------------------------------------- reputation-weighted voting
    print("[11] reputation-weighted vote")
    ui.goto("#/reporters")
    page.wait_for_selector("[data-testid=rep-Frank]")
    page.wait_for_selector("[data-testid=rep-Heidi]")
    rep_frank = int(ui.num("rep-Frank"))
    rep_heidi = int(ui.num("rep-Heidi"))
    ui.goto("#/market/4")
    for who, testid in (("Frank", "vote-0"), ("Grace", "vote-0"), ("Heidi", "vote-1")):
        ui.switch_account(who)
        page.wait_for_selector(f"[data-testid={testid}]")
        ui.clear_toasts()
        page.get_by_test_id(testid).click()
        ui.wait_tx("Vote")
    page.wait_for_function("() => document.querySelectorAll('#resolution tbody tr').length === 4")
    check(True, "Frank, Grace (Yes) and Heidi (No) voted; tally weighted by reputation")
    ui.shot("10_vote")
    page.get_by_test_id("devtools-toggle").click()
    t0 = ui.text("devtools-time")
    ui.clear_toasts()
    page.get_by_test_id("ff-1d").click()
    page.wait_for_function("() => [...document.querySelectorAll('.toast')].some(t => t.textContent.includes('Time travel'))")
    ui.wait_text_change("devtools-time", t0)
    check(True, f"dev tools fast-forwarded chain time by 1 day ({t0} -> {ui.text('devtools-time')})")
    page.get_by_test_id("devtools-toggle").click()
    page.wait_for_selector("[data-testid=finalize-button]", timeout=20000)
    ui.clear_toasts()
    page.get_by_test_id("finalize-button").click()
    ui.wait_tx("Finalize vote")
    page.wait_for_function("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Resolved')")
    check("Yes" in ui.text("phase-badge"), "finalize reported the reputation-weighted consensus (Yes) to the market")
    ui.goto("#/reporters")
    page.wait_for_function("r => parseInt(document.querySelector('[data-testid=rep-Frank]')?.textContent) === r + 10", arg=rep_frank)
    check(int(ui.num("rep-Frank")) == rep_frank + 10, f"Frank's reputation rose {rep_frank} -> {rep_frank + 10}")
    expected_heidi = rep_heidi - (rep_heidi * 2000 + 9999) // 10000
    check(int(ui.num("rep-Heidi")) == expected_heidi, f"Heidi (voted against consensus) was slashed {rep_heidi} -> {expected_heidi}")
    ui.switch_account("Alice")
    page.wait_for_selector("[data-testid=reporter-address]")
    page.get_by_test_id("reporter-address").fill("0xa0Ee7A142d267C1f36714E4a8F75612F20a79720")
    ui.clear_toasts()
    page.get_by_test_id("reporter-register").click()
    ui.wait_tx("Register Judy")
    page.wait_for_selector("[data-testid=rep-Judy]")
    check(int(ui.num("rep-Judy")) == 100, "admin (Alice) registered Judy as a reporter with 100 reputation")
    ui.shot("11_reporters")

    # 13 --------------------------------------------------------------- portfolio, dark theme, mobile
    print("[13] portfolio / dark / mobile")
    ui.goto("#/portfolio")
    page.wait_for_selector("[data-testid^=portfolio-claim-]")
    ui.clear_toasts()
    page.locator("[data-testid^=portfolio-claim-]").first.click()
    ui.wait_tx("Claim fees")
    check(True, "LP Alice claimed trading fees from the portfolio page")
    ui.switch_account("Bob")
    page.wait_for_selector("[data-testid^=position-]")
    check(page.locator("[data-testid^=position-]").count() > 0, "portfolio lists Bob's positions across markets")
    ui.shot("13_portfolio")
    page.evaluate("document.documentElement.setAttribute('data-theme','dark')")
    ui.goto("#/market/2")
    page.evaluate("document.documentElement.setAttribute('data-theme','dark')")
    page.wait_for_selector("[data-testid=prob-chart] path[data-series]")
    ui.shot("14_dark_market", full=False)
    page.evaluate("document.documentElement.setAttribute('data-theme','light')")
    mobile = browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2)
    mobile.add_init_script("localStorage.setItem('wc.theme', 'light')")
    mp = mobile.new_page()
    mui = UI(mp, "mobile")
    mui.goto("#/market/1")
    mp.wait_for_selector("[data-testid=prob-chart] path[data-series]")
    overflow = mp.evaluate("() => document.documentElement.scrollWidth - window.innerWidth")
    check(overflow <= 1, f"phone-width layout has no horizontal scroll (overflow {overflow}px)")
    mui.shot("15_mobile_market", full=False)
    mobile.close()
    errors = ui.errors
    check(not errors, f"no JavaScript errors in the main tab ({len(errors)})" + (f": {errors[:3]}" if errors else ""))
    ctx.close()

    # 12 --------------------------------------------------------------- injected (MetaMask-style) wallet
    print("[12] injected EIP-1193 wallet")
    ictx = browser.new_context(viewport={"width": 1440, "height": 1000})
    ictx.add_init_script(INJECTED_WALLET.replace("%RPC%", RPC).replace("%ACCOUNT%", IVAN))
    ictx.add_init_script("localStorage.setItem('wc.theme', 'light')")
    ip = ictx.new_page()
    iui = UI(ip, "injected")
    iui.goto("#/wallet")
    ip.get_by_test_id("wallet-button").click()
    ip.get_by_test_id("mode-injected").click()
    ip.get_by_test_id("connect-injected").click()
    ip.wait_for_function("() => document.querySelector('[data-testid=current-account]')?.textContent === 'Ivan'")
    log = ip.evaluate("window.__walletLog")
    check("eth_requestAccounts" in log and "wallet_switchEthereumChain" in log, "browser wallet connected (eth_requestAccounts) and was asked to switch to chain 31337")
    iui.clear_toasts()
    ip.get_by_test_id("faucet-DAI").click()
    iui.wait_tx("Faucet: 10,000 DAI")
    check("eth_sendTransaction" in ip.evaluate("window.__walletLog"), "transaction was signed/sent through the injected EIP-1193 provider")
    iui.shot("12_injected_wallet", full=False)
    ip.evaluate("window.__setAccount('0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC')")
    ip.wait_for_function("() => document.querySelector('[data-testid=current-account]')?.textContent === 'Carol'")
    check(True, "the app followed an accountsChanged event from the wallet (Ivan -> Carol)")
    check(not iui.errors, "no JavaScript errors in injected-wallet mode")
    ictx.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="WiseCrowd end-to-end smoke test")
    ap.add_argument("--no-start", action="store_true", help="use an already running ./run.sh")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()
    os.makedirs(SHOTS, exist_ok=True)
    proc = None
    t0 = time.time()
    try:
        if not args.no_start:
            print("starting ./run.sh …")
            proc = start_stack()
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=not args.headed)
            try:
                run(browser)
            finally:
                browser.close()
    except Exception as e:
        traceback.print_exc()
        print(f"\nE2E FAILED after {len(PASSED)} passing checks: {e}")
        return 1
    finally:
        stop_stack(proc)
    print(f"\nE2E PASSED: {len(PASSED)} checks in {time.time() - t0:.0f}s; screenshots in e2e/screenshots/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
