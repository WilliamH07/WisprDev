"use strict";

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** Fast on average but occasionally very slow is the failure mode to avoid. */
function isErratic(samples) {
  const m = median(samples);
  if (m === null || m <= 0) return false;
  return Math.max(...samples) > Math.max(m * 3, 2000);
}

/** Runs `fn` n times sequentially and reports cold (first) and typical (median of the rest) latency in ms. */
async function timeRuns(fn, runs, clock = Date.now) {
  const samples = [];
  for (let i = 0; i < runs; i += 1) {
    const start = clock();
    await fn(i);
    samples.push(clock() - start);
  }
  return {
    samples,
    coldMs: samples[0] ?? null,
    warmMs: median(samples.slice(1)),
    medianMs: median(samples),
    worstMs: samples.length ? Math.max(...samples) : null,
    erratic: isErratic(samples),
  };
}

module.exports = { median, isErratic, timeRuns };
