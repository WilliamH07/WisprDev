"use strict";

const { ChordMatcher, nameForCode } = require("../core/chord");

/**
 * Global hold-to-talk shortcuts. Listens to raw key events (uiohook) because Electron's
 * globalShortcut has no key-up event, which hold-to-talk needs. The listener is passive:
 * it never blocks or alters the keys the user types.
 */
class Hotkeys {
  constructor({ getSettings, onStart, onStop, onCancel, onRewrite, log = () => {} }) {
    this.getSettings = getSettings;
    this.handlers = { onStart, onStop, onCancel, onRewrite };
    this.log = log;
    this.hook = null;
    this.matchers = null;
    this.timers = { dictate: null, edit: null };
    this.running = { dictate: false, edit: false };
    this.captureResolver = null;
    this.captureNames = [];
    this.captureSeen = new Set();
  }

  start() {
    const { uIOhook, UiohookKey } = require("uiohook-napi");
    this.hook = uIOhook;
    this.keys = UiohookKey;
    this.rebuild();
    uIOhook.on("keydown", (e) => this._onKey("keydown", e.keycode));
    uIOhook.on("keyup", (e) => this._onKey("keyup", e.keycode));
    uIOhook.start();
  }

  stop() {
    if (this.hook) {
      try {
        this.hook.stop();
      } catch {
        // already stopped
      }
    }
  }

  /** Rebuilds the matchers after the shortcuts changed in settings. */
  rebuild() {
    const { hotkeys } = this.getSettings();
    this.matchers = {
      dictate: new ChordMatcher(hotkeys.dictate),
      edit: new ChordMatcher(hotkeys.edit),
      rewrite: new ChordMatcher(hotkeys.rewrite),
    };
  }

  /** True while any key of the shortcuts is physically down. */
  anyShortcutKeyDown() {
    return Object.values(this.matchers).some((m) => m.anyChordKeyDown());
  }

  /** Resolves once the shortcut keys are released (or after `timeoutMs`). */
  async waitForRelease(timeoutMs = 700) {
    const deadline = Date.now() + timeoutMs;
    while (this.anyShortcutKeyDown() && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  /** Captures the next pressed combination, for the shortcut picker in settings. */
  capture(timeoutMs = 8000) {
    return new Promise((resolve) => {
      this.captureNames = [];
      this.captureSeen = new Set();
      const done = (names) => {
        clearTimeout(timer);
        this.captureResolver = null;
        resolve(names);
      };
      const timer = setTimeout(() => done(null), timeoutMs);
      this.captureResolver = done;
    });
  }

  _onKey(type, code) {
    if (this.captureResolver) {
      this._onCaptureKey(type, code);
      return;
    }
    for (const [action, matcher] of Object.entries(this.matchers)) {
      const event = matcher.handle(type, code);
      if (event) this._dispatch(action, event);
    }
  }

  _onCaptureKey(type, code) {
    const name = nameForCode(code);
    if (type === "keydown" && name && !this.captureSeen.has(name)) {
      this.captureSeen.add(name);
      this.captureNames.push(name);
    }
    if (type === "keyup" && this.captureNames.length > 0) {
      const down = this.captureNames.length;
      // Modifiers first, then the other key: the order users expect to read.
      const order = ["Ctrl", "Alt", "Shift", "Meta"];
      const names = [...this.captureNames].sort((a, b) => {
        const ia = order.indexOf(a);
        const ib = order.indexOf(b);
        return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
      });
      if (down > 0) this.captureResolver(names);
    }
  }

  _dispatch(action, event) {
    if (action === "rewrite") {
      if (event === "down") this.handlers.onRewrite();
      return;
    }
    const mode = action === "edit" ? "edit" : "dictation";
    if (event === "down") {
      // A short hold delay avoids starting on Windows shortcuts such as Ctrl+Win+Arrow.
      const delay = this.getSettings().startDelayMs;
      this.timers[action] = setTimeout(() => {
        this.timers[action] = null;
        this.running[action] = true;
        this.handlers.onStart(mode);
      }, delay);
    } else if (event === "up") {
      if (this.timers[action]) {
        clearTimeout(this.timers[action]);
        this.timers[action] = null;
      } else if (this.running[action]) {
        this.running[action] = false;
        this.handlers.onStop(mode);
      }
    } else if (event === "cancel") {
      if (this.timers[action]) {
        clearTimeout(this.timers[action]);
        this.timers[action] = null;
      } else if (this.running[action]) {
        this.running[action] = false;
        this.handlers.onCancel(mode);
      }
    }
  }
}

module.exports = { Hotkeys };
