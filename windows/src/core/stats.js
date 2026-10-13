"use strict";

// Content-free usage counters: words, dictations and speaking time per day. No text is stored.

function dayKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function addDays(date, days) {
  const copy = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  copy.setDate(copy.getDate() + days);
  return copy;
}

function countWords(text) {
  return String(text).split(/\s+/).filter(Boolean).length;
}

function computeSnapshot(days, now = new Date(), recentDayCount = 30) {
  let totalDictations = 0;
  let totalWords = 0;
  let totalSpeakingSeconds = 0;
  for (const usage of Object.values(days)) {
    totalDictations += usage.dictations || 0;
    totalWords += usage.words || 0;
    totalSpeakingSeconds += usage.speakingSeconds || 0;
  }

  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const recentDays = [];
  for (let offset = recentDayCount - 1; offset >= 0; offset -= 1) {
    const day = addDays(today, -offset);
    recentDays.push({ date: dayKey(day), words: days[dayKey(day)]?.words || 0 });
  }

  const active = new Set(Object.entries(days).filter(([, u]) => (u.dictations || 0) > 0).map(([k]) => k));
  let cursor = today;
  if (!active.has(dayKey(cursor))) cursor = addDays(cursor, -1); // streak survives until today's first dictation
  let currentStreak = 0;
  while (active.has(dayKey(cursor))) {
    currentStreak += 1;
    cursor = addDays(cursor, -1);
  }

  let bestStreak = 0;
  let run = 0;
  let previous = null;
  for (const key of [...active].sort()) {
    const [y, m, d] = key.split("-").map(Number);
    const date = new Date(y, m - 1, d);
    run = previous && dayKey(addDays(previous, 1)) === key ? run + 1 : 1;
    bestStreak = Math.max(bestStreak, run);
    previous = date;
  }

  const averageWordsPerMinute =
    totalSpeakingSeconds >= 1 ? Math.round(totalWords / (totalSpeakingSeconds / 60)) : 0;
  const typingMinutes = totalWords / 40;
  const minutesSaved = Math.max(0, Math.round(typingMinutes - totalSpeakingSeconds / 60));

  return {
    totalDictations,
    totalWords,
    totalSpeakingSeconds,
    averageWordsPerMinute,
    minutesSaved,
    currentStreak,
    bestStreak,
    recentDays,
  };
}

class UsageStats {
  /** @param {{read:()=>object, write:(data:object)=>void}} storage */
  constructor(storage, { retentionDays = 400 } = {}) {
    this.storage = storage;
    this.retentionDays = retentionDays;
  }

  _load() {
    try {
      const data = this.storage.read();
      return data && typeof data === "object" && data.days ? data : { days: {} };
    } catch {
      return { days: {} };
    }
  }

  record({ wordCount, speakingSeconds, now = new Date() }) {
    if (!(wordCount > 0)) return;
    const data = this._load();
    const key = dayKey(now);
    const usage = data.days[key] || { dictations: 0, words: 0, speakingSeconds: 0 };
    usage.dictations += 1;
    usage.words += wordCount;
    usage.speakingSeconds += Math.max(0, speakingSeconds || 0);
    data.days[key] = usage;
    const cutoff = dayKey(addDays(now, -this.retentionDays));
    for (const k of Object.keys(data.days)) if (k < cutoff) delete data.days[k];
    this.storage.write(data);
  }

  snapshot(now = new Date(), recentDayCount = 30) {
    return computeSnapshot(this._load().days, now, recentDayCount);
  }

  reset() {
    this.storage.write({ days: {} });
  }
}

module.exports = { UsageStats, computeSnapshot, dayKey, countWords };
