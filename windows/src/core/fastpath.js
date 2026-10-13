"use strict";

const DEFAULT_MAX_WORDS = 6;
const MAX_WORDS_RANGE = [3, 40];

function clampMaxWords(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_MAX_WORDS;
  return Math.min(Math.max(Math.round(n), MAX_WORDS_RANGE[0]), MAX_WORDS_RANGE[1]);
}

function wordCount(text) {
  return String(text).split(/\s+/).filter(Boolean).length;
}

/**
 * Short, plain utterances skip the LLM round-trip: speech-to-text output is already
 * punctuated, so the extra network call mostly adds delay.
 */
function shouldSkipCleanup({ transcript, outputLanguage = "", vocabulary = "", customPrompt = "", maxWords }) {
  const trimmed = String(transcript || "").trim();
  if (!trimmed) return false;
  if (outputLanguage.trim() || vocabulary.trim() || customPrompt.trim()) return false;
  return wordCount(trimmed) <= clampMaxWords(maxWords);
}

module.exports = { shouldSkipCleanup, clampMaxWords, wordCount, DEFAULT_MAX_WORDS, MAX_WORDS_RANGE };
