"use strict";

function normalize(text) {
  return String(text)
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const ENTER_PHRASES = ["appuie sur entree", "appuyez sur entree", "press enter", "presse entree"];

/** Detects a trailing "press enter" voice command and strips it from the text. */
function parseTranscriptCommands(text) {
  const original = String(text || "").trim();
  const lowered = normalize(original);
  for (const phrase of ENTER_PHRASES) {
    if (lowered === phrase) return { text: "", pressEnter: true };
    if (lowered.endsWith(` ${phrase}`)) {
      // Cut the same number of trailing words from the original text.
      const wordsToDrop = phrase.split(" ").length;
      const words = original.split(/\s+/);
      return { text: words.slice(0, Math.max(0, words.length - wordsToDrop)).join(" ").replace(/[,;:\s]+$/, ""), pressEnter: true };
    }
  }
  return { text: original, pressEnter: false };
}

/** A voice macro fires when the whole utterance equals its trigger phrase. */
function findMacro(text, macros = []) {
  const spoken = normalize(text);
  if (!spoken) return null;
  return macros.find((m) => m && m.trigger && normalize(m.trigger) === spoken) || null;
}

module.exports = { parseTranscriptCommands, findMacro, normalize };
