"use strict";

/**
 * Hedged request: start `runPrimary`; if it has not answered after `delayMs` (or fails
 * sooner), also start `runRetry` in parallel. The first success wins and the other is
 * aborted. Both failing rejects with the primary's error. Keeps the AI result while
 * removing the "wait for the primary to time out, then try the backup" worst case.
 */
function hedged(runPrimary, runRetry, { delayMs = 1200 } = {}) {
  if (!runRetry) return runPrimary(new AbortController().signal);

  return new Promise((resolve, reject) => {
    const primaryController = new AbortController();
    const retryController = new AbortController();
    let settled = false;
    let retryStarted = false;
    let primaryFailed = false;
    let retryFailed = false;
    let primaryError;
    let retryError;
    let timer;

    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      primaryController.abort();
      retryController.abort();
      fn(value);
    };

    const startRetry = () => {
      if (retryStarted || settled) return;
      retryStarted = true;
      Promise.resolve()
        .then(() => runRetry(retryController.signal))
        .then(
          (value) => finish(resolve, value),
          (error) => {
            retryFailed = true;
            retryError = error;
            if (primaryFailed) finish(reject, primaryError ?? retryError);
          }
        );
    };

    timer = setTimeout(startRetry, delayMs);

    Promise.resolve()
      .then(() => runPrimary(primaryController.signal))
      .then(
        (value) => finish(resolve, value),
        (error) => {
          primaryFailed = true;
          primaryError = error;
          if (!retryStarted) startRetry();
          else if (retryFailed) finish(reject, primaryError);
        }
      );
  });
}

module.exports = { hedged };
