"use strict";

const $ = (id) => document.getElementById(id);
const api = window.wisper;

let settings = null;
let rangeDays = 30;
let chartDays = [];

const fmtInt = (n) => Number(n).toLocaleString("fr-FR");
const fmtMs = (ms) => (ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`);
const fmtMinutes = (m) => (m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`);
const chordLabel = (names) => names.map((n) => ({ Meta: "Win", Shift: "Maj" }[n] || n)).join(" + ");

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// ---- Navigation -------------------------------------------------------------------------
document.querySelectorAll(".nav").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("active", b === button));
    document.querySelectorAll(".view").forEach((v) => (v.hidden = v.id !== `view-${button.dataset.view}`));
    if (button.dataset.view === "home") refreshHome();
    if (button.dataset.view === "history") refreshHistory();
  });
});

// ---- Home -------------------------------------------------------------------------------
function tile(label, value, signal) {
  const t = el("div", "tile");
  t.append(el("div", "label", label), el("div", `v${signal ? " signal" : ""}`, value));
  return t;
}

function drawChart(days) {
  chartDays = days;
  const host = $("chart");
  host.textContent = "";
  const width = 760;
  const height = 170;
  const pad = { left: 36, right: 8, top: 10, bottom: 22 };
  const max = Math.max(1, ...days.map((d) => d.words));
  const x = (i) => pad.left + (i * (width - pad.left - pad.right)) / Math.max(1, days.length - 1);
  const y = (v) => pad.top + (1 - v / max) * (height - pad.top - pad.bottom);
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("preserveAspectRatio", "none");

  const make = (name, attrs) => {
    const node = document.createElementNS(ns, name);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    return node;
  };
  for (const frac of [0, 0.5, 1]) {
    const gy = y(max * frac);
    svg.append(make("line", { x1: pad.left, x2: width - pad.right, y1: gy, y2: gy, stroke: "currentColor", "stroke-opacity": "0.1" }));
    const label = make("text", { x: 2, y: gy + 4, "font-size": "10", fill: "currentColor", "fill-opacity": "0.55", "font-family": "Consolas, monospace" });
    label.textContent = fmtInt(Math.round(max * frac));
    svg.append(label);
  }
  const points = days.map((d, i) => `${x(i)},${y(d.words)}`);
  if (points.length > 1) {
    svg.append(make("polygon", { points: `${x(0)},${y(0)} ${points.join(" ")} ${x(days.length - 1)},${y(0)}`, fill: "currentColor", "fill-opacity": "0.08" }));
    svg.append(make("polyline", { points: points.join(" "), fill: "none", stroke: "currentColor", "stroke-width": "1.5", "vector-effect": "non-scaling-stroke" }));
  }
  const cursor = make("circle", { r: 4, fill: "#ee4b2b", visibility: "hidden" });
  svg.append(cursor);
  svg.addEventListener("mousemove", (event) => {
    const rect = svg.getBoundingClientRect();
    const px = ((event.clientX - rect.left) / rect.width) * width;
    const i = Math.max(0, Math.min(days.length - 1, Math.round(((px - pad.left) / (width - pad.left - pad.right)) * (days.length - 1))));
    cursor.setAttribute("cx", x(i));
    cursor.setAttribute("cy", y(days[i].words));
    cursor.setAttribute("visibility", "visible");
    $("chartReadout").textContent = `${days[i].date} · ${fmtInt(days[i].words)} mots`;
  });
  svg.addEventListener("mouseleave", () => {
    cursor.setAttribute("visibility", "hidden");
    updateReadout();
  });
  host.append(svg);
  updateReadout();
}

function updateReadout() {
  const total = chartDays.reduce((n, d) => n + d.words, 0);
  $("chartReadout").textContent = `${fmtInt(total)} mots sur ${rangeDays} jours`;
}

function renderLatency(timings) {
  const box = $("latency");
  box.textContent = "";
  if (!timings) {
    box.className = "muted";
    box.textContent = "Faites une dictée pour voir où part le temps.";
    return;
  }
  box.className = "";
  const total = (timings.audioFinalizeMs || 0) + (timings.transcriptionMs || 0) + (timings.cleanupMs || 0);
  const totalEl = el("div", "mono", fmtMs(total));
  totalEl.style.fontSize = "24px";
  box.append(totalEl);
  if (timings.engine) box.append(el("div", "muted small mono", timings.engine));
  const rows = [
    ["Finalisation audio", fmtMs(timings.audioFinalizeMs || 0)],
    ["Transcription", fmtMs(timings.transcriptionMs || 0)],
    ["Nettoyage IA", timings.skippedCleanup ? "ignoré (phrase courte)" : fmtMs(timings.cleanupMs || 0)],
  ];
  for (const [k, v] of rows) {
    const row = el("div", "kv");
    row.append(el("span", "muted", k), el("span", "mono", v));
    box.append(row);
  }
}

async function refreshHome() {
  const snap = await api.invoke("stats:get", { days: rangeDays });
  $("heroWords").textContent = fmtInt(snap.totalWords);
  $("heroSub").textContent = snap.totalWords > 0
    ? `mots dictés, soit environ ${fmtMinutes(snap.minutesSaved)} gagnées par rapport à la frappe.`
    : "mots dictés pour l'instant.";
  const tiles = $("tiles");
  tiles.textContent = "";
  if (snap.totalDictations > 0) {
    tiles.append(
      tile("Dictées", fmtInt(snap.totalDictations)),
      tile("Vitesse", `${snap.averageWordsPerMinute} mots/min`),
      tile("Temps gagné", fmtMinutes(snap.minutesSaved)),
      tile("Série en cours", `${snap.currentStreak} j`, snap.currentStreak > 0),
      tile("Meilleure série", `${snap.bestStreak} j`)
    );
  }
  drawChart(snap.recentDays);
  renderLatency(await api.invoke("timings:last"));
}

$("rangeSeg").addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (!button) return;
  rangeDays = Number(button.dataset.days);
  $("rangeSeg").querySelectorAll("button").forEach((b) => b.classList.toggle("on", b === button));
  refreshHome();
});

$("resetStats").addEventListener("click", async () => {
  if (confirm("Réinitialiser toutes les statistiques ?")) {
    await api.invoke("stats:reset");
    refreshHome();
  }
});

function renderBench(target, results, useModel) {
  target.textContent = "";
  target.className = "";
  const best = results
    .filter((r) => !r.error && r.medianMs != null && !r.erratic)
    .sort((a, b) => a.medianMs - b.medianMs)[0];
  for (const r of results) {
    const row = el("div", "bench-row");
    const left = el("div");
    left.append(el("div", "", r.label));
    if (r.error) left.append(el("div", "small signal-text", r.error));
    else left.append(el("div", `small mono ${r.erratic ? "signal-text" : "muted"}`, `1re requête ${fmtMs(r.coldMs)} · pire cas ${fmtMs(r.worstMs)}${r.erratic ? " · irrégulier" : ""}`));
    const right = el("div", "row");
    if (!r.error) {
      right.append(el("span", `mono${r === best ? " signal-text" : ""}`, fmtMs(r.medianMs)));
      if (settings && useModel.isActive(settings, r)) right.append(el("span", "muted small", "actif"));
      else {
        const button = el("button", `pill${r === best ? " action" : ""}`, "Utiliser");
        button.addEventListener("click", async () => {
          settings = await api.invoke("settings:save", useModel.patch(r));
          renderBench(target, results, useModel);
          fillSettings();
        });
        right.append(button);
      }
    }
    row.append(left, right);
    target.append(row);
  }
}

$("benchTranscribe").addEventListener("click", async () => {
  const button = $("benchTranscribe");
  button.disabled = true;
  button.textContent = "Mesure en cours…";
  $("benchTranscribeOut").textContent = "…";
  try {
    const results = await api.invoke("bench:transcription");
    renderBench($("benchTranscribeOut"), results, {
      isActive: (s, r) => s.transcriptionModel === r.model,
      patch: (r) => ({ transcriptionModel: r.model }),
    });
  } finally {
    button.disabled = false;
    button.textContent = "Tester";
  }
});

$("benchCleanup").addEventListener("click", async () => {
  const button = $("benchCleanup");
  button.disabled = true;
  button.textContent = "Mesure en cours…";
  $("benchCleanupOut").textContent = "…";
  try {
    const results = await api.invoke("bench:cleanup");
    renderBench($("benchCleanupOut"), results, {
      isActive: (s, r) => s.cleanupModel === r.model,
      patch: (r) => ({ cleanupModel: r.model }),
    });
  } finally {
    button.disabled = false;
    button.textContent = "Tester";
  }
});

// ---- History ----------------------------------------------------------------------------
async function refreshHistory() {
  const list = $("historyList");
  list.textContent = "";
  const entries = await api.invoke("history:get");
  if (!entries.length) {
    list.append(el("p", "muted", "Aucune dictée enregistrée."));
    return;
  }
  const card = el("div", "card");
  entries.forEach((entry, index) => {
    const box = el("div", "entry");
    const meta = el("div", "meta");
    meta.append(
      el("span", "", new Date(entry.timestamp).toLocaleString("fr-FR")),
      el("span", "mono", fmtMs(entry.totalMs || 0)),
      el("span", "", entry.mode === "edit" ? "Édition" : "Dictée")
    );
    const copy = el("button", "pill", "Copier");
    copy.addEventListener("click", async () => {
      await api.invoke("history:copy", index);
      copy.textContent = "Copié";
      setTimeout(() => (copy.textContent = "Copier"), 1500);
    });
    box.append(meta, el("div", "", entry.text), copy);
    card.append(box);
  });
  list.append(card);
}

$("clearHistory").addEventListener("click", async () => {
  if (confirm("Effacer tout l'historique ?")) {
    await api.invoke("history:clear");
    refreshHistory();
  }
});

// ---- Settings ---------------------------------------------------------------------------
const TEXT_FIELDS = ["transcriptionModel", "transcriptionLanguage", "cleanupModel", "cleanupFallbackModel", "outputLanguage", "vocabulary", "customPrompt"];
const CHECK_FIELDS = ["chunkedEnabled", "fastPathEnabled", "keepHistory", "restoreClipboard", "launchAtLogin"];
const HOTKEY_ACTIONS = [
  ["dictate", "Dicter (maintenir)"],
  ["edit", "Modifier le texte sélectionné à la voix (maintenir)"],
  ["rewrite", "Réécrire le texte sélectionné (appui)"],
];

function macrosToText(macros) {
  return macros.map((m) => `${m.trigger} => ${m.payload}`).join("\n");
}

function textToMacros(text) {
  return text
    .split("\n")
    .map((line) => line.split("=>"))
    .filter((parts) => parts.length >= 2 && parts[0].trim())
    .map((parts) => ({ trigger: parts[0].trim(), payload: parts.slice(1).join("=>").trim() }));
}

function fillSettings() {
  for (const f of TEXT_FIELDS) $(f).value = settings[f] ?? "";
  for (const f of CHECK_FIELDS) $(f).checked = Boolean(settings[f]);
  $("hedgeDelayMs").value = settings.hedgeDelayMs;
  $("fastPathMaxWords").value = settings.fastPathMaxWords;
  $("fastPathLabel").textContent = settings.fastPathMaxWords;
  $("macros").value = macrosToText(settings.macros || []);
  $("keyState").textContent = settings.openRouterKeySet ? "· enregistrée" : "· manquante";
  $("openRouterKey").value = "";
  renderHotkeys();
}

function renderHotkeys() {
  const host = $("hotkeyRows");
  host.textContent = "";
  for (const [action, title] of HOTKEY_ACTIONS) {
    const row = el("div", "kv");
    row.append(el("span", "", title));
    const right = el("div", "row");
    right.append(el("span", "mono", chordLabel(settings.hotkeys[action])));
    const button = el("button", "pill", "Modifier");
    button.addEventListener("click", async () => {
      button.textContent = "Appuyez sur la combinaison…";
      button.disabled = true;
      const names = await api.invoke("hotkey:capture");
      button.disabled = false;
      if (names && names.length > 0) {
        settings = await api.invoke("settings:save", { hotkeys: { ...settings.hotkeys, [action]: names } });
      }
      renderHotkeys();
    });
    right.append(button);
    row.append(right);
    host.append(row);
  }
}

let saveTimer = null;
function save(patch) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    settings = await api.invoke("settings:save", patch);
    $("keyState").textContent = settings.openRouterKeySet ? "· enregistrée" : "· manquante";
  }, 250);
}

for (const f of TEXT_FIELDS) $(f).addEventListener("input", () => save({ [f]: $(f).value }));
for (const f of CHECK_FIELDS) $(f).addEventListener("change", () => save({ [f]: $(f).checked }));
$("hedgeDelayMs").addEventListener("input", () => save({ hedgeDelayMs: Number($("hedgeDelayMs").value) }));
$("fastPathMaxWords").addEventListener("input", () => {
  $("fastPathLabel").textContent = $("fastPathMaxWords").value;
  save({ fastPathMaxWords: Number($("fastPathMaxWords").value) });
});
$("macros").addEventListener("input", () => save({ macros: textToMacros($("macros").value) }));
$("openRouterKey").addEventListener("input", () => save({ openRouterKey: $("openRouterKey").value }));
$("clearKey").addEventListener("click", async () => {
  settings = await api.invoke("settings:save", { openRouterKey: null });
  fillSettings();
});

// ---- Live state -------------------------------------------------------------------------
api.on("state", (state) => {
  $("liveDot").classList.toggle("live", state === "recording");
  const labels = { recording: "Écoute en cours", transcribing: "Transcription…", rewriting: "Réécriture…" };
  $("stateLabel").textContent = labels[state] || "Accueil";
  $("stateLabel").classList.toggle("signal-text", state === "recording");
});
api.on("timings", (timings) => {
  renderLatency(timings);
  refreshHome();
});

(async function init() {
  settings = await api.invoke("settings:get");
  fillSettings();
  refreshHome();
})();
