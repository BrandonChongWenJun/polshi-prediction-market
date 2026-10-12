// Probability-over-time chart (hand-rolled SVG). Follows the dataviz mark specs: 2px lines, hairline solid grid,
// end dots with a 2px surface ring, legend always present for >= 2 series, selective end labels, crosshair +
// tooltip listing every series (values lead), keyboard support, and a table view twin rendered by the caller.
import { esc, pct, fmtDate } from "./format.js";

const NS = "http://www.w3.org/2000/svg";
const HOUR = 3600;
const DAY = 86400;
const STEPS = [HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR, DAY, 2 * DAY, 7 * DAY, 14 * DAY, 30 * DAY, 91 * DAY];

function color(i) {
  return `var(--s${(i % 8) + 1})`;
}

/** Value of each series at time t (step function: last point at or before t). */
function valueAt(points, t) {
  let lo = 0;
  let hi = points.length - 1;
  if (hi < 0) return null;
  if (t < points[0].t) return points[0].prices;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (points[mid].t <= t) lo = mid;
    else hi = mid - 1;
  }
  return points[lo].prices;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function tickFormat(t, step) {
  const d = new Date(t * 1000);
  const mon = MONTHS[d.getMonth()];
  if (step < DAY) return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return `${d.getDate()} ${mon}`;
}

function niceTicks(start, end, maxTicks) {
  const span = Math.max(1, end - start);
  const step = STEPS.find((s) => span / s <= maxTicks) || STEPS[STEPS.length - 1];
  const shift = -new Date().getTimezoneOffset() * 60; // local = utc + shift; align ticks to local midnight / hours
  const first = Math.ceil((start + shift) / step) * step - shift;
  const ticks = [];
  for (let t = first; t <= end; t += step) ticks.push(t);
  return { ticks, step };
}

export class ProbabilityChart {
  /**
   * @param {HTMLElement} root  container (the chart renders a legend + an SVG into it)
   */
  constructor(root) {
    this.root = root;
    this.root.innerHTML = `<div class="chart-legend" data-role="legend"></div>
      <div class="chart-wrap" tabindex="0" role="img" data-role="wrap"><svg data-role="svg" data-testid="prob-chart"></svg><div class="chart-tip" data-role="tip" hidden></div></div>`;
    this.legend = root.querySelector('[data-role="legend"]');
    this.wrap = root.querySelector('[data-role="wrap"]');
    this.svg = root.querySelector('[data-role="svg"]');
    this.tip = root.querySelector('[data-role="tip"]');
    this.data = null;
    this.cursor = null;
    this.ro = new ResizeObserver(() => this.render());
    this.ro.observe(this.wrap);
    this.wrap.addEventListener("pointermove", (e) => this.onPointer(e));
    this.wrap.addEventListener("pointerleave", () => this.hideCursor());
    this.wrap.addEventListener("keydown", (e) => this.onKey(e));
    this.wrap.addEventListener("blur", () => this.hideCursor());
  }

  destroy() {
    this.ro.disconnect();
  }

  /**
   * @param {object} d  { labels, points:[{t, prices[]}], start, end, resolvedAt?, winner?, highlight? }
   */
  setData(d) {
    this.data = d;
    this.render();
  }

  layout() {
    const width = Math.max(280, this.wrap.clientWidth - 20);
    const height = width < 520 ? 230 : 300;
    const n = this.data.labels.length;
    const endLabels = n <= 4 && width >= 520;
    const m = { top: 12, right: endLabels ? 118 : 16, bottom: 30, left: 44 };
    return { width, height, m, endLabels, iw: width - m.left - m.right, ih: height - m.top - m.bottom };
  }

  x(t) {
    const { start, end } = this.data;
    const L = this.L;
    return L.m.left + ((t - start) / Math.max(1, end - start)) * L.iw;
  }

  y(p) {
    const L = this.L;
    return L.m.top + (1 - p) * L.ih;
  }

  render() {
    if (!this.data) return;
    const d = this.data;
    const L = (this.L = this.layout());
    const svg = this.svg;
    svg.setAttribute("viewBox", `0 0 ${L.width} ${L.height}`);
    svg.setAttribute("height", L.height);
    const n = d.labels.length;
    const pts = d.points.filter((p) => p.t <= d.end);
    const startVals = valueAt(pts, d.start) || Array(n).fill(1 / n);
    const inRange = pts.filter((p) => p.t > d.start);
    const series = [{ t: d.start, prices: startVals }, ...inRange];
    const last = series[series.length - 1].prices;
    this.series = series;

    // legend (text in ink colours, identity from the line key)
    this.legend.innerHTML = d.labels
      .map(
        (lab, i) =>
          `<span class="lg"><span class="keyline" style="background:${color(i)}"></span>${esc(lab)} <b>${pct(last[i], 1)}</b></span>`,
      )
      .join("");
    this.wrap.setAttribute(
      "aria-label",
      `Probability chart. Latest: ${d.labels.map((l, i) => `${l} ${pct(last[i], 1)}`).join(", ")}`,
    );

    const parts = [];
    // grid + y axis
    for (const g of [0, 0.25, 0.5, 0.75, 1]) {
      const yy = this.y(g);
      parts.push(`<line x1="${L.m.left}" x2="${L.width - L.m.right}" y1="${yy}" y2="${yy}" style="stroke:var(--grid)" stroke-width="1" shape-rendering="crispEdges"/>`);
      parts.push(`<text x="${L.m.left - 8}" y="${yy + 4}" text-anchor="end" class="axis-t" style="fill:var(--ink-muted);font-size:11.5px;font-variant-numeric:tabular-nums">${Math.round(g * 100)}%</text>`);
    }
    // x axis
    const { ticks, step } = niceTicks(d.start, d.end, Math.max(2, Math.floor(L.iw / 110)));
    parts.push(`<line x1="${L.m.left}" x2="${L.width - L.m.right}" y1="${this.y(0)}" y2="${this.y(0)}" style="stroke:var(--axis)" stroke-width="1" shape-rendering="crispEdges"/>`);
    for (const t of ticks) {
      const xx = this.x(t);
      if (xx < L.m.left + 26 || xx > L.width - L.m.right - 20) continue;
      parts.push(`<text x="${xx}" y="${L.height - 8}" text-anchor="middle" style="fill:var(--ink-muted);font-size:11.5px">${esc(tickFormat(t, step))}</text>`);
    }
    // resolution marker
    if (d.resolvedAt && d.resolvedAt >= d.start && d.resolvedAt <= d.end) {
      const xr = this.x(d.resolvedAt);
      parts.push(`<line x1="${xr}" x2="${xr}" y1="${L.m.top}" y2="${this.y(0)}" style="stroke:var(--text-2)" stroke-width="1"/>`);
      parts.push(`<text x="${xr - 4}" y="${L.m.top + 10}" text-anchor="end" style="fill:var(--text-2);font-size:11.5px;font-weight:600">Resolved</text>`);
    }
    // step lines
    for (let i = 0; i < n; i++) {
      let dstr = `M${this.x(series[0].t).toFixed(1)},${this.y(series[0].prices[i]).toFixed(1)}`;
      for (let k = 1; k < series.length; k++) {
        dstr += `H${this.x(series[k].t).toFixed(1)}V${this.y(series[k].prices[i]).toFixed(1)}`;
      }
      dstr += `H${this.x(d.end).toFixed(1)}`;
      const w = d.highlight === undefined ? 2 : d.highlight === i ? 2.5 : 1.75;
      const op = d.highlight === undefined || d.highlight === i ? 1 : 0.75;
      parts.push(`<path d="${dstr}" fill="none" style="stroke:${color(i)}" stroke-width="${w}" stroke-linejoin="round" stroke-linecap="round" opacity="${op}" data-series="${i}"/>`);
    }
    // end dots with surface ring
    const xe = this.x(d.end);
    for (let i = 0; i < n; i++) {
      parts.push(`<circle cx="${xe}" cy="${this.y(last[i])}" r="4" style="fill:${color(i)};stroke:var(--surface)" stroke-width="2"/>`);
    }
    // selective end labels (<= 4 series, only if they do not collide)
    if (L.endLabels) {
      const ys = last.map((p, i) => ({ i, y: this.y(p) })).sort((a, b) => a.y - b.y);
      const collide = ys.some((a, k) => k > 0 && a.y - ys[k - 1].y < 16);
      if (!collide) {
        for (const { i, y } of ys) {
          const lab = d.labels[i].length > 12 ? d.labels[i].slice(0, 11) + "…" : d.labels[i];
          parts.push(`<text x="${xe + 10}" y="${y + 4}" style="fill:var(--text);font-size:12.5px;font-weight:650">${esc(lab)} <tspan style="fill:var(--text-2);font-weight:500">${pct(last[i], 0)}</tspan></text>`);
        }
      }
    }
    // crosshair layer (filled on hover)
    parts.push(`<g data-role="cursor"></g>`);
    svg.innerHTML = parts.join("");
    this.cursorLayer = svg.querySelector('[data-role="cursor"]');
    if (this.cursor !== null) this.drawCursor(this.cursor);
  }

  onPointer(e) {
    if (!this.data || !this.L) return;
    const rect = this.svg.getBoundingClientRect();
    const scale = this.L.width / rect.width;
    const px = (e.clientX - rect.left) * scale;
    if (px < this.L.m.left || px > this.L.width - this.L.m.right) {
      this.hideCursor();
      return;
    }
    const { start, end } = this.data;
    const t = start + ((px - this.L.m.left) / this.L.iw) * (end - start);
    this.drawCursor(t);
  }

  onKey(e) {
    if (!this.series || !this.series.length) return;
    const times = this.series.map((p) => p.t).concat([this.data.end]);
    let idx = this.cursor === null ? times.length - 1 : times.findIndex((t) => t >= this.cursor);
    if (e.key === "ArrowLeft") idx = Math.max(0, (idx < 0 ? times.length : idx) - 1);
    else if (e.key === "ArrowRight") idx = Math.min(times.length - 1, idx + 1);
    else if (e.key === "Escape") return this.hideCursor();
    else return;
    e.preventDefault();
    this.drawCursor(times[idx]);
  }

  drawCursor(t) {
    this.cursor = t;
    const d = this.data;
    const vals = valueAt(this.series, t) || [];
    const xx = this.x(t);
    const L = this.L;
    let g = `<line x1="${xx}" x2="${xx}" y1="${L.m.top}" y2="${this.y(0)}" style="stroke:var(--text-2)" stroke-width="1"/>`;
    vals.forEach((p, i) => {
      g += `<circle cx="${xx}" cy="${this.y(p)}" r="4" style="fill:${color(i)};stroke:var(--surface)" stroke-width="2"/>`;
    });
    this.cursorLayer.innerHTML = g;
    // tooltip: one row per series, value first, sorted by value
    const rows = vals
      .map((p, i) => ({ p, i }))
      .sort((a, b) => b.p - a.p)
      .map(
        ({ p, i }) =>
          `<div class="tr"><span class="keyline" style="background:${color(i)}"></span><b>${pct(p, 1)}</b><span>${esc(d.labels[i])}</span></div>`,
      )
      .join("");
    this.tip.innerHTML = `<div class="tt">${esc(fmtDate(t))}</div>${rows}`;
    this.tip.hidden = false;
    const rect = this.svg.getBoundingClientRect();
    const scale = rect.width / L.width;
    const left = xx * scale + 8;
    const tipW = this.tip.offsetWidth || 170;
    const flip = left + tipW + 24 > rect.width;
    this.tip.style.left = `${flip ? xx * scale - tipW - 4 : left + 14}px`;
    this.tip.style.top = `${L.m.top * scale + 6}px`;
  }

  hideCursor() {
    this.cursor = null;
    if (this.cursorLayer) this.cursorLayer.innerHTML = "";
    this.tip.hidden = true;
  }
}
