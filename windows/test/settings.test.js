"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const settings = require("../src/core/settings");
const { nameForCode } = require("../src/core/chord");

test("normalize fills defaults and survives garbage", () => {
  const s = settings.normalizeSettings({ fastPathMaxWords: "999", hotkeys: { dictate: ["Nope"] }, macros: [{ trigger: " a ", payload: "b" }, null, { trigger: "" }], cleanupModel: 5 });
  assert.equal(s.fastPathMaxWords, 40);
  assert.deepEqual(s.hotkeys.dictate, ["Ctrl", "Meta"]);
  assert.deepEqual(s.macros, [{ trigger: "a", payload: "b" }]);
  assert.equal(s.cleanupModel, "google/gemini-2.5-flash");
  assert.deepEqual(settings.normalizeSettings(undefined).hotkeys.edit, ["Ctrl", "Meta", "E"]);
  assert.doesNotThrow(() => settings.normalizeSettings(null === undefined ? {} : { hotkeys: "bad", macros: "bad" }));
});

test("secrets: empty keeps, null clears, UI never receives them", () => {
  let s = settings.applyPatch(settings.normalizeSettings({}), { openRouterKey: " sk-1 ", cleanupModel: "m" });
  assert.equal(s.openRouterKey, "sk-1");
  s = settings.applyPatch(s, { openRouterKey: "", cleanupModel: "m2" });
  assert.equal(s.openRouterKey, "sk-1");
  assert.equal(s.cleanupModel, "m2");
  const pub = settings.publicSettings(s);
  assert.equal(pub.openRouterKey, "");
  assert.equal(pub.openRouterKeySet, true);
  s = settings.applyPatch(s, { openRouterKey: null });
  assert.equal(s.openRouterKey, "");
  s = settings.applyPatch(s, { notAField: 1 });
  assert.equal("notAField" in s, false);
});

test("runtime and transcription config route Fish Audio through OpenRouter", () => {
  const s = settings.normalizeSettings({ openRouterKey: "or-key" });
  const t = settings.transcriptionConfig(s);
  assert.equal(t.baseUrl, "https://openrouter.ai/api/v1");
  assert.equal(t.apiKey, "or-key");
  assert.equal(t.model, "fish-audio/transcribe-1");
  const r = settings.runtimeSettings(s);
  assert.equal(r.cleanup.baseUrl, "https://openrouter.ai/api/v1");
  assert.equal(r.cleanup.apiKey, "or-key");
  assert.equal(r.cleanup.primaryModel, "google/gemini-2.5-flash");
  assert.deepEqual(settings.missingConfiguration(s), []);
  assert.equal(settings.missingConfiguration(settings.normalizeSettings({})).length, 2);
});

test("scancode names for the shortcut capture", () => {
  assert.equal(nameForCode(29), "Ctrl");
  assert.equal(nameForCode(3676), "Meta");
  assert.equal(nameForCode(19), "R");
  assert.equal(nameForCode(99999), undefined);
});
