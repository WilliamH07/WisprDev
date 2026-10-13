"use strict";

/**
 * Selection detection on Windows without UI Automation: write a unique sentinel to the
 * clipboard, send Ctrl+C, and see whether the clipboard changed. If nothing is selected
 * the sentinel is still there, so we know for certain nothing was selected, instead of
 * rewriting stale clipboard text.
 */
function makeSentinel() {
  const random = Math.random().toString(36).slice(2) + Date.now().toString(36);
  return `\u200b__wisper_probe_${random}__\u200b`;
}

/** @returns {{kind:"selected", text:string} | {kind:"none"}} */
function interpretCopyResult(sentinel, clipboardAfter) {
  if (typeof clipboardAfter !== "string") return { kind: "none" };
  if (clipboardAfter === sentinel) return { kind: "none" };
  const trimmed = clipboardAfter.trim();
  if (!trimmed) return { kind: "none" };
  return { kind: "selected", text: trimmed };
}

module.exports = { makeSentinel, interpretCopyResult };
