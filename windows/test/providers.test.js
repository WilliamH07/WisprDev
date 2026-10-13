"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { transcribeWav, chatCompletion, prewarm, HttpError } = require("../src/core/providers");

function fakeFetch(handler) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init });
    return handler(url, init);
  };
  impl.calls = calls;
  return impl;
}

const jsonResponse = (body, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
  text: async () => JSON.stringify(body),
});

test("transcribeWav posts multipart to /audio/transcriptions and returns trimmed text", async () => {
  const fetchImpl = fakeFetch(() => jsonResponse({ text: "  bonjour  " }));
  const text = await transcribeWav(
    { baseUrl: "https://openrouter.ai/api/v1", apiKey: "k", model: "fish-audio/transcribe-1", language: "fr" },
    Buffer.from("RIFFxxxx"),
    fetchImpl
  );
  assert.equal(text, "bonjour");
  const { url, init } = fetchImpl.calls[0];
  assert.equal(url, "https://openrouter.ai/api/v1/audio/transcriptions");
  assert.equal(init.headers.Authorization, "Bearer k");
  assert.ok(init.body instanceof FormData);
  assert.equal(init.body.get("model"), "fish-audio/transcribe-1");
  assert.equal(init.body.get("language"), "fr");
  assert.equal(init.body.get("response_format"), "json");
});

test("HTTP errors carry the status", async () => {
  const fetchImpl = fakeFetch(() => jsonResponse({ error: "no" }, 401));
  await assert.rejects(
    () => transcribeWav({ baseUrl: "https://x.test/v1", apiKey: "k", model: "m" }, Buffer.alloc(4), fetchImpl),
    (error) => error instanceof HttpError && error.status === 401
  );
});

test("chat requests to OpenRouter are routed by latency with a reasoning budget", async () => {
  const fetchImpl = fakeFetch(() => jsonResponse({ choices: [{ message: { content: "ok" } }] }));
  const out = await chatCompletion(
    { baseUrl: "https://openrouter.ai/api/v1", apiKey: "k", model: "openai/gpt-oss-20b", system: "s", user: "u" },
    fetchImpl
  );
  assert.equal(out, "ok");
  const body = JSON.parse(fetchImpl.calls[0].init.body);
  assert.deepEqual(body.provider, { sort: "latency" });
  assert.deepEqual(body.reasoning, { effort: "low", exclude: true });
  assert.equal(body.temperature, 0);
  assert.equal(body.messages[0].role, "system");
});

test("chat requests to other providers carry no OpenRouter-only fields", async () => {
  const fetchImpl = fakeFetch(() => jsonResponse({ choices: [{ message: { content: "ok" } }] }));
  await chatCompletion({ baseUrl: "https://api.groq.com/openai/v1", apiKey: "k", model: "m", system: "s", user: "u" }, fetchImpl);
  const body = JSON.parse(fetchImpl.calls[0].init.body);
  assert.equal(body.provider, undefined);
  assert.equal(body.reasoning, undefined);
});

test("an invalid chat reply is an error", async () => {
  const fetchImpl = fakeFetch(() => jsonResponse({ choices: [] }));
  await assert.rejects(() => chatCompletion({ baseUrl: "https://x.test", apiKey: "k", model: "m", system: "s", user: "u" }, fetchImpl));
});

test("prewarm sends one unauthenticated HEAD per HTTPS host and skips others", () => {
  const fetchImpl = fakeFetch(() => jsonResponse({}));
  prewarm(["https://openrouter.ai/api/v1", "https://openrouter.ai/other", "http://localhost:1234", "not a url", "https://api.groq.com/openai/v1"], fetchImpl);
  assert.equal(fetchImpl.calls.length, 2);
  for (const { init } of fetchImpl.calls) {
    assert.equal(init.method, "HEAD");
    assert.equal(init.headers, undefined); // no key, no content
  }
});
