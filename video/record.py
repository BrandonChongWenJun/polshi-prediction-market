#!/usr/bin/env python3
"""Record the narrated walkthrough.

Starts a fresh ./run.sh in WSL, loads studio.html (slides, terminal replay, caption band, cursor) with the dApp in an
iframe, drives the real UI in headless Microsoft Edge in step with the narration clips from tts.py, and captures
frames with the Chrome DevTools screencast. assemble.py turns build/frames + build/timeline.json into the video.

  python video/record.py           # full recording (about 8 minutes)
  python video/record.py --fast    # rehearsal: same UI flow, narration pauses cut to 15%, no frames saved
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import threading
import time

from playwright.async_api import Frame, Locator, Page, async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
sys.path.insert(0, HERE)
from narration import LINES, SECTION_OF  # noqa: E402

WEB = "http://127.0.0.1:5554/"
DISTRO = os.environ.get("WSL_DISTRO", "Ubuntu-22.04")
W, H = 1920, 1080   # recorded frame size
S = 1.25            # studio.html lays out at 1536x864 and is scaled by S
STAGE_H = 768       # height of the app area in studio pixels
GAP = 0.35
JUDY = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"


def wsl_path(p: str) -> str:
    drive, rest = os.path.splitdrive(os.path.abspath(p))
    return f"/mnt/{drive[0].lower()}{rest.replace(os.sep, '/')}"


# ------------------------------------------------------------------------------------------------ local chain


def wsl(script: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(["wsl", "-d", DISTRO, "-e", "bash", "-lc", script], **kw)


def stop_stack() -> None:
    wsl("pkill -INT -f '[r]un.sh'; sleep 3; pkill -9 -f '[a]nvil --port 8554'; pkill -9 -f '[h]ttp.server 5554'; true",
        capture_output=True)


def start_stack() -> tuple[subprocess.Popen, list]:
    stop_stack()
    script = f'export PATH="$HOME/.foundry/bin:$PATH"; cd "{wsl_path(ROOT)}" && exec ./run.sh'
    proc = subprocess.Popen(["wsl", "-d", DISTRO, "-e", "bash", "-lc", script], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    lines, t0 = [], time.time()
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip("\n")
        lines.append([round(time.time() - t0, 2), line])
        print("  [run.sh]", line)
        if line.startswith("READY"):
            break
    else:
        raise RuntimeError("run.sh exited before it was ready")
    threading.Thread(target=lambda: [None for _ in proc.stdout], daemon=True).start()
    return proc, lines


# ------------------------------------------------------------------------------------------------ screencast


class Recorder:
    def __init__(self, page: Page, outdir: str):
        self.page, self.dir = page, outdir
        self.frames: list[list] = []
        self.cdp = None

    async def start(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.cdp = await self.page.context.new_cdp_session(self.page)
        self.cdp.on("Page.screencastFrame", self._frame)
        await self.cdp.send("Page.startScreencast", {"format": "jpeg", "quality": 92, "maxWidth": 1920, "maxHeight": 1080})

    def _frame(self, p: dict) -> None:
        name = f"{len(self.frames) + 1:06d}.jpg"
        with open(os.path.join(self.dir, name), "wb") as f:
            f.write(base64.b64decode(p["data"]))
        self.frames.append([p["metadata"].get("timestamp") or time.time(), time.time(), name])
        asyncio.ensure_future(self.cdp.send("Page.screencastFrameAck", {"sessionId": p["sessionId"]}))

    async def stop(self) -> None:
        await self.cdp.send("Page.stopScreencast")
        await asyncio.sleep(0.3)


# ------------------------------------------------------------------------------------------------ director


class Director:
    def __init__(self, page: Page, app: Frame, dur: dict, fast: bool):
        self.page, self.app, self.dur, self.fast = page, app, dur, fast
        self.scale = 0.15 if fast else 1.0
        self.free_at = 0.0
        self.marks: list[dict] = []
        self.chapters: list[dict] = []
        self.cur = (760.0, 420.0)

    async def js(self, expr: str, arg=None):
        return await self.page.evaluate(expr, arg)

    # narration ------------------------------------------------------------------------------
    async def until(self, t: float) -> None:
        if t > time.time():
            await asyncio.sleep(t - time.time())

    async def say(self, uid: str) -> None:
        """Start caption + narration clip `uid` once the previous clip has finished."""
        await self.until(self.free_at)
        d = self.dur[uid]["dur"] * self.scale
        await self.js("([t, ms]) => studio.caption(t, ms)", [LINES[uid], int(d * 1000) + 350])
        t = time.time()
        if not self.chapters or self.chapters[-1]["title"] != SECTION_OF[uid]:
            self.chapters.append({"title": SECTION_OF[uid], "t": t})
        self.marks.append({"id": uid, "t": t})
        self.free_at = t + d + GAP * self.scale
        print(f"  {uid} {LINES[uid][:80]}")

    async def finish(self, extra: float = 0.0) -> None:
        await self.until(self.free_at + extra * self.scale)

    async def pause(self, s: float) -> None:
        await asyncio.sleep(s * (0.4 if self.fast else 1.0))

    # pointer ---------------------------------------------------------------------------------
    async def move(self, x: float, y: float, ms: int | None = None) -> None:
        if ms is None:
            ms = int(min(850, max(300, math.hypot(x - self.cur[0], y - self.cur[1]) * 0.8)))
        t = time.time()
        await self.js("([x, y, ms]) => studio.cursorTo(x, y, ms)", [x, y, ms])
        await self.page.mouse.move(x * S, y * S, steps=max(2, ms // 45))
        self.cur = (x, y)
        await asyncio.sleep(max(0.0, ms / 1000 - (time.time() - t)))

    async def box(self, loc: Locator) -> dict | None:
        """Element box in studio pixels (Playwright reports page pixels)."""
        b = await loc.bounding_box()
        return {k: v / S for k, v in b.items()} if b else None

    async def visible(self, loc: Locator) -> dict:
        await loc.wait_for(state="visible", timeout=30000)
        fixed = await loc.evaluate("e => !!e.closest('.topbar, #devtools, .toasts')")
        box = await self.box(loc)
        if not fixed and (box is None or box["y"] < 72 or box["y"] + box["height"] > STAGE_H - 96):
            await self.js("studio.clearSpots()")
            await loc.evaluate("e => e.scrollIntoView({behavior: 'smooth', block: 'center'})")
            await asyncio.sleep(0.85)
            box = await self.box(loc)
        return box

    async def click(self, loc: Locator, check: bool = False) -> None:
        box = await self.visible(loc)
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        await self.move(x, y)
        await asyncio.sleep(0.08)
        await self.js("([x, y]) => studio.ripple(x, y)", [x, y])
        if check:
            await loc.check()
        else:
            await loc.click()
        await asyncio.sleep(0.15)

    async def type(self, loc: Locator, text: str, delay: int = 45) -> None:
        await self.click(loc)
        await loc.fill("")
        await loc.press_sequentially(text, delay=delay)
        await asyncio.sleep(0.2)

    async def spot(self, loc: Locator, secs: float = 2.4, pad: int = 6) -> None:
        box = await self.visible(loc)
        await self.js("([r, ms, pad]) => studio.spot(r, ms, pad)", [box, int(secs * 1000), pad])

    async def scroll_to(self, y: int) -> None:
        await self.js("studio.clearSpots()")
        await self.app.evaluate("y => window.scrollTo({top: y, behavior: 'smooth'})", y)
        await asyncio.sleep(0.9)

    # app actions -------------------------------------------------------------------------------
    def tid(self, testid: str) -> Locator:
        return self.app.get_by_test_id(testid)

    async def tx(self, label: str, button: Locator, timeout: int = 90) -> None:
        """Click a button that sends a transaction and wait for its confirmed toast (fail on an error toast)."""
        await self.app.evaluate("() => document.querySelectorAll('.toast').forEach(t => t.dataset.seen = '1')")
        await self.click(button)
        await self.app.wait_for_function(
            """(label) => [...document.querySelectorAll('.toast:not([data-seen])')].some(t =>
                 t.dataset.kind === 'error' || (t.dataset.kind === 'success' && t.textContent.includes(label)))""",
            arg=label, timeout=timeout * 1000)
        err = await self.app.evaluate(
            "() => [...document.querySelectorAll('.toast:not([data-seen])')].filter(t => t.dataset.kind === 'error').map(t => t.textContent).join(' | ')")
        if err:
            raise RuntimeError(f"transaction '{label}' failed: {err}")
        await asyncio.sleep(0.6)

    async def account(self, name: str) -> None:
        if (await self.tid("current-account").inner_text()).strip() == name:
            return
        await self.click(self.tid("wallet-button"))
        item = self.tid(f"account-{name}")
        if not await item.is_visible():
            await self.click(self.tid("mode-local"))
        await self.click(item)
        await self.app.wait_for_function(
            "n => document.querySelector('[data-testid=current-account]')?.textContent.trim() === n", arg=name, timeout=15000)
        await asyncio.sleep(1.0)

    async def nav(self, route: str) -> None:
        await self.click(self.app.locator(f"#nav a[data-route={route}]"))
        await self.app.wait_for_selector("#app .loading", state="detached", timeout=30000)
        await asyncio.sleep(0.7)

    async def open_market(self, n: int) -> None:
        await self.nav("markets")
        await self.click(self.tid(f"market-card-{n}").locator(".mc-q"))
        await self.app.wait_for_selector("[data-testid=prob-chart] path[data-series]", state="attached", timeout=30000)
        await asyncio.sleep(0.6)

    async def wait_js(self, js: str, arg=None, timeout: int = 30000) -> None:
        await self.app.wait_for_function(js, arg=arg, timeout=timeout)


# ------------------------------------------------------------------------------------------------ scenes


async def scene_architecture(d: Director) -> None:
    await d.js("() => { studio.layer('slides'); studio.slide('s-arch'); }")
    await d.pause(0.6)
    await d.say("a01")
    await d.say("a02"); await d.js("studio.focus('client')")
    await d.say("a03"); await d.js("studio.focus('chain')")
    await d.say("a04"); await d.js("studio.focus('pm')")
    await d.say("a05"); await d.js("studio.focus('ob')")
    await d.say("a06"); await d.js("studio.focus('ro')")
    await d.say("a07"); await d.js("studio.focus('tok')")
    await d.finish()
    await d.js("studio.slide('s-design')")
    await d.pause(0.5)
    await d.say("a08"); await d.js("studio.focus('sets')")
    await d.say("a09")
    await d.say("a10"); await d.js("studio.focus('fpmm')")
    await d.finish()
    await d.js("studio.slide('s-life')")
    await d.pause(0.5)
    await d.say("a11"); await d.js("studio.focus('tl')")
    await d.say("a11b"); await d.js("studio.focus('t-close')")
    await d.say("a11c")
    await d.say("a12"); await d.js("studio.focus('paths')")


async def scene_deploy(d: Director, run_lines: list) -> None:
    await d.finish()
    await d.js("""() => { studio.layer('term');
        studio.term.reset('bash — option4-prediction-market', 'real output of this recording run, replayed (sped up)');
        studio.term.prompt('~/option4-prediction-market'); }""")
    await d.pause(0.7)
    await d.say("b01")
    for ch in "./run.sh":
        await d.js("c => studio.term.typeChar(c)", ch)
        await asyncio.sleep(0.07)
    await asyncio.sleep(0.3)
    await d.js("studio.term.enter()")
    lines = [l for _, l in run_lines]
    split = next(i for i, l in enumerate(lines) if "seeding" in l)
    for l in lines[:split]:
        await d.js("l => studio.term.add([l])", l)
        await asyncio.sleep(0.12 if l.startswith("      ") else 1.1)
    await d.say("b02")
    for l in lines[split:]:
        await d.js("l => studio.term.add([l])", l)
        await asyncio.sleep(0.9 if "[run]" in l or l.startswith("      seed") else 0.06)
    await d.finish(0.6)


async def scene_markets(d: Director) -> None:
    await d.app.evaluate("window.scrollTo(0, 0)")
    await d.js("() => { studio.layer('app'); studio.cursorShow(true); }")
    await d.pause(0.7)
    await d.say("c01")
    await d.move(700, 520)
    await d.spot(d.tid("market-grid").locator("[data-testid^=market-card-]").first, 2.6)
    await d.say("c02")
    await d.spot(d.app.locator("#tiles .tile").nth(1), 1.8)
    await d.pause(1.6)
    await d.scroll_to(430)
    await d.pause(1.4)
    await d.scroll_to(900)
    await d.say("c03")
    await d.scroll_to(0)
    await d.spot(d.app.locator("#chain-pill"), 3.0)
    await d.say("c04")
    await d.account("Bob")


async def scene_trading(d: Director) -> None:
    await d.say("d01")
    await d.open_market(1)
    await d.spot(d.app.locator("#meta"), 3.2)
    await d.say("d02")
    chart = d.tid("prob-chart")
    box = await d.visible(chart)
    y = box["y"] + box["height"] * 0.42
    for frac in (0.18, 0.42, 0.66, 0.88):
        await d.move(box["x"] + box["width"] * frac, y, 600)
        await asyncio.sleep(0.25)
    await d.click(d.app.locator("#table-toggle"))
    await d.pause(1.8)
    await d.click(d.app.locator("#table-toggle"))
    await d.say("d03")
    await d.click(d.tid("pick-0"))
    await d.type(d.tid("trade-amount"), "250", 110)
    await d.wait_js("() => document.querySelector('[data-testid=quote-shares]')")
    await d.say("d04")
    await d.spot(d.tid("trade-quote"), 6.5)
    await d.say("d05")
    await d.spot(d.app.locator("#slip"), 3.0)
    await d.say("d06")
    before = await d.tid("prob-0").inner_text()
    await d.tx("Buy Yes", d.tid("trade-submit"))
    await d.wait_js("old => document.querySelector('[data-testid=prob-0]')?.textContent !== old", before)
    await d.spot(d.tid("outcome-row-0"), 2.2)
    await d.pause(1.0)
    await d.spot(d.tid("position-panel"), 2.4)
    await d.pause(1.2)
    await d.say("d07")
    await d.click(d.tid("mode-sell"))
    await d.type(d.tid("trade-amount"), "100", 110)
    await d.wait_js("() => document.querySelector('[data-testid=quote-out]')")
    await d.spot(d.tid("trade-quote"), 2.0)
    await d.pause(1.2)
    await d.tx("Sell Yes", d.tid("trade-submit"))


async def scene_orderbook(d: Director) -> None:
    await d.say("e01")
    await d.click(d.tid("tab-book"))
    await d.click(d.tid("book-outcome-0"))
    await d.click(d.app.locator("#ord-side button[data-side='1']"))
    await d.type(d.tid("order-price"), "0.45", 90)
    await d.type(d.tid("order-amount"), "50", 90)
    await d.say("e02")
    await d.tx("Place sell order", d.tid("order-submit"))
    mine = d.app.locator("[data-testid^=my-order-]").first
    await mine.wait_for()
    oid = int((await mine.get_attribute("data-testid")).split("-")[-1])
    await d.spot(mine, 2.6)
    await d.say("e03")
    await d.account("Frank")
    await d.click(d.tid("tab-book"))
    await d.click(d.tid("book-outcome-0"))
    await d.click(d.tid(f"take-{oid}"))
    await d.type(d.tid("fill-amount"), "20", 110)
    await d.tx(f"Fill order #{oid}", d.tid("fill-submit"))
    await d.wait_js("id => document.querySelector(`[data-testid=order-row-${id}]`)?.textContent.includes('30')", oid)
    await d.spot(d.tid(f"order-row-{oid}"), 2.4)
    await d.say("e04")
    await d.account("Bob")
    await d.click(d.tid("tab-book"))
    await d.wait_js("id => document.querySelector(`[data-testid=my-order-${id}]`)?.textContent.includes('partially')", oid)
    await d.spot(d.tid(f"my-order-{oid}"), 2.0)
    await d.tx(f"Cancel order #{oid}", d.tid(f"cancel-{oid}"))
    await d.wait_js("id => document.querySelector(`[data-testid=my-order-${id}]`)?.textContent.includes('cancelled')", oid)
    await d.say("e05")
    await d.spot(d.tid(f"my-order-{oid}"), 2.6)


async def scene_liquidity(d: Director) -> None:
    await d.say("f01")
    await d.click(d.tid("tab-liquidity"))
    await d.type(d.tid("add-liquidity-amount"), "200", 110)
    await d.tx("Add liquidity", d.tid("add-liquidity-submit"))
    await d.wait_js("() => parseFloat(document.querySelector('[data-testid=my-lp-shares]')?.textContent.replace(/,/g,'')) > 0")
    await d.spot(d.app.locator("#my-lp"), 2.4)
    await d.say("f02")
    await d.click(d.app.locator("#liquidity [data-rm='100']"))
    await d.tx("Remove liquidity", d.tid("remove-liquidity-submit"))
    await d.wait_js("() => parseFloat(document.querySelector('[data-testid=my-lp-shares]')?.textContent.replace(/,/g,'')) === 0")
    await d.spot(d.app.locator("#my-lp"), 2.0)
    await d.say("f03")
    await d.type(d.tid("set-amount"), "5", 110)
    await d.tx("Mint complete sets", d.tid("split-submit"))
    await d.say("f04")
    await d.tx("Merge complete sets", d.tid("merge-submit"))


async def scene_arbitrator(d: Director) -> None:
    await d.say("g01")
    await d.open_market(5)
    await d.spot(d.tid("resolution-panel"), 3.0)
    await d.say("g02")
    await d.account("Dave")
    await d.click(d.tid("report-0"))
    await d.tx("Report", d.tid("report-submit"))
    await d.wait_js("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Resolved')")
    await d.say("g03")
    await d.spot(d.tid("phase-badge"), 2.0)
    await d.account("Bob")
    await d.tx("Redeem winnings", d.tid("redeem-button"))


async def scene_vote(d: Director) -> None:
    await d.say("h01")
    await d.open_market(4)
    await d.spot(d.tid("resolution-panel"), 3.0)
    await d.say("h02")
    await d.spot(d.app.locator("#resolution .quorum"), 3.6, 10)
    await d.say("h03")
    await d.account("Frank")
    await d.tx("Vote", d.tid("vote-0"))
    await d.say("h04")
    await d.account("Heidi")
    await d.tx("Vote", d.tid("vote-1"))
    await d.spot(d.app.locator("#resolution tbody"), 2.2)
    await d.say("h05")
    await d.click(d.tid("devtools-toggle"))
    t0 = await d.tid("devtools-time").inner_text()
    await d.app.evaluate("() => document.querySelectorAll('.toast').forEach(t => t.dataset.seen = '1')")
    await d.click(d.tid("ff-1d"))
    await d.wait_js("() => [...document.querySelectorAll('.toast:not([data-seen])')].some(t => t.textContent.includes('Time travel'))")
    await d.wait_js("old => document.querySelector('[data-testid=devtools-time]')?.textContent !== old", t0)
    await d.pause(0.8)
    await d.click(d.tid("devtools-toggle"))
    await d.tx("Finalize vote", d.tid("finalize-button"))
    await d.wait_js("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Resolved')")
    await d.say("h06")
    await d.spot(d.tid("phase-badge"), 2.4)
    await d.say("h07")
    await d.nav("reporters")
    await d.spot(d.tid("reporter-Frank"), 2.6, 4)
    await d.pause(1.2)
    await d.spot(d.tid("reporter-Heidi"), 2.6, 4)
    await d.say("h08")
    await d.account("Alice")
    await d.type(d.tid("reporter-address"), JUDY, 18)
    await d.tx("Register Judy", d.tid("reporter-register"))
    await d.spot(d.tid("reporter-Judy"), 2.4, 4)


async def scene_timeout(d: Director) -> None:
    await d.say("i01")
    await d.account("Bob")
    await d.open_market(8)
    await d.tx("Resolve as invalid", d.tid("timeout-button"))
    await d.wait_js("() => document.querySelector('[data-testid=phase-badge]')?.textContent.includes('Invalid')")
    await d.say("i02")
    await d.spot(d.tid("phase-badge"), 2.0)
    await d.tx("Redeem pro-rata refund", d.tid("redeem-button"))


async def scene_create(d: Director) -> None:
    await d.say("j01")
    await d.account("Judy")
    await d.nav("wallet")
    await d.type(d.tid("wrap-amount"), "2", 110)
    await d.tx("Wrap 2.0 ETH", d.tid("wrap-button"))
    await d.spot(d.tid("wallet-bal-WETH"), 2.0)
    await d.say("j02")
    await d.nav("create")
    await d.type(d.tid("create-question"), "Which team will win the SC4053 demo day?", 32)
    await d.type(d.tid("create-outcome-0"), "Team Red", 40)
    await d.type(d.tid("create-outcome-1"), "Team Blue", 40)
    await d.click(d.tid("create-add-outcome"))
    await d.type(d.tid("create-outcome-2"), "Team Green", 40)
    await d.click(d.tid("create-odds-toggle"), check=True)
    for i, v in enumerate(("50", "30", "20")):
        await d.type(d.tid(f"create-odd-{i}"), v, 90)
    await d.say("j03")
    await d.click(d.tid("create-token-WETH"))
    await d.type(d.tid("create-liquidity"), "0.5", 110)
    await d.click(d.tid("create-mode-oracle"), check=True)
    await d.wait_js("() => !document.querySelector('[data-testid=create-submit]').disabled")
    await d.say("j04")
    await d.tx("Create market", d.tid("create-submit"), timeout=120)
    await d.app.wait_for_url("**/#/market/10", timeout=30000)
    await d.app.wait_for_selector("[data-testid=prob-chart] path[data-series]", state="attached", timeout=30000)
    await d.pause(0.6)
    await d.spot(d.tid("outcomes"), 3.0)


async def scene_portfolio(d: Director) -> None:
    await d.say("k01")
    await d.account("Alice")
    await d.nav("portfolio")
    claim = d.app.locator("[data-testid^=portfolio-claim-]").first
    await claim.wait_for(timeout=30000)
    await d.tx("Claim fees", claim)


async def scene_wrapup(d: Director, test_lines: list[str]) -> None:
    await d.finish(0.4)
    await d.js("""() => { studio.cursorShow(false); studio.layer('term');
        studio.term.reset('bash — contracts', 'real forge test output from this machine (summary lines)');
        studio.term.prompt('~/option4-prediction-market/contracts'); }""")
    await d.pause(0.6)
    await d.say("l01")
    for ch in "forge test":
        await d.js("c => studio.term.typeChar(c)", ch)
        await asyncio.sleep(0.07)
    await asyncio.sleep(0.3)
    await d.js("studio.term.enter()")
    for l in test_lines[:-1]:
        await d.js("l => studio.term.add([l])", l)
        await asyncio.sleep(0.16)
    await d.js("l => studio.term.add([l], 'hl')", test_lines[-1])
    await d.finish(0.5)
    await d.js("() => { studio.layer('slides'); studio.slide('s-end'); }")
    await d.pause(0.6)
    await d.say("l02")
    await d.finish(1.6)


# ------------------------------------------------------------------------------------------------ main


async def run(fast: bool) -> None:
    os.makedirs(BUILD, exist_ok=True)
    dur = json.load(open(os.path.join(BUILD, "tts", "durations.json")))
    missing = [u for u in LINES if u not in dur]
    if missing:
        raise SystemExit(f"narration clips missing for {missing}; run tts.py first")
    test_log = open(os.path.join(BUILD, "forge_test.log"), encoding="utf-8").read().splitlines()
    test_lines = [l for l in test_log if l.startswith("Ran ") and "for test/" in l] + [test_log[-1]]
    assert "180 tests passed" in test_lines[-1], test_lines[-1]

    proc, run_lines = start_stack()
    json.dump(run_lines, open(os.path.join(BUILD, "run_output.json"), "w"), indent=0)
    studio_html = open(os.path.join(HERE, "studio.html"), encoding="utf-8").read()
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(channel="msedge", headless=True)
            ctx = await browser.new_context(viewport={"width": W, "height": H})
            await ctx.add_init_script("try { localStorage.setItem('wc.theme', 'light') } catch (e) {}")
            page = await ctx.new_page()

            async def serve_studio(route):
                await route.fulfill(status=200, content_type="text/html; charset=utf-8", body=studio_html)

            await page.route(WEB + "__studio.html", serve_studio)
            await page.goto(WEB + "__studio.html")
            await page.evaluate("document.getElementById('appframe').src = '/#/'")
            app = None
            for _ in range(200):
                app = page.frame(name="app")
                if app and app.url.startswith(WEB):
                    break
                await asyncio.sleep(0.1)
            await app.wait_for_selector("[data-testid=market-card-9]", timeout=60000)
            await asyncio.sleep(1.5)

            d = Director(page, app, dur, fast)
            rec = Recorder(page, os.path.join(BUILD, "frames"))
            if not fast:
                await rec.start()
            await asyncio.sleep(0.4)
            started = time.time()
            try:
                await scene_architecture(d)
                await scene_deploy(d, run_lines)
                await scene_markets(d)
                await scene_trading(d)
                await scene_orderbook(d)
                await scene_liquidity(d)
                await scene_arbitrator(d)
                await scene_vote(d)
                await scene_timeout(d)
                await scene_create(d)
                await scene_portfolio(d)
                await scene_wrapup(d, test_lines)
            except Exception:
                await page.screenshot(path=os.path.join(BUILD, "error.png"))
                print("  !! failed after", d.marks[-1]["id"] if d.marks else "start", "- screenshot in build/error.png")
                raise
            end = time.time()
            if not fast:
                await rec.stop()
                recv_lag = statistics.median(r - t for t, r, _ in rec.frames)
                json.dump({"start": started, "end": end, "recv_lag": recv_lag, "frames": rec.frames,
                           "marks": d.marks, "chapters": d.chapters},
                          open(os.path.join(BUILD, "timeline.json"), "w"))
                print(f"recorded {len(rec.frames)} frames over {end - started:.1f}s (median frame lag {recv_lag * 1000:.0f} ms)")
            else:
                print(f"rehearsal OK in {end - started:.1f}s")
            await browser.close()
    finally:
        stop_stack()
        proc.kill()


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--fast", action="store_true", help="rehearse the flow quickly without saving frames")
    args = ap.parse_args()
    asyncio.run(run(args.fast))


if __name__ == "__main__":
    main()
