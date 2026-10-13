"use strict";

const { hedged } = require("./hedge");
const { shouldSkipCleanup } = require("./fastpath");
const {
  buildDictationSystemPrompt,
  buildDictationUserMessage,
  REWRITE_SYSTEM_PROMPT,
  buildRewriteUserMessage,
  COMMAND_SYSTEM_PROMPT,
  buildCommandUserMessage,
} = require("./prompts");

/** Removes wrapping quotes and the EMPTY sentinel the prompts ask for. */
function sanitizeOutput(text) {
  let out = String(text || "").trim();
  if (/^empty$/i.test(out)) return "";
  const pairs = [['"', '"'], ["«", "»"], ["“", "”"]];
  for (const [open, close] of pairs) {
    if (out.length >= 2 && out.startsWith(open) && out.endsWith(close)) {
      out = out.slice(open.length, out.length - close.length).trim();
      break;
    }
  }
  return out;
}

/** A reply far longer than the input means the model answered instead of cleaning up. */
function looksLikeAnswer(raw, cleaned) {
  return cleaned.length > raw.length * 3 + 120;
}

/**
 * Runs `call(model, signal)` on the primary model, hedged with the fallback model when
 * the primary is slow or failing.
 */
function callWithFallback(call, { primaryModel, fallbackModel, hedgeDelayMs }) {
  const retry = fallbackModel && fallbackModel !== primaryModel ? (signal) => call(fallbackModel, signal) : null;
  return hedged((signal) => call(primaryModel, signal), retry, { delayMs: hedgeDelayMs });
}

/**
 * Cleans up a raw transcript. Never throws: on failure the raw transcript is returned
 * so a dictation is never lost.
 * @returns {Promise<{text:string, outcome:string}>}
 */
async function cleanTranscript(raw, settings, chat) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) return { text: "", outcome: "empty" };

  if (
    settings.fastPathEnabled &&
    shouldSkipCleanup({
      transcript: trimmed,
      outputLanguage: settings.outputLanguage,
      vocabulary: settings.vocabulary,
      customPrompt: settings.customPrompt,
      maxWords: settings.fastPathMaxWords,
    })
  ) {
    return { text: trimmed, outcome: "fast-path" };
  }

  const system = buildDictationSystemPrompt({
    customPrompt: settings.customPrompt,
    vocabulary: settings.vocabulary,
    outputLanguage: settings.outputLanguage,
  });
  const user = buildDictationUserMessage(trimmed);
  try {
    const content = await callWithFallback((model, signal) => chat({ model, system, user, signal }), settings.cleanup);
    const cleaned = sanitizeOutput(content);
    if (!cleaned) return { text: "", outcome: "empty" };
    if (looksLikeAnswer(trimmed, cleaned)) return { text: trimmed, outcome: "suspected-answer" };
    return { text: cleaned, outcome: "cleaned" };
  } catch {
    return { text: trimmed, outcome: "cleanup-failed" };
  }
}

/** Rewrites a selected text. Throws on failure (the selection must stay untouched). */
async function rewriteText(text, settings, chat) {
  const user = buildRewriteUserMessage(text);
  const content = await callWithFallback(
    (model, signal) => chat({ model, system: REWRITE_SYSTEM_PROMPT, user, signal }),
    settings.cleanup
  );
  const cleaned = sanitizeOutput(content);
  if (!cleaned) throw new Error("Le modèle n'a rien renvoyé");
  return cleaned;
}

/** Transforms a selected text according to a spoken instruction. Throws on failure. */
async function transformWithCommand(selectedText, voiceCommand, settings, chat) {
  const user = buildCommandUserMessage(voiceCommand, selectedText);
  const content = await callWithFallback(
    (model, signal) => chat({ model, system: COMMAND_SYSTEM_PROMPT, user, signal }),
    settings.cleanup
  );
  const cleaned = sanitizeOutput(content);
  if (!cleaned) throw new Error("Le modèle n'a rien renvoyé");
  return cleaned;
}

module.exports = {
  sanitizeOutput,
  looksLikeAnswer,
  cleanTranscript,
  rewriteText,
  transformWithCommand,
  callWithFallback,
};
