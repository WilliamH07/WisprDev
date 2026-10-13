"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { UsageStats, computeSnapshot } = require("../src/core/stats");

function memoryStorage() {
  let data = null;
  return { read: () => data, write: (d) => { data = JSON.parse(JSON.stringify(d)); } };
}

test("snapshot totals, streaks and recent days", () => {
  const days = {
    "2026-03-01": { dictations: 2, words: 100, speakingSeconds: 60 },
    "2026-03-02": { dictations: 1, words: 50, speakingSeconds: 30 },
    "2026-03-03": { dictations: 3, words: 150, speakingSeconds: 90 },
    "2026-02-20": { dictations: 1, words: 10, speakingSeconds: 5 },
  };
  const snap = computeSnapshot(days, new Date(2026, 2, 3, 12), 14);
  assert.equal(snap.totalDictations, 7);
  assert.equal(snap.totalWords, 310);
  assert.equal(snap.currentStreak, 3);
  assert.equal(snap.bestStreak, 3);
  assert.equal(snap.recentDays.length, 14);
  assert.equal(snap.recentDays.at(-1).words, 150);
  assert.equal(computeSnapshot(days, new Date(2026, 2, 4, 12)).currentStreak, 3);
  assert.equal(computeSnapshot(days, new Date(2026, 2, 6, 12)).currentStreak, 0);
});

test("store records and aggregates without content", () => {
  const stats = new UsageStats(memoryStorage());
  const now = new Date(2026, 4, 10, 12);
  stats.record({ wordCount: 60, speakingSeconds: 30, now });
  stats.record({ wordCount: 0, speakingSeconds: 5, now });
  stats.record({ wordCount: 40, speakingSeconds: 30, now });
  const snap = stats.snapshot(now);
  assert.equal(snap.totalDictations, 2);
  assert.equal(snap.totalWords, 100);
  assert.equal(snap.averageWordsPerMinute, 100);
  stats.reset();
  assert.equal(stats.snapshot(now).totalWords, 0);
});

test("old days are pruned", () => {
  const stats = new UsageStats(memoryStorage(), { retentionDays: 10 });
  stats.record({ wordCount: 5, speakingSeconds: 1, now: new Date(2026, 0, 1) });
  stats.record({ wordCount: 5, speakingSeconds: 1, now: new Date(2026, 5, 1) });
  assert.equal(stats.snapshot(new Date(2026, 5, 1), 400).totalDictations, 1);
});
