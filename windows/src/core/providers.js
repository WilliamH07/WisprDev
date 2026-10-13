"use strict";

const { reasoningEffortFor } = require("./routing");

class HttpError extends Error {
  constructor(status, body) {
    super(`HTTP ${status}${body ? `: ${String(body).slice(0, 200)}` : ""}`);
    this.status = status;
  }
}

function withTimeout(signal, timeoutMs) {
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

/** Opens (and keeps alive) the TLS connection to HTTPS provider hosts. Sends no content. */
function prewarm(baseUrls, fetchImpl = fetch) {
  const seen = new Set();
  for (const raw of baseUrls) {
    let url;
    try {
      url = new URL(String(raw).trim());
    } catch {
      continue;
    }
    if (url.protocol !== "https:" || seen.has(url.host)) continue;
    seen.add(url.host);
    fetchImpl(`https://${url.host}/`, { method: "HEAD", signal: AbortSignal.timeout(5000) }).catch(() => {});
  }
}

/** POST /audio/transcriptions (OpenAI-compatible multipart; also accepted by OpenRouter). */
async function transcribeWav({ baseUrl, apiKey, model, language, timeoutMs = 20000, signal }, wavBuffer, fetchImpl = fetch) {
  const form = new FormData();
  form.append("file", new Blob([wavBuffer], { type: "audio/wav" }), "audio.wav");
  form.append("model", model);
  form.append("response_format", "json");
  if (language) form.append("language", language);
  const response = await fetchImpl(`${baseUrl}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
    signal: withTimeout(signal, timeoutMs),
  });
  if (!response.ok) throw new HttpError(response.status, await response.text().catch(() => ""));
  const json = await response.json();
  return String(json.text || "").trim();
}

/** POST /chat/completions. OpenRouter requests are routed by latency, not price. */
async function chatCompletion(
  { baseUrl, apiKey, model, system, user, timeoutMs = 20000, signal },
  fetchImpl = fetch
) {
  const isOpenRouter = baseUrl.includes("openrouter.ai");
  const body = {
    model,
    temperature: 0,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
  };
  if (isOpenRouter) {
    body.provider = { sort: "latency" };
    body.reasoning = { effort: reasoningEffortFor(model), exclude: true };
  }
  const response = await fetchImpl(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      ...(isOpenRouter ? { "X-Title": "Wisper" } : {}),
    },
    body: JSON.stringify(body),
    signal: withTimeout(signal, timeoutMs),
  });
  if (!response.ok) throw new HttpError(response.status, await response.text().catch(() => ""));
  const json = await response.json();
  const content = json?.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("Réponse du modèle invalide");
  return content;
}

module.exports = { HttpError, prewarm, transcribeWav, chatCompletion };
