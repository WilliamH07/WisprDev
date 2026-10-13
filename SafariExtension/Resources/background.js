// Wisper Agent background script: relays content-script requests to the
// Wisper app on 127.0.0.1 with the pairing token, and streams answers back.
(() => {
  'use strict';

  const core = globalThis.WisperAgentCore;
  const api = globalThis.browser || globalThis.chrome;
  const memoryConversations = new Map();
  const sessionStore = api.storage && api.storage.session;

  const NOT_PAIRED = "Extension non appairée : cliquez sur l'icône Wisper Agent dans la barre d'outils de Safari et collez le code affiché dans Wisper → Réglages → Agent Safari.";
  const UNREACHABLE = "Wisper est injoignable : vérifiez que l'app est lancée et que l'agent Safari est activé dans ses réglages.";
  const REJECTED = "Code d'appairage refusé : collez le code actuel affiché dans Wisper → Réglages → Agent Safari.";

  async function getPairing() {
    const stored = await api.storage.local.get('pairing');
    const pairing = stored && stored.pairing;
    return pairing && pairing.port && pairing.token ? pairing : null;
  }

  async function request(path, options) {
    const { method = 'GET', body, signal } = options || {};
    const pairing = await getPairing();
    if (!pairing) {
      throw new Error(NOT_PAIRED);
    }
    const headers = { Authorization: 'Bearer ' + pairing.token };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
    }
    let response;
    try {
      response = await fetch('http://127.0.0.1:' + pairing.port + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
        cache: 'no-store'
      });
    } catch (error) {
      if (error && error.name === 'AbortError') throw error;
      throw new Error(UNREACHABLE);
    }
    if (!response.ok) {
      let message = 'Erreur Wisper (' + response.status + ')';
      try {
        const data = await response.json();
        if (data && data.error) message = data.error;
      } catch (error) {
        // Keep the generic message.
      }
      throw new Error(response.status === 401 ? REJECTED : message);
    }
    return response;
  }

  function safePost(port, message) {
    try {
      port.postMessage(message);
    } catch (error) {
      // The tab went away; nothing to deliver.
    }
  }

  function reply(port, requestId, ok, data, error) {
    safePost(port, { requestId, ok, data: data || null, error: error || '' });
  }

  async function streamChat(port, requestId, payload, controller) {
    try {
      const response = await request('/v1/chat', { method: 'POST', body: payload, signal: controller.signal });
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const parsed = core.parseEventStream(buffer);
        buffer = parsed.rest;
        for (const event of parsed.events) {
          safePost(port, Object.assign({}, event, { requestId }));
          if (event.type === 'done' || event.type === 'error') {
            return;
          }
        }
      }
      safePost(port, { requestId, type: 'error', message: 'La réponse a été interrompue.' });
    } catch (error) {
      if (error && error.name === 'AbortError') return;
      safePost(port, { requestId, type: 'error', message: error.message });
    }
  }

  // Conversations are kept per tab in session storage (memory only, cleared
  // when Safari quits) so a reload does not lose the thread.
  async function saveConversation(tabId, conversation) {
    const key = 'conversation:' + tabId;
    if (sessionStore) {
      try {
        await sessionStore.set({ [key]: conversation });
        return;
      } catch (error) {
        // Fall back to memory.
      }
    }
    memoryConversations.set(key, conversation);
  }

  async function loadConversation(tabId) {
    const key = 'conversation:' + tabId;
    if (sessionStore) {
      try {
        const stored = await sessionStore.get(key);
        if (stored && stored[key]) return stored[key];
      } catch (error) {
        // Fall back to memory.
      }
    }
    return memoryConversations.get(key) || null;
  }

  if (api.tabs && api.tabs.onRemoved) {
    api.tabs.onRemoved.addListener((tabId) => {
      const key = 'conversation:' + tabId;
      memoryConversations.delete(key);
      if (sessionStore) {
        sessionStore.remove(key).catch(() => {});
      }
    });
  }

  api.runtime.onConnect.addListener((port) => {
    if (port.name !== 'wisper-agent') return;
    const tabId = port.sender && port.sender.tab ? port.sender.tab.id : 'unknown';
    const controllers = new Map();

    port.onMessage.addListener(async (message) => {
      const requestId = message.requestId;
      try {
        switch (message.type) {
          case 'status': {
            const response = await request('/v1/status');
            reply(port, requestId, true, await response.json());
            break;
          }
          case 'warmup': {
            const response = await request('/v1/warmup', { method: 'POST', body: message.payload || {} });
            reply(port, requestId, true, await response.json());
            break;
          }
          case 'chat': {
            const controller = new AbortController();
            controllers.set(requestId, controller);
            await streamChat(port, requestId, message.payload, controller);
            controllers.delete(requestId);
            break;
          }
          case 'cancel': {
            const controller = controllers.get(message.targetId);
            if (controller) controller.abort();
            controllers.delete(message.targetId);
            break;
          }
          case 'saveConversation':
            await saveConversation(tabId, message.payload);
            break;
          case 'loadConversation':
            reply(port, requestId, true, await loadConversation(tabId));
            break;
          default:
            break;
        }
      } catch (error) {
        reply(port, requestId, false, null, error.message);
      }
    });

    port.onDisconnect.addListener(() => {
      for (const controller of controllers.values()) controller.abort();
      controllers.clear();
    });
  });
})();
