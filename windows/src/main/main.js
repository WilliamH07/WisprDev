"use strict";

const path = require("node:path");
const { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, screen, session, clipboard, ClipboardItem } = require("electron");

const { DictationPipeline } = require("../core/pipeline");
const { UsageStats } = require("../core/stats");
const { transcribeWav, chatCompletion, prewarm } = require("../core/providers");
const { timeRuns } = require("../core/bench");
const { syntheticSpeechWav } = require("../core/wav");
const { FISH_AUDIO_MODEL, OPENROUTER_BASE_URL } = require("../core/routing");
const {
  publicSettings,
  runtimeSettings,
  transcriptionConfig,
  missingConfiguration,
} = require("../core/settings");
const { SettingsStore, HistoryStore, statsStorage } = require("./store");
const { Hotkeys } = require("./hotkeys");
const { Output } = require("./output");

const SMOKE_TEST = process.argv.includes("--smoke-test");
const ASSETS = path.join(__dirname, "..", "..", "assets");
const RENDERER = path.join(__dirname, "..", "renderer");
const PRELOAD = path.join(__dirname, "..", "preload");

app.setAppUserModelId("com.williamh07.wisper.windows");
if (!SMOKE_TEST && !app.requestSingleInstanceLock()) {
  app.quit();
  process.exit(0);
}

let store;
let history;
let stats;
let pipeline;
let hotkeys;
let output;
let tray;
let appWindow = null;
let overlayWindow = null;
let recorderWindow = null;
let lastTimings = null;
let quitting = false;
let pendingReady = null;
let pendingStopped = null;

function log(...args) {
  console.log("[wisper]", ...args);
}

// ---- Windows ----------------------------------------------------------------------------
function secureWebPreferences(preloadFile) {
  return {
    preload: path.join(PRELOAD, preloadFile),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
    backgroundThrottling: false,
  };
}

function createRecorderWindow() {
  recorderWindow = new BrowserWindow({ show: false, width: 200, height: 100, webPreferences: secureWebPreferences("recorder.js") });
  recorderWindow.loadFile(path.join(RENDERER, "recorder.html"));
}

function createOverlayWindow() {
  const { workArea } = screen.getPrimaryDisplay();
  const width = 360;
  const height = 64;
  overlayWindow = new BrowserWindow({
    width,
    height,
    x: Math.round(workArea.x + (workArea.width - width) / 2),
    y: workArea.y + workArea.height - height - 12,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    focusable: false, // never steal focus: the text must be pasted into the app the user is in
    skipTaskbar: true,
    alwaysOnTop: true,
    show: false,
    hasShadow: false,
    webPreferences: secureWebPreferences("overlay.js"),
  });
  overlayWindow.setAlwaysOnTop(true, "screen-saver");
  overlayWindow.setIgnoreMouseEvents(true);
  overlayWindow.loadFile(path.join(RENDERER, "overlay.html"));
}

function openAppWindow(view) {
  if (appWindow) {
    appWindow.show();
    appWindow.focus();
    return;
  }
  appWindow = new BrowserWindow({
    width: 1000,
    height: 700,
    minWidth: 760,
    minHeight: 520,
    title: "Wisper",
    icon: path.join(ASSETS, "icon.png"),
    backgroundColor: "#f6f5f1",
    autoHideMenuBar: true,
    webPreferences: secureWebPreferences("app.js"),
  });
  appWindow.removeMenu();
  appWindow.loadFile(path.join(RENDERER, "app.html"));
  appWindow.on("close", (event) => {
    if (!quitting) {
      event.preventDefault();
      appWindow.hide(); // keep dictating from the tray
    }
  });
  appWindow.on("closed", () => {
    appWindow = null;
  });
  if (view) appWindow.webContents.once("did-finish-load", () => appWindow.webContents.executeJavaScript(`document.querySelector('[data-view="${view}"]').click()`));
}

function sendToApp(channel, payload) {
  if (appWindow && !appWindow.isDestroyed()) appWindow.webContents.send(channel, payload);
}

// ---- Overlay & UI -----------------------------------------------------------------------
function overlay(payload) {
  if (!overlayWindow || overlayWindow.isDestroyed()) return;
  if (payload.type === "text") overlayWindow.showInactive();
  overlayWindow.webContents.send("overlay-update", payload);
}

const ui = {
  state(state) {
    sendToApp("state", state);
    if (state === "recording") overlay({ type: "text", style: "recording", text: "Écoute…" });
    else if (state === "transcribing") overlay({ type: "text", style: "working", text: "Transcription…" });
    else if (state === "rewriting") overlay({ type: "text", style: "working", text: "Réécriture…" });
    if (tray) tray.setToolTip(state === "idle" ? "Wisper" : `Wisper — ${state}`);
  },
  level(level) {
    overlay({ type: "level", level });
  },
  message(text, kind) {
    const style = kind === "error" ? "error" : kind === "success" ? "success" : "working";
    overlay({ type: "text", style, text, autoHideMs: kind === "error" ? 3500 : 1600 });
  },
  timings(timings) {
    lastTimings = timings;
    sendToApp("timings", timings);
  },
};

// ---- Recorder bridge --------------------------------------------------------------------
function waitFor(setter, timeoutMs, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      setter(null);
      reject(new Error(message));
    }, timeoutMs);
    setter({
      resolve: () => {
        clearTimeout(timer);
        setter(null);
        resolve();
      },
      reject: (error) => {
        clearTimeout(timer);
        setter(null);
        reject(error);
      },
    });
  });
}

const recorder = {
  async start() {
    const ready = waitFor((v) => (pendingReady = v), 4000, "le micro ne répond pas");
    recorderWindow.webContents.send("rec-start");
    await ready;
  },
  async stop() {
    const stopped = waitFor((v) => (pendingStopped = v), 1500, "arrêt du micro trop long");
    recorderWindow.webContents.send("rec-stop");
    await stopped;
  },
};

ipcMain.on("rec-audio", (_event, buffer) => {
  if (pipeline) pipeline.pushAudio(new Int16Array(buffer));
});
ipcMain.on("rec-ready", () => pendingReady && pendingReady.resolve());
ipcMain.on("rec-stopped", () => pendingStopped && pendingStopped.resolve());
ipcMain.on("rec-error", (_event, message) => pendingReady && pendingReady.reject(new Error(message)));

// ---- Pipeline wiring --------------------------------------------------------------------
function currentRuntime() {
  return runtimeSettings(store.get());
}

function warnIfNotConfigured() {
  const missing = missingConfiguration(store.get());
  if (missing.length === 0) return false;
  ui.message(`Il manque : ${missing[0]}`, "error");
  openAppWindow("settings");
  return true;
}

function setupPipeline() {
  stats = new UsageStats(statsStorage());
  history = new HistoryStore();
  hotkeys = new Hotkeys({
    getSettings: () => store.get(),
    onStart: (mode) => {
      if (warnIfNotConfigured()) return;
      const runtime = currentRuntime();
      prewarm([transcriptionConfig(store.get()).baseUrl, runtime.cleanup.baseUrl]);
      pipeline.begin(mode);
    },
    onStop: () => pipeline.end(),
    onCancel: () => pipeline.cancel(),
    onRewrite: () => {
      if (!warnIfNotConfigured()) pipeline.rewriteSelection();
    },
    log,
  });
  output = new Output({ getSettings: () => store.get(), hotkeys });
  pipeline = new DictationPipeline({
    now: Date.now,
    getSettings: currentRuntime,
    recorder,
    transcribe: (wav) => transcribeWav(transcriptionConfig(store.get()), wav),
    chat: (options) => chatCompletion(options),
    output,
    stats,
    history,
    ui,
  });
}

// ---- IPC for the app window -------------------------------------------------------------
function setupIpc() {
  ipcMain.handle("settings:get", () => publicSettings(store.get()));
  ipcMain.handle("settings:save", (_event, patch) => {
    const before = JSON.stringify(store.get().hotkeys);
    const next = store.update(patch || {});
    if (JSON.stringify(next.hotkeys) !== before && hotkeys.matchers) hotkeys.rebuild();
    if (patch && "launchAtLogin" in patch) app.setLoginItemSettings({ openAtLogin: next.launchAtLogin });
    return publicSettings(next);
  });
  ipcMain.handle("stats:get", (_event, { days } = {}) => stats.snapshot(new Date(), [14, 30, 90].includes(days) ? days : 30));
  ipcMain.handle("stats:reset", () => stats.reset());
  ipcMain.handle("history:get", () => history.list());
  ipcMain.handle("history:clear", () => history.clear());
  ipcMain.handle("history:copy", async (_event, index) => {
    const entry = history.list()[index];
    if (entry) await clipboard.writeText(entry.text);
  });
  ipcMain.handle("timings:last", () => lastTimings);
  ipcMain.handle("hotkey:capture", () => hotkeys.capture());

  ipcMain.handle("bench:transcription", async () => {
    const settings = store.get();
    const wav = syntheticSpeechWav(4, 16000);
    const candidates = [];
    const fish = { ...transcriptionConfig({ ...settings, transcriptionModel: FISH_AUDIO_MODEL }), label: `openrouter.ai · ${FISH_AUDIO_MODEL}` };
    if (fish.apiKey) candidates.push(fish);
    const current = transcriptionConfig(settings);
    if (current.apiKey && current.model !== FISH_AUDIO_MODEL) candidates.push({ ...current, label: `${new URL(current.baseUrl).host} · ${current.model}` });
    return runBench(candidates, (c) => transcribeWav(c, wav), 4);
  });

  ipcMain.handle("bench:cleanup", async () => {
    const settings = store.get();
    const runtime = runtimeSettings(settings);
    if (!runtime.cleanup.apiKey) return [];
    const models = [...new Set([settings.cleanupModel, settings.cleanupFallbackModel, "openai/gpt-oss-20b", "google/gemini-2.5-flash", "google/gemini-2.5-flash-lite"].filter(Boolean))];
    const { DICTATION_SYSTEM_PROMPT } = require("../core/prompts");
    const user = "Transcription vocale brute à formater :\neuh donc en fait je voulais dire que le déploiement est prévu demain matin et que on doit vérifier la config avant";
    const candidates = models.map((model) => ({ model, label: `${new URL(runtime.cleanup.baseUrl).host} · ${model}`, baseUrl: runtime.cleanup.baseUrl, apiKey: runtime.cleanup.apiKey }));
    return runBench(candidates, (c) => chatCompletion({ baseUrl: c.baseUrl, apiKey: c.apiKey, model: c.model, system: DICTATION_SYSTEM_PROMPT, user }), 6);
  });
}

async function runBench(candidates, call, runs) {
  const results = [];
  for (const candidate of candidates) {
    try {
      const timing = await timeRuns(() => call(candidate), runs);
      results.push({ label: candidate.label, model: candidate.model, ...timing });
    } catch (error) {
      results.push({ label: candidate.label, model: candidate.model, error: error.message });
    }
  }
  return results;
}

// ---- Tray -------------------------------------------------------------------------------
function createTray() {
  tray = new Tray(nativeImage.createFromPath(path.join(ASSETS, "tray.png")));
  tray.setToolTip("Wisper");
  const menu = Menu.buildFromTemplate([
    { label: "Ouvrir Wisper", click: () => openAppWindow() },
    { label: "Copier la dernière dictée", click: () => output && output.copyLast() },
    { type: "separator" },
    { label: "Quitter", click: () => { quitting = true; app.quit(); } },
  ]);
  tray.setContextMenu(menu);
  tray.on("click", () => openAppWindow());
}

// ---- Lifecycle --------------------------------------------------------------------------
app.on("second-instance", () => openAppWindow());
app.on("window-all-closed", (event) => event.preventDefault()); // stay in the tray
app.on("before-quit", () => {
  quitting = true;
  if (hotkeys) hotkeys.stop();
});

app.whenReady().then(async () => {
  // Only the hidden recorder may use the microphone.
  session.defaultSession.setPermissionRequestHandler((webContents, permission, callback) => {
    callback(permission === "media" && webContents === (recorderWindow && recorderWindow.webContents));
  });

  store = new SettingsStore();
  setupPipeline();
  setupIpc();
  createRecorderWindow();
  createOverlayWindow();
  createTray();

  let hotkeyError = null;
  try {
    hotkeys.start();
  } catch (error) {
    hotkeyError = error;
    log("global shortcuts unavailable:", error.message);
  }

  if (store.get().launchAtLogin) app.setLoginItemSettings({ openAtLogin: true });

  if (SMOKE_TEST) {
    openAppWindow();
    appWindow.webContents.once("did-finish-load", async () => {
      try {
        await smokeTest();
        log("smoke test ok", hotkeyError ? `(shortcuts: ${hotkeyError.message})` : "");
        quitting = true;
        app.exit(0);
      } catch (error) {
        log("smoke test FAILED:", error.stack || error.message);
        quitting = true;
        app.exit(1);
      }
    });
    appWindow.webContents.once("did-fail-load", (_e, code, description) => {
      log("smoke test FAILED:", description);
      app.exit(1);
    });
    return;
  }

  if (missingConfiguration(store.get()).length > 0 || hotkeyError) openAppWindow("settings");
  else ui.message("Wisper est prêt — maintenez Ctrl + Win pour dicter", "success");
});

/**
 * Dev/CI check: exercises the UI through the real IPC and optionally saves screenshots
 * (WISPER_SCREENSHOT_DIR) with synthetic statistics (WISPER_SEED=1). Never used in normal runs.
 */
async function smokeTest() {
  const fs = require("node:fs");
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const run = (code) => appWindow.webContents.executeJavaScript(code);
  await wait(800);

  if (process.env.WISPER_SEED === "1") {
    const now = new Date();
    for (let i = 0; i < 24; i += 1) {
      const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i, 12);
      stats.record({ wordCount: 120 + ((i * 53) % 260), speakingSeconds: 55 + ((i * 17) % 90), now: day });
    }
    lastTimings = { audioFinalizeMs: 68, transcriptionMs: 717, cleanupMs: 940, skippedCleanup: false, engine: `${FISH_AUDIO_MODEL} · par morceaux (3)` };
    history.add({ timestamp: new Date().toISOString(), mode: "dictation", raw: "x", text: "Exemple de texte dicté pour la capture d'écran.", outcome: "cleaned", engine: "demo", totalMs: 1620 });
  }

  const settings = await run("window.wisper.invoke('settings:get')");
  if (!settings || !settings.hotkeys || settings.hotkeys.dictate.join("+") !== "Ctrl+Meta") throw new Error("settings:get returned unexpected data");
  const snapshot = await run("window.wisper.invoke('stats:get', { days: 30 })");
  if (!snapshot || snapshot.recentDays.length !== 30) throw new Error("stats:get returned unexpected data");

  await smokeNetworkAndClipboard();

  const dir = process.env.WISPER_SCREENSHOT_DIR;
  for (const view of ["home", "history", "settings"]) {
    await run(`document.querySelector('[data-view="${view}"]').click()`);
    await wait(700);
    const errors = await run("document.querySelectorAll('.error').length");
    if (errors) throw new Error(`UI error on view ${view}`);
    if (dir) {
      fs.mkdirSync(dir, { recursive: true });
      const image = await appWindow.webContents.capturePage();
      fs.writeFileSync(path.join(dir, `${view}.png`), image.toPNG());
    }
  }
}

/** Real fetch against a local fake provider, and the real Electron clipboard. */
async function smokeNetworkAndClipboard() {
  const http = require("node:http");
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      seen.push({ url: req.url, auth: req.headers.authorization, type: req.headers["content-type"], body });
      res.setHeader("Content-Type", "application/json");
      if (req.url.endsWith("/audio/transcriptions")) res.end(JSON.stringify({ text: " bonjour le monde " }));
      else res.end(JSON.stringify({ choices: [{ message: { content: "Bonjour le monde." } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}/v1`;
  try {
    const text = await transcribeWav({ baseUrl: base, apiKey: "test-key", model: FISH_AUDIO_MODEL, language: "fr" }, syntheticSpeechWav(1, 16000));
    if (text !== "bonjour le monde") throw new Error(`transcription parsed wrong: ${text}`);
    const first = seen[0];
    if (!first.type.startsWith("multipart/form-data")) throw new Error("transcription is not multipart");
    const raw = first.body.toString("latin1");
    for (const needle of ['name="model"', FISH_AUDIO_MODEL, 'name="file"', 'name="language"', "RIFF"]) {
      if (!raw.includes(needle)) throw new Error(`multipart body is missing ${needle}`);
    }
    if (first.auth !== "Bearer test-key") throw new Error("missing bearer header");

    const reply = await chatCompletion({ baseUrl: base, apiKey: "test-key", model: "openai/gpt-oss-20b", system: "s", user: "u" });
    if (reply !== "Bonjour le monde.") throw new Error("chat parsed wrong");
    const second = JSON.parse(seen[1].body.toString("utf8"));
    if (second.model !== "openai/gpt-oss-20b" || second.messages.length !== 2) throw new Error("chat payload wrong");
  } finally {
    server.close();
  }

  // Clipboard: pasting writes the text; a copy with nothing selected leaves the sentinel, i.e. "none".
  await clipboard.writeText("contenu d'origine");
  const selection = await output.captureSelection();
  if (selection.kind !== "none") throw new Error("a probe with no selection must report none");
  if ((await clipboard.readText()) !== "contenu d'origine") throw new Error("clipboard was not restored after the selection probe");

  // Rich content must survive a probe too (text + html).
  await clipboard.write([new ClipboardItem({ "text/plain": "riche", "text/html": "<b>riche</b>" })]);
  await output.captureSelection();
  const restored = await clipboard.read();
  const types = restored.flatMap((item) => item.types);
  if (!types.includes("text/html")) throw new Error("rich clipboard content was lost after the selection probe");
}
