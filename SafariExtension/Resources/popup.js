(() => {
  'use strict';

  const core = globalThis.WisperAgentCore;
  const api = globalThis.browser || globalThis.chrome;
  const codeInput = document.getElementById('code');
  const status = document.getElementById('status');

  function show(text, kind) {
    status.textContent = text;
    status.className = kind || '';
  }

  async function check(pairing) {
    const response = await fetch('http://127.0.0.1:' + pairing.port + '/v1/status', {
      headers: { Authorization: 'Bearer ' + pairing.token },
      cache: 'no-store'
    });
    if (response.status === 401) throw new Error("Code refusé par Wisper : copiez le code actuel.");
    if (!response.ok) throw new Error('Wisper a répondu ' + response.status + '.');
    return response.json();
  }

  async function refresh() {
    const stored = await api.storage.local.get('pairing');
    const pairing = stored && stored.pairing;
    if (!pairing) {
      show('Non associé.');
      return;
    }
    try {
      const data = await check(pairing);
      show('Connecté à ' + (data.app || 'Wisper') + ' (127.0.0.1:' + pairing.port + ').', 'ok');
    } catch (error) {
      show(error.message.startsWith('Code') ? error.message : "Associé, mais Wisper est injoignable : lancez l'app et activez l'agent Safari.", 'error');
    }
  }

  document.getElementById('pair').addEventListener('click', async () => {
    const pairing = core.parsePairingCode(codeInput.value);
    if (!pairing) {
      show('Code invalide : il commence par « wisper-agent: ».', 'error');
      return;
    }
    try {
      await check(pairing);
    } catch (error) {
      show(error.message.startsWith('Code') ? error.message : "Wisper est injoignable : lancez l'app et activez l'agent Safari.", 'error');
      return;
    }
    await api.storage.local.set({ pairing });
    codeInput.value = '';
    refresh();
  });

  document.getElementById('unpair').addEventListener('click', async () => {
    await api.storage.local.remove('pairing');
    refresh();
  });

  refresh();
})();
