"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { ChunkAccumulator, ChunkedSession } = require("../src/core/chunker");
const { RATE, tone, silence, concat, feed, sleep } = require("./helpers");

test("cuts a chunk at a pause and keeps short gaps together", () => {
  const acc = new ChunkAccumulator(RATE);
  const audio = concat(tone(4), silence(1), tone(4), silence(0.3), tone(3));
  const chunks = feed(acc, audio);
  assert.equal(chunks.length, 1);
  const firstSeconds = chunks[0].length / RATE;
  assert.ok(firstSeconds > 4.0 && firstSeconds < 4.6, `first chunk ${firstSeconds}`);
  const tail = acc.flush();
  assert.ok(tail);
  const tailSeconds = tail.length / RATE;
  assert.ok(tailSeconds > 7.0 && tailSeconds < 8.5, `tail ${tailSeconds}`);
});

test("continuous speech makes no chunk", () => {
  const acc = new ChunkAccumulator(RATE);
  assert.equal(feed(acc, tone(12)).length, 0);
});

test("silence after a cut is not a phrase", () => {
  const acc = new ChunkAccumulator(RATE);
  feed(acc, concat(tone(4), silence(1)));
  assert.equal(acc.flush(), null);
});

test("hard cap emits a chunk without any pause", () => {
  const acc = new ChunkAccumulator(RATE, { maxChunkSeconds: 5 });
  assert.equal(feed(acc, tone(6)).length, 1);
});

test("session keeps speech order even when chunks finish out of order", async () => {
  const delays = [60, 5, 30];
  let n = 0;
  const session = new ChunkedSession({
    sampleRate: RATE,
    transcribe: async () => {
      const index = n++;
      await sleep(delays[index]);
      return `p${index + 1}`;
    },
  });
  feed(session, concat(tone(4), silence(1), tone(4), silence(1), tone(3)));
  assert.equal(await session.finish(), "p1 p2 p3");
  assert.equal(session.chunkCount, 3);
});

test("session without a pause returns null so the whole file is used", async () => {
  const session = new ChunkedSession({ sampleRate: RATE, transcribe: async () => "never" });
  feed(session, tone(2));
  assert.equal(await session.finish(), null);
});

test("a failed chunk rejects so the caller can fall back", async () => {
  const session = new ChunkedSession({
    sampleRate: RATE,
    transcribe: async () => {
      throw new Error("boom");
    },
  });
  feed(session, concat(tone(4), silence(1), tone(2)));
  await assert.rejects(() => session.finish(), /boom/);
});

test("cancelled session ignores audio and finish", async () => {
  const session = new ChunkedSession({ sampleRate: RATE, transcribe: async () => "x" });
  session.cancel();
  feed(session, concat(tone(4), silence(1), tone(2)));
  assert.equal(await session.finish(), null);
});
