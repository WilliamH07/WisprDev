"use strict";

// uiohook scancodes (see uiohook-napi UiohookKey).
const MODIFIER_GROUPS = {
  Ctrl: [29, 3613],
  Alt: [56, 3640],
  Shift: [42, 54],
  Meta: [3675, 3676],
};

const NAMED_KEYS = {
  Space: 57, Enter: 28, Escape: 1, Tab: 15,
  A: 30, B: 48, C: 46, D: 32, E: 18, F: 33, G: 34, H: 35, I: 23, J: 36, K: 37, L: 38, M: 50,
  N: 49, O: 24, P: 25, Q: 16, R: 19, S: 31, T: 20, U: 22, V: 47, W: 17, X: 45, Y: 21, Z: 44,
  0: 11, 1: 2, 2: 3, 3: 4, 4: 5, 5: 6, 6: 7, 7: 8, 8: 9, 9: 10,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68, F11: 87, F12: 88,
};

const KEY_LABELS = { Meta: "Win", Ctrl: "Ctrl", Alt: "Alt", Shift: "Maj" };

function codesFor(name) {
  if (MODIFIER_GROUPS[name]) return MODIFIER_GROUPS[name];
  const code = NAMED_KEYS[name];
  return code === undefined ? [] : [code];
}

const CODE_TO_NAME = (() => {
  const map = new Map();
  for (const [name, codes] of Object.entries(MODIFIER_GROUPS)) for (const c of codes) map.set(c, name);
  for (const [name, code] of Object.entries(NAMED_KEYS)) map.set(code, name);
  return map;
})();

/** Name of a scancode ("Ctrl", "R", ...) or undefined when it cannot be part of a chord. */
function nameForCode(code) {
  return CODE_TO_NAME.get(code);
}

function isValidChord(names) {
  return Array.isArray(names) && names.length > 0 && names.every((n) => codesFor(n).length > 0);
}

function chordLabel(names) {
  return names.map((n) => KEY_LABELS[n] || n).join(" + ");
}

/**
 * Detects a key chord from raw key events. Emits "down" when the whole chord becomes
 * pressed, "up" when it is released, and "cancel" when another key is pressed while it
 * is active (e.g. Ctrl+Win+Right for desktop switching must never keep dictating).
 * A chord is also ignored while any key outside the chord is held.
 */
class ChordMatcher {
  constructor(names) {
    if (!isValidChord(names)) throw new Error(`Invalid chord: ${JSON.stringify(names)}`);
    this.names = names;
    this.groups = names.map((n) => codesFor(n));
    this.chordCodes = new Set(this.groups.flat());
    this.pressed = new Set();
    this.active = false;
    this.latched = false; // set after a cancel, cleared once every chord key is released
  }

  _allChordKeysDown() {
    return this.groups.every((codes) => codes.some((c) => this.pressed.has(c)));
  }

  _anyChordKeyDown() {
    for (const c of this.chordCodes) if (this.pressed.has(c)) return true;
    return false;
  }

  _otherKeysDown() {
    for (const c of this.pressed) if (!this.chordCodes.has(c)) return true;
    return false;
  }

  /** @returns {"down"|"up"|"cancel"|null} */
  handle(type, code) {
    if (type === "keydown") {
      this.pressed.add(code);
      if (!this.chordCodes.has(code)) {
        if (this.active) {
          this.active = false;
          this.latched = true;
          return "cancel";
        }
        return null;
      }
      if (!this.active && !this.latched && !this._otherKeysDown() && this._allChordKeysDown()) {
        this.active = true;
        return "down";
      }
      return null;
    }

    this.pressed.delete(code);
    if (!this._anyChordKeyDown()) this.latched = false;
    if (this.active && this.chordCodes.has(code) && !this._allChordKeysDown()) {
      this.active = false;
      return "up";
    }
    return null;
  }

  anyChordKeyDown() {
    return this._anyChordKeyDown();
  }
}

module.exports = { ChordMatcher, isValidChord, chordLabel, nameForCode, MODIFIER_GROUPS, NAMED_KEYS, codesFor };
