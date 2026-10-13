"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { median, isErratic, timeRuns } = require("../src/core/bench");

test("median", () => {
  assert.equal(median([]), null);
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([1, 2, 3, 10]), 2.5);
});

test("erratic detection flags a fast model with a slow tail", () => {
  assert.equal(isErratic([400, 420, 410, 380, 9000]), true);
  assert.equal(isErratic([400, 420, 410, 380, 900]), false);
  assert.equal(isErratic([]), false);
});

test("timeRuns reports cold, warm and worst", async () => {
  let t = 0;
  const durations = [900, 100, 120, 110];
  const clock = () => t;
  const result = await timeRuns(async (i) => { t += durations[i]; }, 4, clock);
  assert.equal(result.coldMs, 900);
  assert.equal(result.warmMs, 110);
  assert.equal(result.worstMs, 900);
  assert.equal(result.erratic, false);
});
