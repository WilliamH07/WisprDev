"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { shouldSkipCleanup, clampMaxWords } = require("../src/core/fastpath");
const routing = require("../src/core/routing");
const { ChordMatcher, isValidChord } = require("../src/core/chord");
const { makeSentinel, interpretCopyResult } = require("../src/core/selection");
const { parseTranscriptCommands, findMacro } = require("../src/core/commands");
const { encodePcm16Wav, syntheticSpeechWav } = require("../src/core/wav");
const prompts = require("../src/core/prompts");
const { sanitizeOutput, looksLikeAnswer } = require("../src/core/cleanup");

test("fast path rules", () => {
  assert.equal(shouldSkipCleanup({ transcript: "Sounds good, thanks." }), true);
  assert.equal(shouldSkipCleanup({ transcript: "one two three four five six seven" }), false);
  assert.equal(shouldSkipCleanup({ transcript: "   " }), false);
  assert.equal(shouldSkipCleanup({ transcript: "Hello there", outputLanguage: "French" }), false);
  assert.equal(shouldSkipCleanup({ transcript: "Hello there", vocabulary: "Kubernetes" }), false);
  assert.equal(shouldSkipCleanup({ transcript: "Hello there", customPrompt: "x" }), false);
  assert.equal(shouldSkipCleanup({ transcript: "a b c d e f g h", maxWords: 10 }), true);
  assert.equal(clampMaxWords(999), 40);
  assert.equal(clampMaxWords(0), 6);
  assert.equal(clampMaxWords(1), 3);
});

test("transcription routing", () => {
  assert.equal(routing.transcriptionBaseUrl({ model: "fish-audio/transcribe-1" }), routing.OPENROUTER_BASE_URL);
  assert.equal(routing.transcriptionBaseUrl({ model: "whisper-large-v3" }), routing.DEFAULT_TRANSCRIPTION_BASE_URL);
  assert.equal(
    routing.transcriptionBaseUrl({ model: "fish-audio/transcribe-1", explicitUrl: " https://example.test/v1/ " }),
    "https://example.test/v1"
  );
  assert.equal(routing.transcriptionApiKey({ model: "fish-audio/transcribe-1", openRouterKey: "or", defaultKey: "d" }), "or");
  assert.equal(routing.transcriptionApiKey({ model: "whisper-large-v3", openRouterKey: "or", defaultKey: "d" }), "d");
  assert.equal(routing.transcriptionApiKey({ model: "fish-audio/transcribe-1", explicitKey: "x", openRouterKey: "or" }), "x");
  assert.equal(routing.reasoningEffortFor("openai/gpt-oss-20b"), "low");
  assert.equal(routing.reasoningEffortFor("google/gemini-2.5-flash"), "none");
});

test("chord: hold, release and cancel", () => {
  const m = new ChordMatcher(["Ctrl", "Meta"]);
  assert.equal(m.handle("keydown", 29), null);
  assert.equal(m.handle("keydown", 3675), "down");
  assert.equal(m.handle("keydown", 3675), null); // key repeat
  assert.equal(m.handle("keyup", 3675), "up");
  assert.equal(m.handle("keyup", 29), null);
  // Another key while active cancels (Ctrl+Win+Right = switch desktop).
  m.handle("keydown", 29);
  assert.equal(m.handle("keydown", 3676), "down");
  assert.equal(m.handle("keydown", 57421), "cancel");
  assert.equal(m.handle("keyup", 57421), null);
  assert.equal(m.handle("keyup", 3676), null);
  assert.equal(m.handle("keyup", 29), null);
  // After release everything works again.
  m.handle("keydown", 29);
  assert.equal(m.handle("keydown", 3675), "down");
});

test("chord ignores presses made while another key is held", () => {
  const m = new ChordMatcher(["Ctrl", "Meta"]);
  m.handle("keydown", 30); // 'A' held
  m.handle("keydown", 29);
  assert.equal(m.handle("keydown", 3675), null);
  m.handle("keyup", 30);
  m.handle("keyup", 3675);
  m.handle("keyup", 29);
  m.handle("keydown", 29);
  assert.equal(m.handle("keydown", 3675), "down");
});

test("typing a key before the chord does not block it later", () => {
  const m = new ChordMatcher(["Ctrl", "Meta"]);
  m.handle("keydown", 30);
  m.handle("keyup", 30);
  m.handle("keydown", 29);
  assert.equal(m.handle("keydown", 3675), "down");
});

test("chord with a letter and validation", () => {
  const m = new ChordMatcher(["Ctrl", "Meta", "R"]);
  m.handle("keydown", 29);
  m.handle("keydown", 3675);
  assert.equal(m.handle("keydown", 19), "down");
  assert.equal(m.handle("keyup", 19), "up");
  assert.equal(isValidChord(["Ctrl", "Nope"]), false);
  assert.equal(isValidChord([]), false);
  assert.throws(() => new ChordMatcher(["Ctrl", "Nope"]));
});

test("selection detection by clipboard sentinel", () => {
  const sentinel = makeSentinel();
  assert.notEqual(sentinel, makeSentinel());
  assert.deepEqual(interpretCopyResult(sentinel, sentinel), { kind: "none" });
  assert.deepEqual(interpretCopyResult(sentinel, "  \n"), { kind: "none" });
  assert.deepEqual(interpretCopyResult(sentinel, undefined), { kind: "none" });
  assert.deepEqual(interpretCopyResult(sentinel, " picked text "), { kind: "selected", text: "picked text" });
});

test("voice commands and macros", () => {
  assert.deepEqual(parseTranscriptCommands("Envoie le message, appuie sur Entrée"), { text: "Envoie le message", pressEnter: true });
  assert.deepEqual(parseTranscriptCommands("press enter"), { text: "", pressEnter: true });
  assert.deepEqual(parseTranscriptCommands("Bonjour tout le monde"), { text: "Bonjour tout le monde", pressEnter: false });
  const macros = [{ trigger: "mon adresse", payload: "1 rue de Test" }];
  assert.equal(findMacro("Mon adresse.", macros).payload, "1 rue de Test");
  assert.equal(findMacro("voici mon adresse complète", macros), null);
});

test("wav encoding", () => {
  const wav = encodePcm16Wav(new Int16Array([0, 1]), 16000);
  assert.equal(wav.length, 48);
  assert.equal(wav.toString("ascii", 0, 4), "RIFF");
  assert.equal(wav.toString("ascii", 8, 12), "WAVE");
  assert.equal(syntheticSpeechWav(1, 16000).length, 44 + 32000);
});

test("prompts and output sanitizing", () => {
  assert.ok(prompts.DICTATION_SYSTEM_PROMPT.includes("RÈGLE ANTI-RÉPONSE"));
  assert.ok(prompts.REWRITE_SYSTEM_PROMPT.includes("ANTI-RÉPONSE"));
  assert.ok(prompts.COMMAND_SYSTEM_PROMPT.includes("COMMANDE_VOCALE"));
  const withVocab = prompts.buildDictationSystemPrompt({ vocabulary: "Kubernetes, Redis", outputLanguage: "English" });
  assert.ok(withVocab.includes("Kubernetes, Redis") && withVocab.includes("English"));
  assert.equal(sanitizeOutput('"Bonjour"'), "Bonjour");
  assert.equal(sanitizeOutput("EMPTY"), "");
  assert.equal(sanitizeOutput("« Salut »"), "Salut");
  assert.equal(looksLikeAnswer("ok", "x".repeat(500)), true);
  assert.equal(looksLikeAnswer("hello world", "Hello, world."), false);
});
