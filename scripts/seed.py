#!/usr/bin/env python3
"""Seed realistic demo state into a freshly deployed local chain (anvil started with --timestamp in the past).

Creates nine markets across USDT (6 dp), DAI (18 dp) and WETH (18 dp) with a ~10-day trading history whose
prices drift along plausible paths (so the probability charts look real), an extra liquidity provider,
peer-to-peer orders (open, partially filled, cancelled), one arbitrator-resolved market with an unredeemed
winner, one market resolved by reputation-weighted voting, one market whose voting window is open right now,
one market waiting for its arbitrator and one whose arbitrator missed the deadline.

Block timestamps are set explicitly (evm_setNextBlockTimestamp) so the history is spread over the past days;
the chain clock ends at (roughly) the current wall-clock time.

Usage: seed.py --rpc http://127.0.0.1:8554 --deployment contracts/deployments/31337.json --end <unix time>
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time

from abi_lite import Rpc, RpcError, calldata, decode_uint, decode_uint_array

ACCOUNTS = [
    ("Alice", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
    ("Bob", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
    ("Carol", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"),
    ("Dave", "0x90F79bf6EB2c4f870365E785982E1f101E93b906"),
    ("Eve", "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"),
    ("Frank", "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"),
    ("Grace", "0x976EA74026E726554dB657fA54763abd0C3a0aa9"),
    ("Heidi", "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"),
    ("Ivan", "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f"),
    ("Judy", "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"),
]
A = dict(ACCOUNTS)
MIN, HOUR, DAY = 60, 3600, 86400
MAX = 2**256 - 1
INVALID = 255
BUY, SELL = 0, 1  # OrderBook.Side

CREATE_SIG = "createMarket((string,string,string[],uint64,uint64,address,address,uint256,uint16[],uint16))"


class Chain:
    """Sends transactions from anvil's unlocked accounts at explicit, monotonically increasing timestamps."""

    def __init__(self, rpc: Rpc, start: int):
        self.rpc = rpc
        latest = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        self.t = max(start, latest + 1)
        self.count = 0

    def at(self, ts: int) -> None:
        if ts > self.t:
            self.t = ts

    def send(self, who: str, to: str, sig: str, *args, value: int = 0) -> dict:
        self.rpc("evm_setNextBlockTimestamp", [self.t])
        tx = {"from": A[who], "to": to, "data": calldata(sig, *args)}
        if value:
            tx["value"] = hex(value)
        try:
            h = self.rpc("eth_sendTransaction", [tx])
        except RpcError as e:
            sys.exit(f"seed: transaction failed: {who} -> {sig} {args}\n  {e}")
        receipt = None
        for _ in range(400):  # anvil may return the hash slightly before the block is mined
            receipt = self.rpc("eth_getTransactionReceipt", [h])
            if receipt is not None:
                break
            time.sleep(0.005)
        if receipt is None:
            sys.exit(f"seed: no receipt for {h}: {who} -> {sig} {args}")
        if int(receipt["status"], 16) != 1:
            sys.exit(f"seed: transaction reverted: {who} -> {sig} {args}")
        self.t += 1
        self.count += 1
        return receipt


def lerp(a, b, f):
    return a + (b - a) * f


class Seeder:
    def __init__(self, rpc: Rpc, dep: dict, t0: int, t_end: int):
        self.rpc = rpc
        self.pm = dep["PredictionMarket"]
        self.book = dep["OrderBook"]
        self.oracle = dep["ReputationOracle"]
        self.usdt = dep["USDT"]
        self.dai = dep["DAI"]
        self.weth = dep["WETH"]
        self.unit = {self.usdt: 10**6, self.dai: 10**18, self.weth: 10**18}
        self.t0 = t0
        self.t_end = t_end
        self.ch = Chain(rpc, t0 + MIN)
        self.rng = random.Random(4053)
        self.markets: dict[str, dict] = {}

    # ------------------------------------------------------------------ reads

    def prices(self, mid: int) -> list[float]:
        return [p / 1e18 for p in decode_uint_array(self.rpc.call(self.pm, "getPrices(uint256)", mid))]

    def shares(self, who: str, mid: int, outcome: int) -> int:
        pid = (mid << 8) | outcome
        return decode_uint(self.rpc.call(self.pm, "balanceOf(address,uint256)", A[who], pid))

    def market_count(self) -> int:
        return decode_uint(self.rpc.call(self.pm, "marketCount()"))

    def order_count(self) -> int:
        return decode_uint(self.rpc.call(self.book, "orderCount()"))

    # ------------------------------------------------------------------ actions

    def fund(self) -> None:
        for who in ["Alice", "Bob", "Carol", "Eve", "Frank", "Grace", "Heidi", "Ivan"]:
            self.ch.send(who, self.usdt, "mint(address,uint256)", A[who], 60_000 * 10**6)
            self.ch.send(who, self.dai, "mint(address,uint256)", A[who], 60_000 * 10**18)
            self.ch.send(who, self.weth, "deposit()", value=30 * 10**18)
            for token in (self.usdt, self.dai, self.weth):
                for spender in (self.pm, self.book):
                    self.ch.send(who, token, "approve(address,uint256)", spender, MAX)
            self.ch.send(who, self.pm, "setApprovalForAll(address,bool)", self.book, True)
        # the arbitrator holds a little USDT; Judy is left untouched (fresh account for the faucet/approval demo)
        self.ch.send("Dave", self.usdt, "faucet()")
        for who in ["Eve", "Frank", "Grace", "Heidi"]:
            self.ch.send("Alice", self.oracle, "registerReporter(address)", A[who])

    def create(self, key, who, token, question, category, labels, close, resolution, arbitrator, liquidity, odds, fee,
               path, traders, trade_every=10 * HOUR):
        odds_bps = [int(round(o * 10_000)) for o in odds]
        odds_bps[-1] = 10_000 - sum(odds_bps[:-1])
        params = (question, category, labels, close, resolution, arbitrator, token,
                  int(liquidity * self.unit[token]), odds_bps, fee)
        self.ch.send(who, self.pm, CREATE_SIG, params)
        mid = self.market_count()
        self.markets[key] = dict(id=mid, token=token, n=len(labels), liq=liquidity, close=close, path=path,
                                 traders=traders, every=trade_every, created=self.ch.t)
        return mid

    def target(self, m: dict, t: int) -> list[float]:
        """Target probability vector at time t: piecewise-linear path through keypoints plus noise."""
        keys = m["path"]  # list of (fraction of trading window, probs)
        start, end = m["created"], min(m["close"], self.t_end)
        f = 0.0 if end <= start else max(0.0, min(1.0, (t - start) / (end - start)))
        for (fa, pa), (fb, pb) in zip(keys, keys[1:]):
            if fa <= f <= fb:
                g = 0.0 if fb == fa else (f - fa) / (fb - fa)
                probs = [lerp(x, y, g) for x, y in zip(pa, pb)]
                break
        else:
            probs = list(keys[-1][1])
        probs = [max(0.02, p + self.rng.gauss(0, 0.012)) for p in probs]
        s = sum(probs)
        return [p / s for p in probs]

    def trade_towards(self, key: str, trader: str) -> None:
        m = self.markets[key]
        mid, unit = m["id"], self.unit[m["token"]]
        p = self.prices(mid)
        tgt = self.target(m, self.ch.t)
        gaps = [a - b for a, b in zip(tgt, p)]
        under = max(range(m["n"]), key=lambda k: gaps[k])
        over = min(range(m["n"]), key=lambda k: gaps[k])
        held = self.shares(trader, mid, over)
        if held > 0 and gaps[over] < -0.012 and self.rng.random() < 0.35:
            amount = int(held * self.rng.uniform(0.3, 0.8))
            if amount > 0:
                self.ch.send(trader, self.pm, "sell(uint256,uint8,uint256,uint256)", mid, over, amount, 0)
                return
        # partial moves towards the target (multi-outcome pools react more strongly, so trade smaller)
        k = self.rng.uniform(0.5, 1.4) if m["n"] == 2 else self.rng.uniform(0.25, 0.7)
        size = max(abs(gaps[under]), 0.006) * m["liq"] * k
        amount = max(int(size * unit), unit // 20)
        self.ch.send(trader, self.pm, "buy(uint256,uint8,uint256,uint256)", mid, under, amount, 0)

    def buy(self, who, key, outcome, amount_units):
        m = self.markets[key]
        amount = int(amount_units * self.unit[m["token"]])
        self.ch.send(who, self.pm, "buy(uint256,uint8,uint256,uint256)", m["id"], outcome, amount, 0)

    def order(self, who, key, outcome, side, price_bps, amount_units, expiry=0) -> int:
        m = self.markets[key]
        amount = int(amount_units * self.unit[m["token"]])
        self.ch.send(who, self.book, "placeOrder(uint256,uint8,uint8,uint16,uint256,uint64)", m["id"], outcome, side,
                     price_bps, amount, expiry)
        return self.order_count()

    # ------------------------------------------------------------------ scenario

    def run(self) -> None:
        t0, te, usdt, dai, weth = self.t0, self.t_end, self.usdt, self.dai, self.weth
        dave, oracle = A["Dave"], self.oracle
        self.fund()

        # ---- markets (ids 1..9 in this order)
        self.ch.at(t0 + 30 * MIN)
        self.create("btc", "Alice", usdt, "Will BTC close above $150,000 on 31 Dec 2026 (UTC, CoinGecko daily close)?",
                    "Crypto", ["Yes", "No"], te + 94 * DAY, te + 95 * DAY, dave, 5000, [0.40, 0.60], 200,
                    [(0, [0.40, 0.60]), (0.35, [0.44, 0.56]), (0.7, [0.36, 0.64]), (1, [0.33, 0.67])],
                    ["Bob", "Carol", "Ivan", "Frank", "Grace"], 7 * HOUR)
        self.ch.at(t0 + 1 * HOUR)
        self.create("dex", "Alice", dai, "Which chain will record the most DEX volume in Q4 2026 (DefiLlama)?",
                    "Crypto", ["Ethereum", "Solana", "Base", "Other"], te + 95 * DAY, te + 98 * DAY, dave, 4000,
                    [0.35, 0.40, 0.15, 0.10], 150,
                    [(0, [0.35, 0.40, 0.15, 0.10]), (0.5, [0.31, 0.43, 0.17, 0.09]), (1, [0.29, 0.41, 0.22, 0.08])],
                    ["Bob", "Carol", "Heidi", "Ivan"], 11 * HOUR)
        self.ch.at(t0 + 2 * HOUR)
        self.create("eth", "Carol", weth,
                    "Will the next Ethereum network upgrade after Fusaka activate on mainnet before 1 Jul 2027?",
                    "Tech", ["Yes", "No"], te + 270 * DAY, te + 271 * DAY, dave, 5, [0.55, 0.45], 100,
                    [(0, [0.55, 0.45]), (0.5, [0.58, 0.42]), (1, [0.63, 0.37])], ["Bob", "Ivan", "Eve"], 14 * HOUR)
        self.ch.at(t0 + 3 * HOUR)
        self.create("rain", "Alice", usdt,
                    "Will MSS record more than 200 mm of rainfall at Changi in September 2026? (resolved by reporter vote)",
                    "Weather", ["Yes", "No"], te - 2 * HOUR, te - 1 * HOUR, oracle, 1500, [0.5, 0.5], 200,
                    [(0, [0.50, 0.50]), (0.6, [0.58, 0.42]), (1, [0.64, 0.36])], ["Bob", "Carol", "Ivan"], 12 * HOUR)
        self.ch.at(t0 + 4 * HOUR)
        self.create("quiz", "Alice", usdt, "Will the SC4053 mid-term quiz average be at least 70/100?",
                    "Campus", ["Yes", "No"], te - 1 * DAY, te - 3 * HOUR, dave, 1000, [0.55, 0.45], 200,
                    [(0, [0.55, 0.45]), (1, [0.70, 0.30])], ["Bob", "Carol", "Ivan", "Eve"], 13 * HOUR)
        self.ch.at(t0 + 5 * HOUR)
        self.create("hack", "Alice", dai, "Which team will win the NTU Blockchain Hackathon 2026 grand prize?",
                    "Campus", ["Team Alpha", "Team Beta", "Team Gamma"], t0 + 3 * DAY, t0 + 3 * DAY + 12 * HOUR,
                    dave, 2000, [0.34, 0.33, 0.33], 200,
                    [(0, [0.34, 0.33, 0.33]), (0.6, [0.25, 0.50, 0.25]), (1, [0.17, 0.68, 0.15])],
                    ["Bob", "Carol", "Ivan"], 8 * HOUR)
        self.ch.at(t0 + 6 * HOUR)
        self.create("lecture", "Alice", usdt,
                    "Will the SC4053 guest lecture on DeFi take place on 18 Sep 2026? (resolved by reporter vote)",
                    "Campus", ["Yes", "No"], t0 + 4 * DAY, t0 + 5 * DAY, oracle, 1000, [0.6, 0.4], 200,
                    [(0, [0.60, 0.40]), (1, [0.82, 0.18])], ["Bob", "Carol", "Ivan"], 9 * HOUR)
        self.ch.at(t0 + 7 * HOUR)
        self.create("gas", "Alice", weth,
                    "Will average Ethereum L1 gas stay below 2 gwei during the week of 14 Sep 2026?",
                    "Crypto", ["Yes", "No"], t0 + 36 * HOUR, t0 + 2 * DAY, A["Ivan"], 2, [0.5, 0.5], 100,
                    [(0, [0.50, 0.50]), (1, [0.44, 0.56])], ["Bob", "Carol"], 6 * HOUR)
        self.ch.at(t0 + 8 * HOUR)
        self.create("epl", "Alice", usdt, "Which club will top the Premier League table on 1 Jan 2027?",
                    "Sports", ["Arsenal", "Liverpool", "Man City", "Chelsea", "Other"], te + 95 * DAY,
                    te + 97 * DAY, dave, 3000, [0.28, 0.30, 0.22, 0.10, 0.10], 200,
                    [(0, [0.28, 0.30, 0.22, 0.10, 0.10]), (0.5, [0.31, 0.27, 0.21, 0.12, 0.09]),
                     (1, [0.33, 0.26, 0.19, 0.13, 0.09])], ["Bob", "Carol", "Ivan", "Frank", "Grace"], 12 * HOUR)

        # ---- one-off events (time, callable)
        m = self.markets
        events: list[tuple[int, int, callable]] = []

        def ev(ts, fn):
            events.append((ts, len(events), fn))

        # organic trading, per market, at random intervals inside the trading window
        for key, mk in m.items():
            ts = mk["created"] + 40 * MIN
            stop = min(mk["close"], te) - 20 * MIN
            k = 0
            while ts < stop:
                trader = mk["traders"][k % len(mk["traders"])]
                ev(ts, lambda key=key, trader=trader: self.trade_towards(key, trader))
                ts += int(self.rng.expovariate(1 / mk["every"])) + 20 * MIN
                k += 1

        # explicit positions used by the live demo
        ev(t0 + 10 * HOUR, lambda: self.buy("Bob", "gas", 0, 0.5))
        ev(t0 + 11 * HOUR, lambda: self.buy("Carol", "gas", 1, 0.3))
        ev(t0 + 20 * HOUR, lambda: self.buy("Carol", "hack", 1, 300))
        ev(t0 + 22 * HOUR, lambda: self.buy("Ivan", "hack", 0, 250))
        ev(t0 + 30 * HOUR, lambda: self.buy("Bob", "hack", 1, 200))
        ev(t0 + 2 * DAY, lambda: self.ch.send("Ivan", self.pm, "addLiquidity(uint256,uint256,uint256)", m["btc"]["id"],
                                              2000 * 10**6, 0))
        ev(t0 + 2 * DAY + 3 * HOUR, lambda: self.buy("Bob", "lecture", 0, 150))
        ev(t0 + 2 * DAY + 5 * HOUR, lambda: self.buy("Carol", "lecture", 1, 80))

        # hackathon market: Dave reports "Team Beta"; Bob redeems, Carol keeps her winnings for the demo
        ev(t0 + 4 * DAY, lambda: self.ch.send("Dave", self.pm, "reportOutcome(uint256,uint8)", m["hack"]["id"], 1))
        ev(t0 + 4 * DAY + 2 * HOUR, lambda: self.ch.send("Bob", self.pm, "redeem(uint256)", m["hack"]["id"]))

        # guest-lecture market: reputation-weighted vote (Heidi votes against the consensus)
        for i, (who, outcome) in enumerate([("Eve", 0), ("Frank", 0), ("Heidi", 1), ("Grace", 0)]):
            ev(t0 + 5 * DAY + (i + 1) * HOUR,
               lambda who=who, outcome=outcome: self.ch.send(who, oracle, "vote(uint256,uint8)", m["lecture"]["id"],
                                                             outcome))
        ev(t0 + 6 * DAY + HOUR, lambda: self.ch.send("Alice", oracle, "finalize(uint256)", m["lecture"]["id"]))
        ev(t0 + 6 * DAY + 3 * HOUR, lambda: self.ch.send("Bob", self.pm, "redeem(uint256)", m["lecture"]["id"]))
        ev(t0 + 6 * DAY + 5 * HOUR, lambda: self.ch.send("Alice", self.pm, "claimFees(uint256)", m["btc"]["id"]))

        # quiz market: clear positions for the arbitrator demo
        ev(te - 1 * DAY - 3 * HOUR, lambda: self.buy("Bob", "quiz", 0, 200))
        ev(te - 1 * DAY - 2 * HOUR, lambda: self.buy("Carol", "quiz", 1, 120))

        # peer-to-peer order book on the BTC and EPL markets
        def p2p():
            btc, epl = m["btc"]["id"], m["epl"]["id"]
            self.ch.send("Carol", self.pm, "splitPosition(uint256,uint256)", btc, 800 * 10**6)
            ask1 = self.order("Carol", "btc", 0, SELL, 3700, 250)
            self.order("Carol", "btc", 0, SELL, 3900, 150)
            self.order("Carol", "btc", 1, SELL, 6900, 200)
            self.order("Ivan", "btc", 0, BUY, 3100, 300)
            self.order("Bob", "btc", 1, BUY, 6000, 150)
            self.ch.t += 3 * HOUR
            self.ch.send("Frank", self.book, "fillOrder(uint256,uint256)", ask1, 90 * 10**6)  # partial fill
            self.ch.send("Carol", self.pm, "splitPosition(uint256,uint256)", epl, 300 * 10**6)
            self.order("Carol", "epl", 0, SELL, 3500, 100)
            self.order("Grace", "epl", 1, BUY, 2400, 120)
            stale = self.order("Carol", "epl", 2, SELL, 2500, 80)
            self.ch.t += HOUR
            self.ch.send("Carol", self.book, "cancelOrder(uint256)", stale)

        ev(te - 2 * DAY, p2p)

        # rain market: voting opens at te - 1h; Eve has already voted when the demo starts
        ev(te - 25 * MIN, lambda: self.ch.send("Eve", oracle, "vote(uint256,uint8)", m["rain"]["id"], 0))

        for ts, _, fn in sorted(events, key=lambda e: (e[0], e[1])):
            self.ch.at(ts)
            fn()

        # bring the chain clock to (at least) the current wall-clock time
        now = max(int(time.time()), self.t_end)
        self.ch.at(now)
        self.rpc("evm_setNextBlockTimestamp", [self.ch.t])
        self.rpc("evm_mine", [])
        print(f"seed: {self.ch.count} transactions, {len(self.markets)} markets, chain time {self.ch.t}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", default="http://127.0.0.1:8554")
    ap.add_argument("--deployment", required=True)
    ap.add_argument("--end", type=int, default=int(time.time()), help="unix time the seeded history ends at")
    ap.add_argument("--days", type=int, default=10, help="length of the seeded history")
    args = ap.parse_args()
    dep = json.load(open(args.deployment))
    rpc = Rpc(args.rpc)
    Seeder(rpc, dep, args.end - args.days * DAY, args.end).run()


if __name__ == "__main__":
    main()
