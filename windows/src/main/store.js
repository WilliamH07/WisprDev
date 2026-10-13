"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { app, safeStorage } = require("electron");
const { normalizeSettings, applyPatch, SECRET_FIELDS } = require("../core/settings");

class JsonFile {
  constructor(file) {
    this.file = file;
  }

  read() {
    try {
      return JSON.parse(fs.readFileSync(this.file, "utf8"));
    } catch {
      return null;
    }
  }

  write(data) {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data), "utf8");
    fs.renameSync(tmp, this.file); // atomic: a crash never leaves a half-written file
  }
}

function encrypt(value) {
  if (!value) return "";
  if (safeStorage.isEncryptionAvailable()) return `enc:${safeStorage.encryptString(value).toString("base64")}`;
  return `plain:${value}`;
}

function decrypt(stored) {
  if (typeof stored !== "string" || !stored) return "";
  try {
    if (stored.startsWith("enc:")) return safeStorage.decryptString(Buffer.from(stored.slice(4), "base64"));
    if (stored.startsWith("plain:")) return stored.slice(6);
  } catch {
    return "";
  }
  return "";
}

/** Settings on disk; API keys are encrypted with the Windows data-protection API. */
class SettingsStore {
  constructor() {
    this.file = new JsonFile(path.join(app.getPath("userData"), "settings.json"));
    const raw = this.file.read() || {};
    const decrypted = { ...raw };
    for (const key of SECRET_FIELDS) decrypted[key] = decrypt(raw[key]);
    this.settings = normalizeSettings(decrypted);
  }

  get() {
    return this.settings;
  }

  update(patch) {
    this.settings = applyPatch(this.settings, patch);
    const toWrite = { ...this.settings };
    for (const key of SECRET_FIELDS) toWrite[key] = encrypt(this.settings[key]);
    this.file.write(toWrite);
    return this.settings;
  }
}

class HistoryStore {
  constructor(max = 20) {
    this.file = new JsonFile(path.join(app.getPath("userData"), "history.json"));
    this.max = max;
  }

  list() {
    const data = this.file.read();
    return Array.isArray(data) ? data : [];
  }

  add(entry) {
    this.file.write([entry, ...this.list()].slice(0, this.max));
  }

  clear() {
    this.file.write([]);
  }
}

function statsStorage() {
  return new JsonFile(path.join(app.getPath("userData"), "stats.json"));
}

module.exports = { SettingsStore, HistoryStore, statsStorage };
