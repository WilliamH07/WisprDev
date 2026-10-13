"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { DictationPipeline } = require("../src/core/pipeline");
const { UsageStats } = require("../src/core/stats");
const { RATE, tone, silence, concat, sleep } = require("./helpers");

function memoryStorage() {
  let data = null;
  return { read: () => data, write: (d) => { data = JSON.parse(JSON.stringify(d)); } };
}

function makeSettings(overrides = {}) {
  return {
    chunkedEnabled: true,
    fastPathEnabled: true,
    fastPathMaxWords: 6,
    outputLanguage: "",
    vocabulary: "",
    customPrompt: "",
    macros: [],
    keepHistory: true,
    transcriptionModel: "fish-audio/transcribe-1",
    cleanup: { primaryModel: "primary", fallbackModel: "backup", hedgeDelayMs: 40, baseUrl: "https://x.test/v1", apiKey: "k" },
    ...overrides,
  };
}

function harness({ settings = makeSettings(), transcribe, chat, selection } = {}) {
  const log = { pasted: [], messages: [], states: [], history: [], transcribeCalls: 0, chatCalls: [] };
  const deps = {
    now: () => Date.now(),
    getSettings: () => settings,
    recorder: { start: async () => {}, stop: async () => {} },
    transcribe: async (wav) => {
      log.transcribeCalls += 1;
      return transcribe ? transcribe(wav) : "bonjour tout le monde";
    },
    chat: async (opts) => {
      log.chatCalls.push(opts.model);
      return chat ? chat(opts) : "Texte propre.";
    },
    output: {
      pasteText: async (text, opts) => log.pasted.push({ text, ...opts }),
      captureSelection: async () => selection ?? { kind: "selected", text: "texte sélectionné" },
    },
    stats: new UsageStats(memoryStorage()),
    history: { add: (e) => log.history.push(e) },
    ui: {
      state: (s) => log.states.push(s),
      level: () => {},
      message: (text, kind) => log.messages.push({ text, kind }),
      timings: () => {},
    },
  };
  return { pipeline: new DictationPipeline(deps), log, deps };
}

function speak(pipeline, audio) {
  for (let i = 0; i < audio.length; i += 480) pipeline.pushAudio(audio.subarray(i, Math.min(i + 480, audio.length)));
}

test("short utterance: whole-file transcription, fast path skips cleanup, pastes", async () => {
  const { pipeline, log } = harness();
  assert.equal(await pipeline.begin(), true);
  speak(pipeline, tone(2));
  const result = await pipeline.end();
  assert.equal(result.ok, true);
  assert.equal(result.outcome, "fast-path");
  assert.deepEqual(log.pasted, [{ text: "bonjour tout le monde", pressEnter: false }]);
  assert.equal(log.chatCalls.length, 0);
  assert.equal(log.transcribeCalls, 1);
  assert.equal(pipeline.state, "idle");
  assert.equal(log.history.length, 1);
});

test("long utterance: chunked transcription then cleaned text is pasted", async () => {
  let n = 0;
  const { pipeline, log } = harness({
    transcribe: async () => `phrase ${++n} avec plusieurs mots pour dépasser le seuil rapide`,
    chat: async () => "Texte nettoyé final.",
  });
  await pipeline.begin();
  speak(pipeline, concat(tone(4), silence(1), tone(4), silence(1), tone(3)));
  const result = await pipeline.end();
  assert.equal(result.outcome, "cleaned");
  assert.equal(log.transcribeCalls, 3); // one request per phrase, no whole-file request
  assert.match(result.timings.engine, /par morceaux \(3\)/);
  assert.equal(log.pasted[0].text, "Texte nettoyé final.");
});

test("a failed chunk falls back to the whole recording", async () => {
  let calls = 0;
  const { pipeline, log } = harness({
    transcribe: async () => {
      calls += 1;
      if (calls <= 2) throw new Error("chunk failed");
      return "transcription complète du fichier entier avec assez de mots";
    },
    chat: async () => "Résultat.",
  });
  await pipeline.begin();
  speak(pipeline, concat(tone(4), silence(1), tone(3)));
  const result = await pipeline.end();
  assert.equal(result.ok, true);
  assert.equal(log.pasted[0].text, "Résultat.");
});

test("slow primary cleanup model is overtaken by the backup", async () => {
  const { pipeline, log } = harness({
    transcribe: async () => "une phrase suffisamment longue pour passer par le nettoyage complet",
    chat: async ({ model, signal }) => {
      if (model === "primary") {
        await sleep(600);
        return "Lent.";
      }
      return "Rapide.";
    },
  });
  await pipeline.begin();
  speak(pipeline, tone(2));
  const started = Date.now();
  const result = await pipeline.end();
  assert.equal(log.pasted[0].text, "Rapide.");
  assert.ok(Date.now() - started < 400);
  assert.equal(result.outcome, "cleaned");
  assert.deepEqual(log.chatCalls.sort(), ["backup", "primary"]);
});

test("cleanup failure pastes the raw transcript instead of losing the dictation", async () => {
  const { pipeline, log } = harness({
    transcribe: async () => "une phrase suffisamment longue pour passer par le nettoyage complet",
    chat: async () => {
      throw new Error("provider down");
    },
  });
  await pipeline.begin();
  speak(pipeline, tone(2));
  const result = await pipeline.end();
  assert.equal(result.outcome, "cleanup-failed");
  assert.equal(log.pasted[0].text, "une phrase suffisamment longue pour passer par le nettoyage complet");
});

test("accidental tap is discarded without any request", async () => {
  const { pipeline, log } = harness();
  await pipeline.begin();
  speak(pipeline, silence(0.2));
  const result = await pipeline.end();
  assert.equal(result.reason, "too-short");
  assert.equal(log.transcribeCalls, 0);
  assert.equal(log.pasted.length, 0);
  assert.equal(pipeline.state, "idle");
});

test("transcription error shows a friendly message and recovers", async () => {
  const error = Object.assign(new Error("nope"), { status: 401 });
  const { pipeline, log } = harness({ transcribe: async () => { throw error; } });
  await pipeline.begin();
  speak(pipeline, tone(2));
  const result = await pipeline.end();
  assert.equal(result.ok, false);
  assert.match(log.messages.at(-1).text, /Clé API/);
  assert.equal(pipeline.state, "idle");
  assert.equal(await pipeline.begin(), true); // usable again
});

test("macro and press-enter voice command", async () => {
  const settings = makeSettings({ macros: [{ trigger: "mon adresse", payload: "1 rue de Test" }] });
  const { pipeline, log } = harness({ settings, transcribe: async () => "Mon adresse" });
  await pipeline.begin();
  speak(pipeline, tone(2));
  assert.equal((await pipeline.end()).outcome, "macro");
  assert.equal(log.pasted[0].text, "1 rue de Test");

  const second = harness({ transcribe: async () => "Merci beaucoup, appuie sur entrée" });
  await second.pipeline.begin();
  speak(second.pipeline, tone(2));
  await second.pipeline.end();
  assert.deepEqual(second.log.pasted[0], { text: "Merci beaucoup", pressEnter: true });
});

test("rewrite selection verifies a real selection first", async () => {
  const none = harness({ selection: { kind: "none" } });
  const result = await none.pipeline.rewriteSelection();
  assert.equal(result.reason, "no-selection");
  assert.equal(none.log.chatCalls.length, 0);
  assert.equal(none.log.pasted.length, 0);
  assert.equal(none.log.messages.at(-1).text, "Aucun texte sélectionné");

  const ok = harness({ chat: async () => "Texte réécrit." });
  const done = await ok.pipeline.rewriteSelection();
  assert.equal(done.ok, true);
  assert.equal(ok.log.pasted[0].text, "Texte réécrit.");
  assert.equal(ok.pipeline.state, "idle");
});

test("rewrite failure leaves the selection untouched", async () => {
  const { pipeline, log } = harness({ chat: async () => { throw new Error("down"); } });
  const result = await pipeline.rewriteSelection();
  assert.equal(result.ok, false);
  assert.equal(log.pasted.length, 0);
});

test("edit by voice: instruction applied to the selection, nothing pasted without one", async () => {
  const withSel = harness({
    transcribe: async () => "mets ça en majuscules",
    chat: async () => "TEXTE SÉLECTIONNÉ",
  });
  await withSel.pipeline.begin("edit");
  speak(withSel.pipeline, tone(2));
  const edited = await withSel.pipeline.end();
  assert.equal(edited.outcome, "edited");
  assert.equal(withSel.log.pasted[0].text, "TEXTE SÉLECTIONNÉ");

  const withoutSel = harness({ transcribe: async () => "mets ça en majuscules", selection: { kind: "none" } });
  await withoutSel.pipeline.begin("edit");
  speak(withoutSel.pipeline, tone(2));
  const aborted = await withoutSel.pipeline.end();
  assert.equal(aborted.reason, "no-selection");
  assert.equal(withoutSel.log.pasted.length, 0);
  assert.equal(withoutSel.log.chatCalls.length, 0);
});

test("stats record words, never text; history respects the setting", async () => {
  const quiet = harness({ settings: makeSettings({ keepHistory: false }), transcribe: async () => "un deux trois" });
  await quiet.pipeline.begin();
  speak(quiet.pipeline, tone(2));
  await quiet.pipeline.end();
  assert.equal(quiet.log.history.length, 0);
  assert.equal(quiet.deps.stats.snapshot().totalWords, 3);
});

test("a second begin while recording is refused; cancel resets", async () => {
  const { pipeline } = harness();
  assert.equal(await pipeline.begin(), true);
  assert.equal(await pipeline.begin(), false);
  pipeline.cancel();
  assert.equal(pipeline.state, "idle");
  assert.equal(await pipeline.begin(), true);
});
