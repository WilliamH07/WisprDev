"use strict";

const { clipboard, ClipboardItem } = require("electron");
const { makeSentinel, interpretCopyResult } = require("../core/selection");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Electron's clipboard API is promise-based (W3C style): snapshot every MIME type the
 * clipboard exposes so a paste or a selection probe can put the user's content back.
 */
async function snapshotClipboard() {
  const entries = [];
  try {
    for (const item of await clipboard.read()) {
      const parts = {};
      for (const type of item.types) {
        if (type.startsWith("electron ")) continue; // bookmarks and raw formats are not restorable as-is
        try {
          parts[type] = await item.getType(type);
        } catch {
          // a format that cannot be read is skipped
        }
      }
      if (Object.keys(parts).length > 0) entries.push(parts);
    }
  } catch {
    // an unreadable clipboard is treated as empty
  }
  let text = "";
  try {
    text = await clipboard.readText();
  } catch {
    // empty
  }
  return { entries, text };
}

async function restoreClipboard(snapshot) {
  try {
    if (snapshot.entries.length === 0) {
      if (snapshot.text) await clipboard.writeText(snapshot.text);
      else clipboard.clear();
      return;
    }
    await clipboard.write(snapshot.entries.map((parts) => new ClipboardItem(parts)));
  } catch {
    // last resort: at least restore the plain text
    if (snapshot.text) await clipboard.writeText(snapshot.text).catch(() => {});
  }
}

/** Types into the focused app by pasting (Ctrl+V) and selects text by copying (Ctrl+C). */
class Output {
  constructor({ getSettings, hotkeys }) {
    this.getSettings = getSettings;
    this.hotkeys = hotkeys;
    this.lastText = "";
  }

  _keys() {
    const { uIOhook, UiohookKey } = require("uiohook-napi");
    return { uIOhook, Key: UiohookKey };
  }

  async pasteText(text, { pressEnter = false } = {}) {
    const { uIOhook, Key } = this._keys();
    await this.hotkeys.waitForRelease(600);
    if (text) {
      this.lastText = text;
      const keep = this.getSettings().restoreClipboard;
      const snapshot = keep ? await snapshotClipboard() : null;
      // A trailing space after sentence punctuation keeps consecutive dictations apart.
      const payload = /[.!?…]$/.test(text) ? `${text} ` : text;
      await clipboard.writeText(payload);
      await sleep(30);
      uIOhook.keyTap(Key.V, [Key.Ctrl]);
      if (snapshot) {
        setTimeout(async () => {
          // Only restore if the user has not copied something new in the meantime.
          if ((await clipboard.readText()) === payload) await restoreClipboard(snapshot);
        }, 1000);
      }
    }
    if (pressEnter) {
      await sleep(80);
      uIOhook.keyTap(Key.Enter);
    }
  }

  /**
   * Reads the current selection by copying it. A unique sentinel is placed on the
   * clipboard first: if it is still there after Ctrl+C, nothing was selected, so stale
   * clipboard text can never be mistaken for a selection.
   */
  async captureSelection() {
    const { uIOhook, Key } = this._keys();
    await this.hotkeys.waitForRelease(800);
    const snapshot = await snapshotClipboard();
    const sentinel = makeSentinel();
    await clipboard.writeText(sentinel);
    try {
      uIOhook.keyTap(Key.C, [Key.Ctrl]);
      let after = sentinel;
      for (let i = 0; i < 20; i += 1) {
        await sleep(25);
        after = await clipboard.readText();
        if (after !== sentinel) break;
      }
      return interpretCopyResult(sentinel, after);
    } finally {
      await restoreClipboard(snapshot);
    }
  }

  copyLast() {
    if (this.lastText) clipboard.writeText(this.lastText).catch(() => {});
  }
}

module.exports = { Output };
