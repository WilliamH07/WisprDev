"use strict";

const OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";
const FISH_AUDIO_MODEL = "fish-audio/transcribe-1";
const DEFAULT_TRANSCRIPTION_BASE_URL = "https://api.groq.com/openai/v1";

function isOpenRouterModel(model) {
  return String(model || "").trim().toLowerCase().startsWith("fish-audio/");
}

/** An explicit URL wins; OpenRouter-hosted models go to OpenRouter; else the default. */
function transcriptionBaseUrl({ model, explicitUrl = "", defaultUrl = DEFAULT_TRANSCRIPTION_BASE_URL }) {
  const explicit = String(explicitUrl).trim();
  if (explicit) return explicit.replace(/\/+$/, "");
  return isOpenRouterModel(model) ? OPENROUTER_BASE_URL : defaultUrl;
}

/** Key priority: explicit transcription key, then the OpenRouter key for OpenRouter models. */
function transcriptionApiKey({ model, explicitKey = "", openRouterKey = "", defaultKey = "" }) {
  const explicit = String(explicitKey).trim();
  if (explicit) return explicit;
  const router = String(openRouterKey).trim();
  if (isOpenRouterModel(model) && router) return router;
  return String(defaultKey).trim();
}

/** Models that think by default get a small reasoning budget; others none. */
function reasoningEffortFor(model) {
  return /gpt-oss/i.test(model) ? "low" : "none";
}

module.exports = {
  OPENROUTER_BASE_URL,
  FISH_AUDIO_MODEL,
  DEFAULT_TRANSCRIPTION_BASE_URL,
  isOpenRouterModel,
  transcriptionBaseUrl,
  transcriptionApiKey,
  reasoningEffortFor,
};
