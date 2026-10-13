// Wisper Agent content script: double Control toggles an in-page panel that
// answers questions about the page, the user's selection and a PDF library.
// The panel lives inside the page (closed shadow root) so the browser window
// never loses focus, and the user's interactions with it are not delivered to
// the page's own scripts.
(() => {
  'use strict';

  if (window.top !== window || globalThis.__wisperAgentLoaded) {
    return;
  }
  globalThis.__wisperAgentLoaded = true;

  const core = globalThis.WisperAgentCore;
  const api = globalThis.browser || globalThis.chrome;
  const MAX_PAGE_CHARACTERS = 250000;
  const MAX_SELECTION_CHARACTERS = 6000;

  const state = {
    host: null,
    shadow: null,
    ui: {},
    open: false,
    port: null,
    nextRequestId: 1,
    pending: new Map(),
    activeChat: null,
    models: [],
    libraries: [],
    model: '',
    libraryId: '',
    conversation: { id: newConversationId(), messages: [] },
    selection: null,
    selectionRoot: null,
    previousFocus: null,
    pageDirty: true,
    page: null,
    picking: false,
    pickTarget: null,
    drag: null,
    renderScheduled: false
  };

  const detector = core.createDoubleTapDetector({});

  function newConversationId() {
    return 'c-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
  }

  // MARK: - Shortcut and event isolation

  // Registered at document_start, before any page script, so these listeners
  // run first in the capture phase.
  const ISOLATED_EVENTS = [
    'keydown', 'keyup', 'keypress', 'beforeinput', 'input',
    'compositionstart', 'compositionupdate', 'compositionend',
    'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu',
    'pointerdown', 'pointerup', 'touchstart', 'touchend', 'wheel',
    'copy', 'cut', 'paste', 'selectstart', 'dragstart'
  ];

  const PASSIVE_EVENTS = new Set(['wheel', 'touchstart', 'touchend']);
  for (const type of ISOLATED_EVENTS) {
    // Scroll-related listeners stay passive so the page keeps scrolling smoothly.
    window.addEventListener(type, onWindowEvent, { capture: true, passive: PASSIVE_EVENTS.has(type) });
  }
  window.addEventListener('mousemove', onPointerMove, { capture: true, passive: true });
  window.addEventListener('blur', () => detector.reset(), { capture: true });
  document.addEventListener('selectionchange', onSelectionChange, { capture: true });

  function onWindowEvent(event) {
    if (event.type === 'keydown' && !event.isComposing) {
      detector.keyDown({
        key: event.key,
        time: event.timeStamp,
        repeat: event.repeat,
        shiftKey: event.shiftKey,
        altKey: event.altKey,
        metaKey: event.metaKey
      });
    } else if (event.type === 'keyup') {
      const tap = detector.keyUp({ key: event.key, time: event.timeStamp });
      if (tap === 'single') {
        // Likely the first half of a double tap: extract the page now so the
        // panel opens with its context ready.
        setTimeout(preparePage, 0);
      } else if (tap === 'double') {
        toggle();
      }
    } else if (event.type === 'mousedown' || event.type === 'pointerdown') {
      detector.pointerDown();
    } else if (event.type === 'mouseup') {
      state.drag = null;
    }

    if (!state.host) {
      return;
    }

    if (isFromAgent(event)) {
      routeAgentEvent(event);
      // Keystrokes and clicks inside the panel stay private: the page's
      // listeners (shortcuts, analytics, click-outside handlers) never see them.
      event.stopImmediatePropagation();
      return;
    }

    if (state.picking) {
      handlePickerEvent(event);
    }
  }

  function isFromAgent(event) {
    return state.open && typeof event.composedPath === 'function' && event.composedPath().includes(state.host);
  }

  // MARK: - Panel lifecycle

  function toggle() {
    if (state.open) {
      close();
    } else {
      open();
    }
  }

  function open() {
    captureSelection();
    ensureUI();
    state.open = true;
    state.host.style.setProperty('display', 'block', 'important');
    if (typeof state.host.showPopover === 'function') {
      try {
        if (state.host.matches(':popover-open')) {
          state.host.hidePopover();
        }
        state.host.showPopover();
      } catch (error) {
        // Top layer unavailable: the fixed position and z-index still apply.
      }
    }
    preparePage();
    renderAll();
    connect();
    // Warm Wisper first (TLS to the provider, PDF index, page chunks) while
    // the user starts typing; the conversation is restored in parallel.
    sendWarmup();
    requestStatus();
    restoreConversation();
    state.ui.input.focus({ preventScroll: true });
  }

  function close() {
    stopPicking();
    state.open = false;
    if (state.host) {
      if (typeof state.host.hidePopover === 'function') {
        try {
          state.host.hidePopover();
        } catch (error) {
          // Not in the top layer.
        }
      }
      state.host.style.setProperty('display', 'none', 'important');
    }
    restoreFocus();
  }

  // MARK: - Selection and focus

  function isEditable(element) {
    if (!element || element === state.host) return false;
    if (element.isContentEditable) return true;
    if (element.tagName === 'TEXTAREA') return true;
    if (element.tagName === 'INPUT') {
      const type = (element.getAttribute('type') || 'text').toLowerCase();
      return ['text', 'search', 'email', 'url', 'tel', 'number', ''].includes(type);
    }
    return false;
  }

  function isSensitiveField(element) {
    if (!element) return false;
    const type = (element.getAttribute && element.getAttribute('type') || '').toLowerCase();
    const autocomplete = (element.getAttribute && element.getAttribute('autocomplete') || '').toLowerCase();
    return type === 'password' || /^cc-|one-time-code|current-password|new-password/.test(autocomplete);
  }

  function fieldLabel(element) {
    if (!element) return '';
    const fromLabels = element.labels && element.labels.length ? element.labels[0].innerText : '';
    const labelledBy = element.getAttribute('aria-labelledby');
    const fromLabelledBy = labelledBy
      ? labelledBy.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((node) => node.innerText).join(' ')
      : '';
    return core.collapseWhitespace(
      fromLabels || fromLabelledBy || element.getAttribute('aria-label') || element.getAttribute('placeholder') ||
      element.getAttribute('title') || element.getAttribute('name') || ''
    ).slice(0, 200);
  }

  function describeElement(element) {
    const heading = element.querySelector && element.querySelector('h1,h2,h3,h4,legend,label');
    const text = heading ? heading.innerText : (element.getAttribute('aria-label') || element.tagName.toLowerCase());
    return core.collapseWhitespace(text).slice(0, 120);
  }

  function captureSelection() {
    const active = document.activeElement;
    state.previousFocus = null;
    if (active && active !== document.body && active !== state.host) {
      const saved = { element: active };
      if (typeof active.selectionStart === 'number') {
        saved.start = active.selectionStart;
        saved.end = active.selectionEnd;
      }
      const selection = document.getSelection();
      if (selection && selection.rangeCount) {
        saved.range = selection.getRangeAt(0).cloneRange();
      }
      state.previousFocus = saved;
    }

    const selection = document.getSelection();
    const text = selection ? selection.toString().trim() : '';
    if (text && !(state.host && state.host.contains(selection.anchorNode))) {
      const range = selection.getRangeAt(0);
      const container = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
        ? range.commonAncestorContainer
        : range.commonAncestorContainer.parentElement;
      setSelection({ kind: 'text', label: '', text: text.slice(0, MAX_SELECTION_CHARACTERS) }, container);
      return;
    }

    if (isEditable(active) && !isSensitiveField(active)) {
      const value = active.isContentEditable ? active.innerText : active.value;
      setSelection({ kind: 'field', label: fieldLabel(active), text: String(value || '').slice(0, MAX_SELECTION_CHARACTERS) }, active);
    }
  }

  function setSelection(selection, root) {
    state.selection = selection;
    state.selectionRoot = root || null;
    state.pageDirty = true;
    if (state.open) {
      renderChips();
    }
  }

  function onSelectionChange() {
    if (!state.open || state.picking) return;
    const selection = document.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;
    if (state.host && state.host.contains(selection.anchorNode)) return;
    const text = selection.toString().trim();
    if (!text) return;
    const range = selection.getRangeAt(0);
    const container = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
      ? range.commonAncestorContainer
      : range.commonAncestorContainer.parentElement;
    setSelection({ kind: 'text', label: '', text: text.slice(0, MAX_SELECTION_CHARACTERS) }, container);
  }

  function restoreFocus() {
    const saved = state.previousFocus;
    state.previousFocus = null;
    if (!saved || !saved.element || !saved.element.isConnected) return;
    try {
      saved.element.focus({ preventScroll: true });
      if (typeof saved.start === 'number' && typeof saved.element.setSelectionRange === 'function') {
        saved.element.setSelectionRange(saved.start, saved.end);
      } else if (saved.range) {
        const selection = document.getSelection();
        selection.removeAllRanges();
        selection.addRange(saved.range);
      }
    } catch (error) {
      // The element may no longer accept focus; nothing to restore.
    }
  }

  // MARK: - Element picker

  function startPicking() {
    state.picking = true;
    state.ui.panel.classList.add('picking');
    state.ui.highlight.style.display = 'none';
  }

  function stopPicking() {
    state.picking = false;
    state.pickTarget = null;
    if (state.ui.panel) {
      state.ui.panel.classList.remove('picking');
      state.ui.highlight.style.display = 'none';
    }
  }

  function onPointerMove(event) {
    if (state.drag) {
      const dx = event.clientX - state.drag.x;
      const dy = event.clientY - state.drag.y;
      state.ui.panel.style.right = Math.max(0, state.drag.right - dx) + 'px';
      state.ui.panel.style.bottom = Math.max(0, state.drag.bottom - dy) + 'px';
      return;
    }
    if (!state.picking) return;
    const target = document.elementFromPoint(event.clientX, event.clientY);
    if (!target || target === state.host || target === document.documentElement || target === document.body) {
      state.ui.highlight.style.display = 'none';
      state.pickTarget = null;
      return;
    }
    state.pickTarget = target;
    const rect = target.getBoundingClientRect();
    Object.assign(state.ui.highlight.style, {
      display: 'block',
      left: rect.left + 'px',
      top: rect.top + 'px',
      width: rect.width + 'px',
      height: rect.height + 'px'
    });
  }

  function handlePickerEvent(event) {
    if (event.type === 'keydown' && event.key === 'Escape') {
      event.preventDefault();
      event.stopImmediatePropagation();
      stopPicking();
      return;
    }
    if (!['mousedown', 'mouseup', 'click', 'pointerdown', 'pointerup', 'auxclick', 'dblclick'].includes(event.type)) {
      return;
    }
    // While picking, clicks select an element instead of activating the page.
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.type !== 'click') return;
    const target = state.pickTarget || document.elementFromPoint(event.clientX, event.clientY);
    stopPicking();
    if (!target || target === state.host) return;
    if (isEditable(target) && !isSensitiveField(target)) {
      const value = target.isContentEditable ? target.innerText : target.value;
      setSelection({ kind: 'field', label: fieldLabel(target), text: String(value || '').slice(0, MAX_SELECTION_CHARACTERS) }, target);
    } else if (!isSensitiveField(target)) {
      const text = core.collapseWhitespace(target.innerText || '').slice(0, MAX_SELECTION_CHARACTERS);
      setSelection({ kind: 'element', label: describeElement(target), text }, target);
    }
    state.ui.input.focus({ preventScroll: true });
  }

  // MARK: - Page extraction

  const SKIP_SELECTOR = [
    'script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe', 'object', 'embed', 'video', 'audio',
    'nav', 'footer', 'aside', 'dialog:not([open])', 'option', 'optgroup', 'datalist',
    '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]', '[role="complementary"]', '[role="search"]',
    '[aria-hidden="true"]', '[hidden]', 'wisper-agent-root'
  ].join(',');
  const BLOCK_SELECTOR = 'h1,h2,h3,h4,h5,h6,p,li,dt,dd,blockquote,pre,figcaption,caption,tr,label,legend,summary,button,div,section,article,main,form,fieldset,body';
  const NOISE_PATTERN = /(^|[\s_-])(ad|ads|advert|advertisement|sponsor|sponsored|promo|cookie|cookies|consent|gdpr|newsletter|share|sharing|social|related|recommended|outbrain|taboola)([\s_-]|$)/i;

  function shouldSkip(element) {
    if (element.matches(SKIP_SELECTOR)) return true;
    if (element.tagName === 'HEADER' && !element.closest('main,article')) return true;
    const marker = (element.id || '') + ' ' + (element.getAttribute('class') || '');
    if (marker.length > 1 && NOISE_PATTERN.test(marker)) return true;
    if (typeof element.checkVisibility === 'function' && !element.checkVisibility({ checkVisibilityCSS: true })) return true;
    return false;
  }

  function contentRoot() {
    const body = document.body;
    if (!body) return null;
    const total = body.textContent.length || 1;
    let best = null;
    for (const candidate of document.querySelectorAll('main,[role="main"],article')) {
      const length = candidate.textContent.length;
      if (length / total >= 0.35 && (!best || length > best.textContent.length)) {
        best = candidate;
      }
    }
    return best || body;
  }

  function extractPage() {
    const root = contentRoot();
    const blocks = [];
    if (!root) {
      return { url: core.sanitizeUrl(location.href), title: document.title, blocks };
    }
    const viewportHeight = window.innerHeight;
    const selectionRoot = state.selectionRoot;
    let current = null;
    let characters = 0;

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.nodeType === Node.TEXT_NODE) {
          return node.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        }
        if (shouldSkip(node)) return NodeFilter.FILTER_REJECT;
        if (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA' || node.tagName === 'SELECT') {
          return NodeFilter.FILTER_ACCEPT;
        }
        return NodeFilter.FILTER_SKIP;
      }
    });

    function finish() {
      if (!current) return;
      const block = { t: current.kind, x: current.text };
      if (current.level) block.l = current.level;
      if (current.text.length) block.ld = current.linkLength / current.text.length;
      const rect = current.element.getBoundingClientRect();
      if (rect.bottom > 0 && rect.top < viewportHeight && rect.height > 0) block.v = 1;
      if (selectionRoot && (selectionRoot.contains(current.element) || current.element.contains(selectionRoot))) block.s = 1;
      blocks.push(block);
      current = null;
    }

    function kindOf(element) {
      const tag = element.tagName;
      if (/^H[1-6]$/.test(tag)) return { kind: 'h', level: Number(tag[1]) };
      if (tag === 'LI' || tag === 'DT' || tag === 'DD') return { kind: 'li' };
      if (tag === 'PRE') return { kind: 'pre' };
      if (tag === 'TR') return { kind: 'row' };
      return { kind: 'p' };
    }

    let node;
    while ((node = walker.nextNode()) && characters < MAX_PAGE_CHARACTERS) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        // Form fields contribute their label only; values typed by the user
        // are never read unless that field is the explicit selection.
        finish();
        if (isSensitiveField(node) || node.type === 'hidden') continue;
        const label = fieldLabel(node);
        if (label) {
          current = { element: node, kind: 'field', text: label, linkLength: 0 };
          finish();
        }
        continue;
      }
      const parent = node.parentElement;
      const element = parent.closest(BLOCK_SELECTOR) || parent;
      const text = node.nodeValue;
      const inLink = Boolean(parent.closest('a'));
      if (!current || current.element !== element) {
        finish();
        const kind = kindOf(element);
        current = { element, kind: kind.kind, level: kind.level, text: '', linkLength: 0 };
      }
      const separator = current.kind === 'row' && current.text && parent.closest('td,th') !== current.lastCell ? ' | ' : ' ';
      if (current.kind === 'row') current.lastCell = parent.closest('td,th');
      const addition = current.kind === 'pre' ? text : text.replace(/\s+/g, ' ');
      current.text += current.text && current.kind !== 'pre' ? separator + addition.trim() : addition;
      if (inLink) current.linkLength += addition.trim().length;
      characters += addition.length;
    }
    finish();

    return {
      url: core.sanitizeUrl(location.href),
      title: document.title,
      blocks: core.cleanBlocks(blocks)
    };
  }

  function preparePage() {
    if (!state.pageDirty && state.page) return state.page;
    try {
      state.page = extractPage();
    } catch (error) {
      state.page = { url: core.sanitizeUrl(location.href), title: document.title, blocks: [] };
    }
    state.pageDirty = false;
    if (state.open) renderChips();
    return state.page;
  }

  new MutationObserver((records) => {
    for (const record of records) {
      if (!state.host || !state.host.contains(record.target)) {
        state.pageDirty = true;
        return;
      }
    }
  }).observe(document, { childList: true, subtree: true, characterData: true });

  // MARK: - Background connection

  function connect() {
    if (state.port) return state.port;
    try {
      state.port = api.runtime.connect({ name: 'wisper-agent' });
    } catch (error) {
      showNotice("L'extension a été rechargée : actualisez la page.");
      return null;
    }
    state.port.onMessage.addListener(onPortMessage);
    state.port.onDisconnect.addListener(() => {
      state.port = null;
      for (const [, pending] of state.pending) {
        pending({ ok: false, error: 'Connexion avec l’extension interrompue.' });
      }
      state.pending.clear();
      if (state.activeChat) finishChat({ type: 'error', message: 'Connexion avec l’extension interrompue.' });
    });
    return state.port;
  }

  function post(message, onReply) {
    const port = connect();
    if (!port) return null;
    const requestId = state.nextRequestId++;
    if (onReply) state.pending.set(requestId, onReply);
    port.postMessage(Object.assign({ requestId }, message));
    return requestId;
  }

  function onPortMessage(message) {
    if (state.activeChat && message.requestId === state.activeChat.requestId) {
      handleChatEvent(message);
      return;
    }
    const pending = state.pending.get(message.requestId);
    if (pending) {
      state.pending.delete(message.requestId);
      pending(message);
    }
  }

  function requestStatus() {
    post({ type: 'status' }, (reply) => {
      if (!reply.ok) {
        showNotice(reply.error || 'Wisper est injoignable.');
        return;
      }
      const data = reply.data || {};
      state.models = data.models || [];
      state.libraries = data.libraries || [];
      if (!state.model) state.model = data.defaultModel || (state.models[0] && state.models[0].id) || '';
      if (state.libraryId && !state.libraries.some((library) => library.id === state.libraryId)) {
        state.libraryId = '';
      }
      showNotice(data.hasAPIKey ? '' : 'Ajoutez votre clé OpenRouter dans Wisper → Réglages → Intelligence IA.');
      renderSelectors();
      renderChips();
    });
  }

  function sendWarmup() {
    post({ type: 'warmup', payload: { libraryId: state.libraryId || null, page: preparePage() } }, (reply) => {
      if (reply.ok && reply.data) {
        state.libraries = reply.data.libraries || state.libraries;
        renderChips();
      }
    });
  }

  async function loadPreferences() {
    try {
      const stored = await api.storage.local.get(['model', 'libraryId']);
      if (stored.model) state.model = stored.model;
      if (stored.libraryId) state.libraryId = stored.libraryId;
    } catch (error) {
      // Defaults apply.
    }
  }

  function savePreferences() {
    try {
      api.storage.local.set({ model: state.model, libraryId: state.libraryId });
    } catch (error) {
      // Preferences are a convenience only.
    }
  }

  function restoreConversation() {
    return new Promise((resolve) => {
      if (state.conversation.messages.length) {
        resolve();
        return;
      }
      const requestId = post({ type: 'loadConversation' }, (reply) => {
        if (reply.ok && reply.data && Array.isArray(reply.data.messages) && reply.data.messages.length) {
          state.conversation = reply.data;
          renderMessages();
        }
        resolve();
      });
      if (requestId === null) resolve();
    });
  }

  function saveConversation() {
    const messages = state.conversation.messages
      .filter((message) => !message.pending)
      .map((message) => ({ role: message.role, content: message.content, sources: message.sources || [], error: message.error || '' }));
    post({ type: 'saveConversation', payload: { id: state.conversation.id, messages } });
  }

  // MARK: - Chat

  function sendQuestion() {
    const question = state.ui.input.value.trim();
    if (!question || state.activeChat) return;
    state.ui.input.value = '';
    autoResize();

    const history = state.conversation.messages
      .filter((message) => !message.error && message.content)
      .map((message) => ({ role: message.role, content: message.content }));
    state.conversation.messages.push({ role: 'user', content: question });
    const answer = { role: 'assistant', content: '', pending: true, sources: [] };
    state.conversation.messages.push(answer);
    renderMessages();

    const payload = {
      conversationId: state.conversation.id,
      model: state.model,
      libraryId: state.libraryId || null,
      page: preparePage(),
      selection: state.selection,
      history,
      question
    };
    const requestId = post({ type: 'chat', payload });
    if (requestId === null) {
      answer.pending = false;
      answer.error = 'Extension indisponible.';
      renderMessages();
      return;
    }
    state.activeChat = { requestId, answer };
    renderComposer();
  }

  function handleChatEvent(event) {
    const chat = state.activeChat;
    if (!chat) return;
    if (event.type === 'meta') {
      chat.answer.sources = event.sources || [];
      chat.answer.meta = event;
    } else if (event.type === 'delta') {
      chat.answer.content += event.text || '';
      scheduleRender();
    } else if (event.type === 'done' || event.type === 'error') {
      finishChat(event);
    }
  }

  function finishChat(event) {
    const chat = state.activeChat;
    if (!chat) return;
    chat.answer.pending = false;
    if (event.type === 'error') {
      chat.answer.error = event.message || 'Erreur inconnue.';
    }
    state.activeChat = null;
    renderMessages();
    renderComposer();
    saveConversation();
  }

  function cancelChat() {
    if (!state.activeChat) return;
    post({ type: 'cancel', targetId: state.activeChat.requestId });
    finishChat({ type: 'done' });
  }

  function newConversation() {
    cancelChat();
    state.conversation = { id: newConversationId(), messages: [] };
    saveConversation();
    renderMessages();
  }

  // MARK: - UI

  const STYLE = `
    :host { all: initial; }
    * { box-sizing: border-box; }
    .panel {
      position: fixed; right: 20px; bottom: 20px; width: 400px; max-width: calc(100vw - 24px);
      max-height: min(72vh, 680px); display: flex; flex-direction: column;
      font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      color: #1d1d1f; background: rgba(250, 250, 250, 0.97); border: 1px solid rgba(0, 0, 0, 0.12);
      border-radius: 14px; box-shadow: 0 18px 50px rgba(0, 0, 0, 0.22); pointer-events: auto; overflow: hidden;
      -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
    }
    .panel.picking { opacity: 0.55; }
    .header { display: flex; align-items: center; gap: 6px; padding: 8px 10px; border-bottom: 1px solid rgba(0,0,0,0.08); cursor: move; user-select: none; }
    .title { font-weight: 600; margin-right: auto; }
    select { font: inherit; font-size: 12px; max-width: 120px; padding: 2px 4px; border-radius: 6px; border: 1px solid rgba(0,0,0,0.15); background: transparent; color: inherit; }
    button { font: inherit; border: none; background: transparent; color: inherit; cursor: pointer; border-radius: 6px; padding: 3px 6px; }
    button:hover { background: rgba(0,0,0,0.07); }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; padding: 6px 10px; border-bottom: 1px solid rgba(0,0,0,0.06); }
    .chip { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: rgba(0,0,0,0.06); color: #555; display: inline-flex; align-items: center; gap: 4px; max-width: 100%; }
    .chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 260px; }
    .chip button { padding: 0 2px; font-size: 11px; }
    .messages { flex: 1; overflow-y: auto; overscroll-behavior: contain; padding: 10px; display: flex; flex-direction: column; gap: 10px; min-height: 60px; }
    .empty { color: #777; font-size: 12px; }
    .message.user { align-self: flex-end; background: #0a84ff; color: white; padding: 6px 10px; border-radius: 12px 12px 4px 12px; max-width: 85%; white-space: pre-wrap; }
    .message.assistant { align-self: stretch; }
    .message.assistant p { margin: 0 0 6px; }
    .message.assistant ul, .message.assistant ol { margin: 0 0 6px; padding-left: 20px; }
    .message.assistant h1, .message.assistant h2, .message.assistant h3, .message.assistant h4, .message.assistant h5, .message.assistant h6 { font-size: 13px; margin: 8px 0 4px; }
    .message.assistant pre { background: rgba(0,0,0,0.06); padding: 8px; border-radius: 8px; overflow-x: auto; font: 12px ui-monospace, Menlo, monospace; white-space: pre; }
    .message.assistant code { font: 12px ui-monospace, Menlo, monospace; background: rgba(0,0,0,0.06); padding: 0 3px; border-radius: 4px; }
    .message.assistant a { color: #0a84ff; }
    .cite { font-size: 11px; background: rgba(10,132,255,0.12); color: #0a64c2; padding: 0 5px; border-radius: 4px; }
    .typing { color: #888; }
    .error { color: #c62828; font-size: 12px; }
    .sources { font-size: 11px; color: #777; margin-top: 4px; }
    .notice { margin: 0 10px 8px; padding: 6px 8px; font-size: 12px; border-radius: 8px; background: rgba(255,159,10,0.15); color: #8a5300; }
    .notice:empty { display: none; }
    .composer { display: flex; gap: 6px; align-items: flex-end; padding: 8px 10px; border-top: 1px solid rgba(0,0,0,0.08); }
    textarea { flex: 1; resize: none; font: inherit; color: inherit; background: white; border: 1px solid rgba(0,0,0,0.15); border-radius: 10px; padding: 6px 8px; min-height: 34px; max-height: 140px; outline: none; }
    textarea:focus { border-color: #0a84ff; }
    .send { background: #0a84ff; color: white; padding: 6px 12px; border-radius: 10px; }
    .send:hover { background: #0071e3; }
    .hint { font-size: 10px; color: #999; padding: 0 10px 6px; }
    .highlight { position: fixed; display: none; pointer-events: none; border: 2px solid #0a84ff; background: rgba(10,132,255,0.08); border-radius: 4px; }
    @media (prefers-color-scheme: dark) {
      .panel { color: #f5f5f7; background: rgba(40, 40, 42, 0.97); border-color: rgba(255,255,255,0.12); }
      .header, .composer { border-color: rgba(255,255,255,0.1); }
      .chips { border-color: rgba(255,255,255,0.08); }
      .chip { background: rgba(255,255,255,0.1); color: #ccc; }
      button:hover { background: rgba(255,255,255,0.1); }
      textarea { background: rgba(0,0,0,0.25); border-color: rgba(255,255,255,0.15); }
      select { border-color: rgba(255,255,255,0.2); }
      .message.assistant pre, .message.assistant code { background: rgba(255,255,255,0.08); }
      .cite { color: #6cb4ff; }
      .notice { color: #ffcc80; }
    }
  `;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function ensureUI() {
    if (state.host && state.host.isConnected) return;
    const host = document.createElement('wisper-agent-root');
    for (const [property, value] of Object.entries({
      all: 'initial', position: 'fixed', inset: '0', width: '100vw', height: '100vh', margin: '0', padding: '0',
      border: 'none', background: 'transparent', overflow: 'visible', 'pointer-events': 'none',
      'z-index': '2147483647', display: 'none'
    })) {
      host.style.setProperty(property, value, 'important');
    }
    if ('popover' in host) host.setAttribute('popover', 'manual');
    const shadow = host.attachShadow({ mode: 'closed' });

    if ('adoptedStyleSheets' in shadow && typeof CSSStyleSheet === 'function') {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(STYLE);
      shadow.adoptedStyleSheets = [sheet];
    } else {
      shadow.appendChild(element('style', '', STYLE));
    }

    const highlight = element('div', 'highlight');
    const panel = element('div', 'panel');
    const header = element('div', 'header');
    header.dataset.drag = '1';
    header.appendChild(element('span', 'title', 'Wisper'));
    const modelSelect = element('select');
    modelSelect.title = 'Modèle';
    const librarySelect = element('select');
    librarySelect.title = 'Bibliothèque de PDF';
    header.append(modelSelect, librarySelect);
    for (const [action, label, title] of [
      ['pick', '◎', 'Pointer un élément de la page'],
      ['new', '＋', 'Nouvelle conversation'],
      ['close', '✕', 'Fermer (Ctrl Ctrl)']
    ]) {
      const button = element('button', '', label);
      button.dataset.action = action;
      button.title = title;
      header.appendChild(button);
    }
    const chips = element('div', 'chips');
    const messages = element('div', 'messages');
    const notice = element('div', 'notice');
    const composer = element('div', 'composer');
    const input = element('textarea');
    input.rows = 1;
    input.placeholder = 'Posez une question sur cette page…';
    const send = element('button', 'send', 'Envoyer');
    send.dataset.action = 'send';
    composer.append(input, send);
    const hint = element('div', 'hint', 'Entrée : envoyer · Maj+Entrée : nouvelle ligne · Ctrl Ctrl ou Échap : fermer');
    panel.append(header, chips, messages, notice, composer, hint);
    shadow.append(highlight, panel);

    // Non-composed events never leave the shadow root; handle them inside.
    shadow.addEventListener('change', (event) => {
      if (event.target === modelSelect) {
        state.model = modelSelect.value;
        savePreferences();
      } else if (event.target === librarySelect) {
        state.libraryId = librarySelect.value;
        savePreferences();
        renderChips();
        sendWarmup();
      }
    });

    document.documentElement.appendChild(host);
    state.host = host;
    state.shadow = shadow;
    state.ui = { panel, header, chips, messages, notice, input, send, modelSelect, librarySelect, highlight };
  }

  // Window-level listeners only see the shadow host, so the real target is
  // resolved from the focused element (keyboard) or the pointer position.
  function internalTarget(event) {
    const pointerEvent = 'clientX' in event && !(event.type === 'click' && event.detail === 0);
    if (!pointerEvent) {
      return state.shadow.activeElement;
    }
    let hit = null;
    for (const candidate of state.shadow.querySelectorAll('[data-action], textarea, select, [data-drag]')) {
      const rect = candidate.getBoundingClientRect();
      if (event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom) {
        hit = candidate;
      }
    }
    return hit;
  }

  function routeAgentEvent(event) {
    const target = internalTarget(event);
    switch (event.type) {
      case 'keydown':
        if (event.key === 'Escape') {
          event.preventDefault();
          if (state.picking) stopPicking();
          else close();
        } else if (target === state.ui.input && event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
          event.preventDefault();
          sendQuestion();
        }
        break;
      case 'input':
        if (target === state.ui.input) autoResize();
        break;
      case 'mousedown':
        if (target && target.dataset && target.dataset.drag && event.button === 0) {
          const panelStyle = getComputedStyle(state.ui.panel);
          state.drag = { x: event.clientX, y: event.clientY, right: parseFloat(panelStyle.right) || 0, bottom: parseFloat(panelStyle.bottom) || 0 };
        }
        break;
      case 'click': {
        const action = target && target.dataset ? target.dataset.action : null;
        if (action === 'send') {
          if (state.activeChat) cancelChat();
          else sendQuestion();
        } else if (action === 'close') {
          close();
        } else if (action === 'new') {
          newConversation();
        } else if (action === 'pick') {
          if (state.picking) stopPicking();
          else startPicking();
        } else if (action === 'clear-selection') {
          setSelection(null, null);
        }
        break;
      }
      default:
        break;
    }
  }

  function autoResize() {
    const input = state.ui.input;
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 140) + 'px';
  }

  function showNotice(text) {
    if (state.ui.notice) state.ui.notice.textContent = text || '';
  }

  function renderAll() {
    renderSelectors();
    renderChips();
    renderMessages();
    renderComposer();
  }

  function renderSelectors() {
    const { modelSelect, librarySelect } = state.ui;
    if (!modelSelect) return;
    modelSelect.replaceChildren();
    const models = state.models.slice();
    if (state.model && !models.some((model) => model.id === state.model)) {
      models.unshift({ id: state.model, name: state.model.split('/').pop() });
    }
    for (const model of models) {
      const option = element('option', '', model.name);
      option.value = model.id;
      option.selected = model.id === state.model;
      modelSelect.appendChild(option);
    }
    librarySelect.replaceChildren();
    const none = element('option', '', 'Sans PDF');
    none.value = '';
    librarySelect.appendChild(none);
    for (const library of state.libraries) {
      const option = element('option', '', library.name);
      option.value = library.id;
      option.selected = library.id === state.libraryId;
      librarySelect.appendChild(option);
    }
  }

  function renderChips() {
    const { chips } = state.ui;
    if (!chips) return;
    chips.replaceChildren();
    const page = state.page;
    if (page) {
      const characters = page.blocks.reduce((sum, block) => sum + block.x.length, 0);
      const tokens = Math.ceil(characters / 3.5);
      const chip = element('span', 'chip');
      chip.appendChild(element('span', '', 'Page · ~' + (tokens < 1000 ? tokens : Math.round(tokens / 1000) + 'k') + ' tokens'));
      chip.title = page.title || page.url;
      chips.appendChild(chip);
    }
    if (state.selection) {
      const chip = element('span', 'chip');
      const kind = state.selection.kind === 'field' ? 'Champ' : state.selection.kind === 'element' ? 'Élément' : 'Sélection';
      const label = state.selection.label || state.selection.text;
      chip.appendChild(element('span', '', kind + ' · ' + core.collapseWhitespace(label).slice(0, 60)));
      const clear = element('button', '', '✕');
      clear.dataset.action = 'clear-selection';
      clear.title = 'Retirer la sélection';
      chip.appendChild(clear);
      chips.appendChild(chip);
    }
    const library = state.libraries.find((item) => item.id === state.libraryId);
    if (library) {
      const status = library.state === 'ready' ? library.passages + ' passages'
        : library.state === 'indexing' ? 'lecture des PDF…' : library.files + ' PDF';
      const chip = element('span', 'chip');
      chip.appendChild(element('span', '', library.name + ' · ' + status));
      chips.appendChild(chip);
    }
  }

  function scheduleRender() {
    if (state.renderScheduled) return;
    state.renderScheduled = true;
    requestAnimationFrame(() => {
      state.renderScheduled = false;
      renderMessages();
    });
  }

  function renderInline(parent, nodes) {
    for (const node of nodes) {
      if (node.type === 'text') {
        parent.appendChild(document.createTextNode(node.text));
      } else if (node.type === 'code') {
        parent.appendChild(element('code', '', node.text));
      } else if (node.type === 'strong' || node.type === 'em') {
        const wrapper = element(node.type);
        renderInline(wrapper, node.children);
        parent.appendChild(wrapper);
      } else if (node.type === 'cite') {
        parent.appendChild(element('span', 'cite', node.text));
      } else if (node.type === 'link') {
        const link = element('a', '', node.text);
        link.href = node.href;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        parent.appendChild(link);
      }
    }
  }

  function renderMarkdown(parent, text) {
    for (const block of core.parseMarkdown(text)) {
      if (block.type === 'p') {
        const paragraph = element('p');
        block.lines.forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement('br'));
          renderInline(paragraph, line);
        });
        parent.appendChild(paragraph);
      } else if (block.type === 'h') {
        const heading = element('h' + block.level);
        renderInline(heading, block.children);
        parent.appendChild(heading);
      } else if (block.type === 'ul' || block.type === 'ol') {
        const list = element(block.type);
        for (const item of block.items) {
          const entry = element('li');
          renderInline(entry, item);
          list.appendChild(entry);
        }
        parent.appendChild(list);
      } else if (block.type === 'pre') {
        const pre = element('pre');
        pre.appendChild(element('code', '', block.text));
        parent.appendChild(pre);
      }
    }
  }

  function renderMessages() {
    const { messages } = state.ui;
    if (!messages) return;
    const nearBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 40;
    messages.replaceChildren();
    if (!state.conversation.messages.length) {
      messages.appendChild(element('div', 'empty', 'Posez une question : l’agent connaît la page, votre sélection et la bibliothèque choisie. ◎ permet de pointer un élément précis.'));
    }
    for (const message of state.conversation.messages) {
      if (message.role === 'user') {
        messages.appendChild(element('div', 'message user', message.content));
        continue;
      }
      const bubble = element('div', 'message assistant');
      if (message.content) {
        renderMarkdown(bubble, message.content);
      } else if (message.pending) {
        bubble.appendChild(element('div', 'typing', '…'));
      }
      if (message.error) {
        bubble.appendChild(element('div', 'error', message.error));
      }
      if (!message.pending && message.sources && message.sources.length) {
        bubble.appendChild(element('div', 'sources', 'Sources : ' + message.sources.join(', ')));
      }
      messages.appendChild(bubble);
    }
    if (nearBottom || state.activeChat) {
      messages.scrollTop = messages.scrollHeight;
    }
  }

  function renderComposer() {
    if (!state.ui.send) return;
    state.ui.send.textContent = state.activeChat ? 'Arrêter' : 'Envoyer';
  }

  loadPreferences();
})();
