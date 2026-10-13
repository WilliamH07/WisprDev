"use strict";

/** Per-stage latency of one dictation, in milliseconds. Durations only, never content. */
function formatDuration(ms) {
  return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;
}

function totalMs(t) {
  return (t.audioFinalizeMs || 0) + (t.transcriptionMs || 0) + (t.cleanupMs || 0);
}

module.exports = { formatDuration, totalMs };
