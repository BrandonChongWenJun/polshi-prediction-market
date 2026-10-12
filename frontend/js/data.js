// Data layer: normalises contract views and caches event history (for charts / activity feeds).
import { pm, book, oracle, readProvider, tokenByAddress, sameAddr, ORACLE_ADDRESS, INVALID, cfg } from "./chain.js";
import { pricesFromPool } from "./format.js";

export const PHASE = { Trading: 0, Closed: 1, Reporting: 2, TimedOut: 3, Resolved: 4, Invalid: 5 };
export const SIDE = { Buy: 0, Sell: 1 };
export const ORDER_STATUS = { Open: 0, Filled: 1, Cancelled: 2 };
export const ROUND = { Pending: 0, Resolved: 1, NoConsensus: 2, Voided: 3 };

const arr = (x) => Array.from(x ?? []);

export function normalizeMarket(v) {
  const token = tokenByAddress(v.collateral);
  const pool = arr(v.pool).map(BigInt);
  return {
    id: Number(v.id),
    creator: v.creator,
    arbitrator: v.arbitrator,
    isOracle: sameAddr(v.arbitrator, ORACLE_ADDRESS),
    collateral: v.collateral,
    token,
    createdAt: Number(v.createdAt),
    closeTime: Number(v.closeTime),
    resolutionTime: Number(v.resolutionTime),
    resolvedAt: Number(v.resolvedAt),
    feeBps: Number(v.feeBps),
    n: Number(v.numOutcomes),
    resolved: v.resolved,
    outcome: Number(v.outcome),
    phase: Number(v.phase),
    collateralLocked: BigInt(v.collateralLocked),
    totalLpShares: BigInt(v.totalLpShares),
    feePool: BigInt(v.feePool),
    volume: BigInt(v.volume),
    pool,
    prices: arr(v.prices).map((p) => Number(p) / 1e18),
    outcomeSupply: arr(v.outcomeSupply).map(BigInt),
    question: v.question,
    category: v.category,
    labels: arr(v.outcomeLabels).map(String),
  };
}

export async function fetchMarket(id) {
  return normalizeMarket(await pm.getMarket(id));
}

export async function fetchMarkets() {
  const count = Number(await pm.marketCount());
  const ids = Array.from({ length: count }, (_, i) => i + 1);
  const views = await Promise.all(ids.map((id) => pm.getMarket(id)));
  return views.map(normalizeMarket);
}

export async function fetchPosition(id, account) {
  if (!account) return null;
  const p = await pm.getUserPosition(id, account);
  return {
    balances: arr(p.balances).map(BigInt),
    lpShares: BigInt(p.lpShares),
    pendingFees: BigInt(p.pendingFees),
    redeemable: BigInt(p.redeemable),
  };
}

export function normalizeOrder(id, o) {
  return {
    id: Number(id),
    maker: o.maker,
    expiry: Number(o.expiry),
    createdAt: Number(o.createdAt),
    price: Number(o.price), // bps of 1 collateral per share
    outcome: Number(o.outcome),
    side: Number(o.side),
    status: Number(o.status),
    marketId: Number(o.marketId),
    amount: BigInt(o.amount),
    remaining: BigInt(o.remaining),
    escrow: BigInt(o.escrow),
  };
}

export async function fetchOrders(marketId) {
  const total = Number(await book.marketOrderCount(marketId));
  const out = [];
  for (let offset = 0; offset < total; offset += 200) {
    const [ids, orders] = await book.getMarketOrders(marketId, offset, 200);
    arr(ids).forEach((id, i) => out.push(normalizeOrder(id, orders[i])));
  }
  return out;
}

export async function fetchRound(marketId, n) {
  const [r, votes] = await Promise.all([oracle.getRound(marketId), oracle.getVotes(marketId)]);
  const tally = arr(r.tally).map(BigInt);
  return {
    votingStart: Number(r.votingStart),
    votingEnd: Number(r.votingEnd),
    extended: r.extended,
    status: Number(r.status),
    result: Number(r.result),
    snapshotTotal: BigInt(r.snapshotTotalReputation),
    totalWeight: BigInt(r.totalWeight),
    requiredWeight: BigInt(r.requiredWeight),
    voterCount: Number(r.voterCount),
    tally, // n + 1 entries, last = INVALID
    votes: arr(votes[0]).map((voter, i) => ({
      voter,
      outcome: Number(votes[1][i]),
      weight: BigInt(votes[2][i]),
    })),
    n,
  };
}

let oracleParams = null;
export async function fetchOracleParams() {
  if (oracleParams) return oracleParams;
  const [votingPeriod, quorumBps, reward, slashBps, initial, maxRep, owner] = await Promise.all([
    oracle.votingPeriod(),
    oracle.quorumBps(),
    oracle.REWARD(),
    oracle.SLASH_BPS(),
    oracle.INITIAL_REPUTATION(),
    oracle.MAX_REPUTATION(),
    oracle.owner(),
  ]);
  oracleParams = {
    votingPeriod: Number(votingPeriod),
    quorumBps: Number(quorumBps),
    reward: Number(reward),
    slashBps: Number(slashBps),
    initial: Number(initial),
    maxRep: Number(maxRep),
    owner,
  };
  return oracleParams;
}

export async function fetchReporters() {
  const [[addrs, infos], total, active] = await Promise.all([
    oracle.getReporters(),
    oracle.totalReputation(),
    oracle.activeReporters(),
  ]);
  return {
    total: BigInt(total),
    active: Number(active),
    list: arr(addrs).map((a, i) => ({
      address: a,
      registered: infos[i].registered,
      votesCast: Number(infos[i].votesCast),
      correctVotes: Number(infos[i].correctVotes),
      reputation: Number(infos[i].reputation),
    })),
  };
}

export async function fetchReporter(addr) {
  if (!addr) return null;
  const r = await oracle.reporters(addr);
  return { registered: r.registered, reputation: Number(r.reputation) };
}

// ------------------------------------------------------------------------------------------------ event history

const blockTimes = new Map();
async function blockTime(n) {
  if (blockTimes.has(n)) return blockTimes.get(n);
  const b = await readProvider.getBlock(n);
  blockTimes.set(n, b.timestamp);
  return b.timestamp;
}

const history = new Map(); // marketId -> { next, points, trades, fills, loading }

/**
 * Incrementally loads PoolUpdated / Trade / OrderFilled logs of a market.
 * points: [{ t, prices[] }] (probability path), activity: trades and P2P fills, newest last.
 */
export async function fetchHistory(marketId) {
  let h = history.get(marketId);
  if (!h) {
    h = { next: cfg.startBlock || 0, points: [], activity: [], loading: null };
    history.set(marketId, h);
  }
  if (h.loading) return h.loading.then(() => h);
  h.loading = (async () => {
    const latest = await readProvider.getBlockNumber();
    if (latest < h.next) return;
    const from = h.next;
    const [pools, trades, fills] = await Promise.all([
      pm.queryFilter(pm.filters.PoolUpdated(marketId), from, latest),
      pm.queryFilter(pm.filters.Trade(marketId), from, latest),
      book.queryFilter(book.filters.OrderFilled(null, marketId), from, latest),
    ]);
    const txTime = new Map();
    for (const log of pools) {
      const t = Number(log.args.timestamp);
      txTime.set(log.transactionHash, t);
      h.points.push({ t, prices: pricesFromPool(arr(log.args.balances).map(BigInt)), block: log.blockNumber });
    }
    for (const log of trades) {
      h.activity.push({
        kind: "trade",
        t: txTime.get(log.transactionHash) ?? (await blockTime(log.blockNumber)),
        block: log.blockNumber,
        idx: log.index,
        tx: log.transactionHash,
        trader: log.args.trader,
        outcome: Number(log.args.outcome),
        isBuy: log.args.isBuy,
        collateral: BigInt(log.args.collateralAmount),
        shares: BigInt(log.args.shares),
        fee: BigInt(log.args.fee),
      });
    }
    for (const log of fills) {
      h.activity.push({
        kind: "fill",
        t: await blockTime(log.blockNumber),
        block: log.blockNumber,
        idx: log.index,
        tx: log.transactionHash,
        orderId: Number(log.args.orderId),
        taker: log.args.taker,
        maker: log.args.maker,
        shares: BigInt(log.args.shares),
        collateral: BigInt(log.args.collateral),
      });
    }
    h.points.sort((a, b) => a.t - b.t || a.block - b.block);
    h.activity.sort((a, b) => a.block - b.block || a.idx - b.idx);
    h.next = latest + 1;
  })();
  try {
    await h.loading;
  } finally {
    h.loading = null;
  }
  return h;
}

/** Order fills need the order's outcome/side, which the event does not carry. */
export function describeFill(fill, orders) {
  const o = orders.find((x) => x.id === fill.orderId);
  return o ? { outcome: o.outcome, side: o.side, price: o.price } : null;
}

export function phaseInfo(m, round) {
  const labels = m.labels;
  switch (m.phase) {
    case PHASE.Trading:
      return { key: "trading", text: "Trading" };
    case PHASE.Closed:
      return { key: "closed", text: "Closed · awaiting event" };
    case PHASE.Reporting:
      if (m.isOracle) {
        if (round && round.extended) return { key: "voting", text: "Voting · extended" };
        return { key: "voting", text: "Reporter vote" };
      }
      return { key: "reporting", text: "Awaiting arbitrator" };
    case PHASE.TimedOut:
      return { key: "timedout", text: "Arbitrator timed out" };
    case PHASE.Resolved:
      return { key: "resolved", text: `Resolved · ${labels[m.outcome] ?? "?"}` };
    case PHASE.Invalid:
      return { key: "invalid", text: "Invalid · pro-rata refund" };
    default:
      return { key: "closed", text: "Unknown" };
  }
}

export function outcomeName(m, outcome) {
  return outcome === INVALID ? "Invalid" : m.labels[outcome] ?? `#${outcome}`;
}
