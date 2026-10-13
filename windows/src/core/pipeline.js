"use strict";

const { ChunkedSession } = require("./chunker");
const { ChunkAccumulator } = require("./chunker");
const { encodePcm16Wav } = require("./wav");
const { cleanTranscript, rewriteText, transformWithCommand } = require("./cleanup");
const { parseTranscriptCommands, findMacro } = require("./commands");
const { countWords } = require("./stats");
const { formatDuration, totalMs } = require("./timings");

const SAMPLE_RATE = 24000;

function friendlyError(error) {
  const status = error && error.status;
  if (status === 401 || status === 403) return "Clé API invalide ou refusée";
  if (status === 402) return "Crédits insuffisants chez le fournisseur";
  if (status === 429) return "Trop de requêtes, réessayez dans un instant";
  if (error && (error.name === "TimeoutError" || error.name === "AbortError")) return "Le fournisseur a mis trop de temps à répondre";
  return `Erreur : ${error && error.message ? error.message : "inconnue"}`;
}

/**
 * Orchestrates a dictation: record -> transcribe (by phrase while speaking) -> clean up
 * (hedged) -> paste. All side effects go through `deps` so it can be tested without Electron.
 *
 * deps: { now, getSettings, recorder:{start,stop}, transcribe(wav,signal), chat(opts),
 *         output:{pasteText(text,{pressEnter}), captureSelection()}, stats, history, ui }
 */
class DictationPipeline {
  constructor(deps) {
    this.deps = deps;
    this.state = "idle";
    this._resetRecording();
  }

  _resetRecording() {
    this.pieces = [];
    this.totalSamples = 0;
    this.peakRms = 0;
    this.session = null;
    this.mode = "dictation";
  }

  get isBusy() {
    return this.state !== "idle";
  }

  /** Starts recording. Returns false when another dictation is already running. */
  async begin(mode = "dictation") {
    if (this.state !== "idle") return false;
    this.state = "recording";
    this._resetRecording();
    this.mode = mode;
    const settings = this.deps.getSettings();
    if (settings.chunkedEnabled && mode === "dictation") {
      this.session = new ChunkedSession({
        sampleRate: SAMPLE_RATE,
        transcribe: (wav) => this.deps.transcribe(wav),
      });
    }
    this.deps.ui.state("recording");
    try {
      await this.deps.recorder.start();
    } catch (error) {
      this.state = "idle";
      this.deps.ui.message(`Micro indisponible : ${error.message}`, "error");
      return false;
    }
    return true;
  }

  /** Called with each block of 24 kHz mono PCM16 samples while recording. */
  pushAudio(samples) {
    if (this.state !== "recording") return;
    this.pieces.push(samples);
    this.totalSamples += samples.length;
    const level = ChunkAccumulator.rms(samples);
    this.peakRms = Math.max(this.peakRms, level);
    if (this.session) this.session.append(samples);
    this.deps.ui.level(level);
  }

  cancel() {
    if (this.state === "idle") return;
    if (this.session) this.session.cancel();
    this._resetRecording();
    this.state = "idle";
    Promise.resolve(this.deps.recorder.stop()).catch(() => {});
    this.deps.ui.state("idle");
  }

  _wholeWav() {
    const all = new Int16Array(this.totalSamples);
    let offset = 0;
    for (const piece of this.pieces) {
      all.set(piece, offset);
      offset += piece.length;
    }
    return encodePcm16Wav(all, SAMPLE_RATE);
  }

  /** Stops recording and runs the rest of the pipeline. */
  async end() {
    if (this.state !== "recording") return { ok: false, reason: "not-recording" };
    this.state = "processing";
    const { deps } = this;
    const releaseAt = deps.now();
    const session = this.session;
    const mode = this.mode;
    try {
      await deps.recorder.stop();
    } catch {
      // The audio already received is still usable.
    }
    const timings = { audioFinalizeMs: deps.now() - releaseAt, transcriptionMs: 0, cleanupMs: 0, engine: "", skippedCleanup: false };
    const durationSeconds = this.totalSamples / SAMPLE_RATE;
    const hasSpeech = this.peakRms >= 0.01;

    // Accidental tap or pure silence.
    if (this.totalSamples === 0 || (durationSeconds < 0.4 && !hasSpeech) || (!hasSpeech && this.peakRms < 0.003)) {
      if (session) session.cancel();
      this._resetRecording();
      this.state = "idle";
      deps.ui.state("idle");
      return { ok: false, reason: "too-short" };
    }

    deps.ui.state("transcribing");
    const settings = deps.getSettings();
    try {
      const transcribeStart = deps.now();
      let raw = null;
      if (session) {
        try {
          raw = await session.finish();
        } catch {
          raw = null; // a chunk failed: use the whole recording instead
        }
      }
      if (raw !== null && raw.trim() !== "") {
        timings.engine = `${settings.transcriptionModel} · par morceaux (${session.chunkCount})`;
      } else {
        raw = await deps.transcribe(this._wholeWav());
        timings.engine = settings.transcriptionModel;
      }
      timings.transcriptionMs = deps.now() - transcribeStart;

      if (!raw || !raw.trim()) {
        this._finish(timings);
        deps.ui.message("Rien à transcrire", "info");
        return { ok: true, text: "", outcome: "empty", timings };
      }

      if (mode === "edit") return await this._finishEdit(raw, settings, timings);
      return await this._finishDictation(raw, settings, timings, durationSeconds);
    } catch (error) {
      if (session) session.cancel();
      this._finish(timings);
      deps.ui.message(friendlyError(error), "error");
      return { ok: false, reason: "error", error };
    }
  }

  async _finishDictation(raw, settings, timings, durationSeconds) {
    const { deps } = this;
    const parsed = parseTranscriptCommands(raw);
    const macro = findMacro(parsed.text, settings.macros);
    let text;
    let outcome;
    if (macro) {
      text = macro.payload;
      outcome = "macro";
      timings.skippedCleanup = true;
    } else {
      const cleanupStart = deps.now();
      const result = await cleanTranscript(parsed.text, settings, (opts) =>
        deps.chat({ ...opts, ...this._chatTarget(settings) })
      );
      timings.cleanupMs = deps.now() - cleanupStart;
      timings.skippedCleanup = result.outcome === "fast-path";
      text = result.text;
      outcome = result.outcome;
    }

    if (text) {
      await deps.output.pasteText(text, { pressEnter: parsed.pressEnter });
    } else if (parsed.pressEnter) {
      await deps.output.pasteText("", { pressEnter: true });
    }
    if (text) {
      deps.stats.record({ wordCount: countWords(text), speakingSeconds: durationSeconds });
    }
    this._record({ mode: "dictation", raw, text, outcome, timings, settings });
    this._finish(timings);
    deps.ui.message(text ? "Collé" : "Rien à coller", text ? "success" : "info");
    return { ok: true, text, outcome, timings };
  }

  async _finishEdit(instruction, settings, timings) {
    const { deps } = this;
    const selection = await deps.output.captureSelection();
    if (selection.kind !== "selected") {
      this._finish(timings);
      deps.ui.message("Aucun texte sélectionné", "error");
      return { ok: false, reason: "no-selection", timings };
    }
    const cleanupStart = deps.now();
    try {
      const text = await transformWithCommand(selection.text, instruction, settings, (opts) =>
        deps.chat({ ...opts, ...this._chatTarget(settings) })
      );
      timings.cleanupMs = deps.now() - cleanupStart;
      await deps.output.pasteText(text, { pressEnter: false });
      this._record({ mode: "edit", raw: instruction, text, outcome: "edited", timings, settings });
      this._finish(timings);
      deps.ui.message("Texte modifié", "success");
      return { ok: true, text, outcome: "edited", timings };
    } catch (error) {
      this._finish(timings);
      deps.ui.message(friendlyError(error), "error");
      return { ok: false, reason: "error", error };
    }
  }

  /** Rewrites the current selection (tap shortcut). Verifies a real selection first. */
  async rewriteSelection() {
    const { deps } = this;
    if (this.state !== "idle") return { ok: false, reason: "busy" };
    this.state = "processing";
    try {
      const selection = await deps.output.captureSelection();
      if (selection.kind !== "selected") {
        deps.ui.message("Aucun texte sélectionné", "error");
        return { ok: false, reason: "no-selection" };
      }
      deps.ui.state("rewriting");
      const settings = deps.getSettings();
      const started = deps.now();
      const text = await rewriteText(selection.text, settings, (opts) =>
        deps.chat({ ...opts, ...this._chatTarget(settings) })
      );
      await deps.output.pasteText(text, { pressEnter: false });
      deps.ui.timings({ audioFinalizeMs: 0, transcriptionMs: 0, cleanupMs: deps.now() - started, engine: "Réécriture", skippedCleanup: false });
      deps.ui.message("Texte réécrit", "success");
      return { ok: true, text };
    } catch (error) {
      deps.ui.message(friendlyError(error), "error");
      return { ok: false, reason: "error", error };
    } finally {
      this.state = "idle";
      deps.ui.state("idle");
    }
  }

  _chatTarget(settings) {
    return { baseUrl: settings.cleanup.baseUrl, apiKey: settings.cleanup.apiKey };
  }

  _record({ mode, raw, text, outcome, timings, settings }) {
    if (!settings.keepHistory) return;
    this.deps.history.add({
      timestamp: new Date(this.deps.now()).toISOString(),
      mode,
      raw,
      text,
      outcome,
      engine: timings.engine,
      totalMs: totalMs(timings),
    });
  }

  _finish(timings) {
    this._resetRecording();
    this.state = "idle";
    this.deps.ui.timings(timings);
    this.deps.ui.state("idle");
  }
}

module.exports = { DictationPipeline, friendlyError, SAMPLE_RATE, formatDuration };
