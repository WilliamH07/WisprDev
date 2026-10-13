"use strict";

const RATE = 24000;

function tone(seconds, amplitude = 0.3) {
  const samples = new Int16Array(Math.floor(seconds * RATE));
  for (let i = 0; i < samples.length; i += 1) {
    samples[i] = Math.round(amplitude * Math.sin((2 * Math.PI * 220 * i) / RATE) * 32767);
  }
  return samples;
}

function silence(seconds) {
  return new Int16Array(Math.floor(seconds * RATE));
}

function concat(...parts) {
  const out = new Int16Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

/** Feeds audio in small blocks like a capture callback. */
function feed(target, audio, block = 480) {
  const results = [];
  for (let i = 0; i < audio.length; i += block) {
    const out = target.append(audio.subarray(i, Math.min(i + block, audio.length)));
    if (Array.isArray(out)) results.push(...out);
  }
  return results;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

module.exports = { RATE, tone, silence, concat, feed, sleep };
