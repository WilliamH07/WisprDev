"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { hedged } = require("../src/core/hedge");
const { sleep } = require("./helpers");

test("fast primary wins and the retry never starts", async () => {
  let retryCalled = false;
  const value = await hedged(
    async () => "primary",
    async () => {
      retryCalled = true;
      return "retry";
    },
    { delayMs: 50 }
  );
  assert.equal(value, "primary");
  await sleep(80);
  assert.equal(retryCalled, false);
});

test("slow primary is overtaken by the retry after the delay", async () => {
  const started = Date.now();
  const value = await hedged(
    async () => {
      await sleep(400);
      return "primary";
    },
    async () => {
      await sleep(10);
      return "retry";
    },
    { delayMs: 50 }
  );
  assert.equal(value, "retry");
  assert.ok(Date.now() - started < 300);
});

test("a failing primary starts the retry immediately", async () => {
  const started = Date.now();
  const value = await hedged(
    async () => {
      throw new Error("down");
    },
    async () => "retry",
    { delayMs: 1000 }
  );
  assert.equal(value, "retry");
  assert.ok(Date.now() - started < 500);
});

test("both failing rejects with the primary error", async () => {
  await assert.rejects(
    () =>
      hedged(
        async () => {
          throw new Error("primary down");
        },
        async () => {
          throw new Error("retry down");
        },
        { delayMs: 10 }
      ),
    /primary down/
  );
});

test("without a retry function it just runs the primary", async () => {
  assert.equal(await hedged(async () => "only", null), "only");
});

test("the losing request is aborted", async () => {
  let primarySignal;
  await hedged(
    (signal) => {
      primarySignal = signal;
      return new Promise((resolve) => setTimeout(() => resolve("slow"), 500));
    },
    async () => "fast",
    { delayMs: 10 }
  );
  assert.equal(primarySignal.aborted, true);
});
