"use strict";

const { FISH_AUDIO_MODEL, OPENROUTER_BASE_URL, transcriptionBaseUrl, transcriptionApiKey } = require("./routing");
const { clampMaxWords, DEFAULT_MAX_WORDS } = require("./fastpath");
const { isValidChord } = require("./chord");

const SECRET_FIELDS = ["openRouterKey", "transcriptionApiKey", "cleanupApiKey"];

const DEFAULTS = Object.freeze({
  openRouterKey: "",
  transcriptionModel: FISH_AUDIO_MODEL,
  transcriptionBaseUrl: "",
  transcriptionApiKey: "",
  transcriptionLanguage: "",
  cleanupModel: "google/gemini-2.5-flash",
  cleanupFallbackModel: "openai/gpt-oss-20b",
  cleanupBaseUrl: "",
  cleanupApiKey: "",
  hedgeDelayMs: 1200,
  fastPathEnabled: true,
  fastPathMaxWords: DEFAULT_MAX_WORDS,
  chunkedEnabled: true,
  outputLanguage: "",
  vocabulary: "",
  customPrompt: "",
  macros: [],
  keepHistory: true,
  restoreClipboard: true,
  launchAtLogin: false,
  startDelayMs: 120,
  hotkeys: { dictate: ["Ctrl", "Meta"], rewrite: ["Ctrl", "Meta", "R"], edit: ["Ctrl", "Meta", "E"] },
});

const str = (v, fallback) => (typeof v === "string" ? v.trim() : fallback);
const bool = (v, fallback) => (typeof v === "boolean" ? v : fallback);
const num = (v, fallback, min, max) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : fallback;
};

/** Fills defaults and coerces every field so a corrupted settings file can never crash the app. */
function normalizeSettings(input = {}) {
  const d = DEFAULTS;
  const hotkeys = {};
  for (const action of Object.keys(d.hotkeys)) {
    const candidate = input.hotkeys && input.hotkeys[action];
    hotkeys[action] = isValidChord(candidate) ? [...candidate] : [...d.hotkeys[action]];
  }
  const macros = Array.isArray(input.macros)
    ? input.macros
        .filter((m) => m && typeof m.trigger === "string" && typeof m.payload === "string" && m.trigger.trim())
        .map((m) => ({ trigger: m.trigger.trim(), payload: m.payload }))
    : [];
  return {
    openRouterKey: str(input.openRouterKey, d.openRouterKey),
    transcriptionModel: str(input.transcriptionModel, d.transcriptionModel) || d.transcriptionModel,
    transcriptionBaseUrl: str(input.transcriptionBaseUrl, d.transcriptionBaseUrl),
    transcriptionApiKey: str(input.transcriptionApiKey, d.transcriptionApiKey),
    transcriptionLanguage: str(input.transcriptionLanguage, d.transcriptionLanguage),
    cleanupModel: str(input.cleanupModel, d.cleanupModel) || d.cleanupModel,
    cleanupFallbackModel: str(input.cleanupFallbackModel, d.cleanupFallbackModel),
    cleanupBaseUrl: str(input.cleanupBaseUrl, d.cleanupBaseUrl),
    cleanupApiKey: str(input.cleanupApiKey, d.cleanupApiKey),
    hedgeDelayMs: num(input.hedgeDelayMs, d.hedgeDelayMs, 200, 10000),
    fastPathEnabled: bool(input.fastPathEnabled, d.fastPathEnabled),
    fastPathMaxWords: clampMaxWords(input.fastPathMaxWords ?? d.fastPathMaxWords),
    chunkedEnabled: bool(input.chunkedEnabled, d.chunkedEnabled),
    outputLanguage: str(input.outputLanguage, d.outputLanguage),
    vocabulary: typeof input.vocabulary === "string" ? input.vocabulary : d.vocabulary,
    customPrompt: typeof input.customPrompt === "string" ? input.customPrompt : d.customPrompt,
    macros,
    keepHistory: bool(input.keepHistory, d.keepHistory),
    restoreClipboard: bool(input.restoreClipboard, d.restoreClipboard),
    launchAtLogin: bool(input.launchAtLogin, d.launchAtLogin),
    startDelayMs: num(input.startDelayMs, d.startDelayMs, 0, 1000),
    hotkeys,
  };
}

/**
 * Merges a patch from the settings UI. Secret fields sent as an empty string keep the
 * stored value; send `null` to clear one.
 */
function applyPatch(current, patch = {}) {
  const merged = { ...current };
  for (const [key, value] of Object.entries(patch)) {
    if (!(key in DEFAULTS)) continue;
    if (SECRET_FIELDS.includes(key)) {
      if (value === null) merged[key] = "";
      else if (typeof value === "string" && value.trim() !== "") merged[key] = value.trim();
      continue;
    }
    merged[key] = value;
  }
  return normalizeSettings(merged);
}

/** What the UI may see: secrets are replaced by a "set" flag. */
function publicSettings(settings) {
  const out = { ...settings };
  for (const key of SECRET_FIELDS) {
    out[`${key}Set`] = Boolean(settings[key]);
    out[key] = "";
  }
  return out;
}

/** Settings in the shape the pipeline and providers consume. */
function runtimeSettings(settings) {
  return {
    ...settings,
    cleanup: {
      primaryModel: settings.cleanupModel,
      fallbackModel: settings.cleanupFallbackModel,
      hedgeDelayMs: settings.hedgeDelayMs,
      baseUrl: (settings.cleanupBaseUrl || OPENROUTER_BASE_URL).replace(/\/+$/, ""),
      apiKey: settings.cleanupApiKey || settings.openRouterKey,
    },
  };
}

function transcriptionConfig(settings) {
  return {
    baseUrl: transcriptionBaseUrl({ model: settings.transcriptionModel, explicitUrl: settings.transcriptionBaseUrl }),
    apiKey: transcriptionApiKey({
      model: settings.transcriptionModel,
      explicitKey: settings.transcriptionApiKey,
      openRouterKey: settings.openRouterKey,
    }),
    model: settings.transcriptionModel,
    language: settings.transcriptionLanguage || undefined,
  };
}

/** Human-readable list of what is still missing before a dictation can work. */
function missingConfiguration(settings) {
  const missing = [];
  if (!transcriptionConfig(settings).apiKey) missing.push("clé API de transcription (OpenRouter)");
  if (!runtimeSettings(settings).cleanup.apiKey) missing.push("clé API du nettoyage (OpenRouter)");
  return missing;
}

module.exports = {
  DEFAULTS,
  SECRET_FIELDS,
  normalizeSettings,
  applyPatch,
  publicSettings,
  runtimeSettings,
  transcriptionConfig,
  missingConfiguration,
};
