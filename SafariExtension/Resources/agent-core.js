// Pure helpers shared by the content script, the background worker and the
// popup. No DOM or extension API access here so the Swift test suite can load
// this file in JavaScriptCore and exercise it deterministically.
(function (root) {
  'use strict';

  // MARK: - Double tap on Control

  // A tap counts only when Control is pressed and released on its own: any
  // other key, modifier or pointer press in between cancels it, so chords
  // such as Ctrl+C or Ctrl+click never open the agent.
  function createDoubleTapDetector(options) {
    const maxHoldMs = (options && options.maxHoldMs) || 350;
    const maxGapMs = (options && options.maxGapMs) || 400;
    let downAt = null;
    let lastTapAt = null;

    function reset() {
      downAt = null;
      lastTapAt = null;
    }

    return {
      // Returns nothing; only key releases can complete a tap.
      keyDown(event) {
        if (event.key === 'Control') {
          if (event.repeat) {
            return;
          }
          if (event.shiftKey || event.altKey || event.metaKey) {
            reset();
            return;
          }
          downAt = event.time;
          return;
        }
        reset();
      },
      // Returns 'double' when the second clean tap completes, 'single' after a
      // first clean tap, otherwise null.
      keyUp(event) {
        if (event.key !== 'Control') {
          return null;
        }
        if (downAt === null) {
          return null;
        }
        const held = event.time - downAt;
        downAt = null;
        if (held < 0 || held > maxHoldMs) {
          lastTapAt = null;
          return null;
        }
        if (lastTapAt !== null && event.time - lastTapAt <= maxGapMs) {
          lastTapAt = null;
          return 'double';
        }
        lastTapAt = event.time;
        return 'single';
      },
      pointerDown() {
        reset();
      },
      reset
    };
  }

  // MARK: - Page text cleanup

  function collapseWhitespace(text) {
    return String(text || '').replace(/\s+/g, ' ').trim();
  }

  // Blocks come from the content script as { t, x, l?, v?, s?, ld? }:
  // t = kind, x = text, l = heading level, v = visible in the viewport,
  // s = part of the user's selection, ld = share of the text inside links.
  // Removes empty blocks, link farms (menus, tag clouds) and short blocks
  // repeated across the page (navigation echoed in headers and footers).
  function cleanBlocks(blocks) {
    const seenShort = new Set();
    const cleaned = [];
    for (const block of blocks || []) {
      const text = block.t === 'pre' ? String(block.x || '').trim() : collapseWhitespace(block.x);
      if (!text) {
        continue;
      }
      if (!block.s && block.t !== 'h' && (block.ld || 0) > 0.6 && text.length < 300) {
        continue;
      }
      if (!block.s && text.length < 200) {
        const key = block.t + '|' + text.toLowerCase();
        if (seenShort.has(key)) {
          continue;
        }
        seenShort.add(key);
      }
      const out = { t: block.t, x: text };
      if (block.l) out.l = block.l;
      if (block.v) out.v = 1;
      if (block.s) out.s = 1;
      cleaned.push(out);
    }
    return cleaned;
  }

  // Query strings and fragments often carry session identifiers or search
  // terms; only the origin and path are useful context for the model.
  function sanitizeUrl(rawUrl) {
    const match = /^([a-z][a-z0-9+.-]*:\/\/[^/?#]*)([^?#]*)/i.exec(String(rawUrl || ''));
    if (!match) {
      return '';
    }
    return match[1] + (match[2] || '/');
  }

  function estimateTokens(text) {
    const length = String(text || '').length;
    return length === 0 ? 0 : Math.ceil(length / 3.5);
  }

  // MARK: - Pairing

  // Format shown in Wisper's settings: wisper-agent:<port>:<token>
  function parsePairingCode(code) {
    const match = /^\s*wisper-agent:(\d{2,5}):([A-Za-z0-9_-]{32,128})\s*$/.exec(String(code || ''));
    if (!match) {
      return null;
    }
    const port = Number(match[1]);
    if (port < 1024 || port > 65535) {
      return null;
    }
    return { port, token: match[2] };
  }

  // MARK: - Server-sent events

  // Splits a growing text buffer into complete SSE events. Returns the parsed
  // JSON payloads and the unconsumed remainder to prepend to the next chunk.
  function parseEventStream(buffer) {
    const normalized = String(buffer || '').replace(/\r\n/g, '\n');
    const parts = normalized.split('\n\n');
    const rest = parts.pop();
    const events = [];
    for (const part of parts) {
      const data = part
        .split('\n')
        .filter((line) => line.startsWith('data:'))
        .map((line) => line.slice(5).replace(/^ /, ''))
        .join('\n');
      if (!data) {
        continue;
      }
      try {
        events.push(JSON.parse(data));
      } catch (error) {
        // A malformed event is skipped rather than aborting the stream.
      }
    }
    return { events, rest };
  }

  // MARK: - Markdown

  // Model output is untrusted. Instead of producing HTML, the parser returns a
  // small tree that the content script turns into DOM nodes with textContent,
  // so no model text can ever be interpreted as markup.
  const INLINE_PATTERN = /(`[^`\n]+`)|(\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\))|(\*\*([^*\n]+)\*\*)|(\[([^\]\n]*\bp\.\s*\d+[^\]\n]*)\])|(\*([^*\n]+)\*)/g;

  function parseInline(text) {
    const nodes = [];
    const pattern = new RegExp(INLINE_PATTERN.source, 'g');
    let lastIndex = 0;
    let match;
    const source = String(text || '');
    while ((match = pattern.exec(source)) !== null) {
      if (match.index > lastIndex) {
        nodes.push({ type: 'text', text: source.slice(lastIndex, match.index) });
      }
      if (match[1]) {
        nodes.push({ type: 'code', text: match[1].slice(1, -1) });
      } else if (match[2]) {
        nodes.push({ type: 'link', href: match[4], text: match[3] });
      } else if (match[5]) {
        nodes.push({ type: 'strong', children: parseInline(match[6]) });
      } else if (match[7]) {
        nodes.push({ type: 'cite', text: match[8] });
      } else if (match[9]) {
        nodes.push({ type: 'em', children: parseInline(match[10]) });
      }
      lastIndex = match.index + match[0].length;
    }
    if (lastIndex < source.length) {
      nodes.push({ type: 'text', text: source.slice(lastIndex) });
    }
    return nodes;
  }

  function parseMarkdown(text) {
    const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
    const blocks = [];
    let paragraph = [];
    let list = null;

    function flushParagraph() {
      if (paragraph.length) {
        blocks.push({ type: 'p', lines: paragraph.map(parseInline) });
        paragraph = [];
      }
    }
    function flushList() {
      if (list) {
        blocks.push(list);
        list = null;
      }
    }

    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      const fence = /^\s*```/.exec(line);
      if (fence) {
        flushParagraph();
        flushList();
        const code = [];
        index++;
        while (index < lines.length && !/^\s*```/.test(lines[index])) {
          code.push(lines[index]);
          index++;
        }
        blocks.push({ type: 'pre', text: code.join('\n') });
        continue;
      }
      if (!line.trim()) {
        flushParagraph();
        flushList();
        continue;
      }
      const heading = /^\s*(#{1,6})\s+(.*)$/.exec(line);
      if (heading) {
        flushParagraph();
        flushList();
        blocks.push({ type: 'h', level: heading[1].length, children: parseInline(heading[2]) });
        continue;
      }
      const bullet = /^\s*[-*•]\s+(.*)$/.exec(line);
      const ordered = /^\s*\d+[.)]\s+(.*)$/.exec(line);
      if (bullet || ordered) {
        flushParagraph();
        const kind = bullet ? 'ul' : 'ol';
        if (!list || list.type !== kind) {
          flushList();
          list = { type: kind, items: [] };
        }
        list.items.push(parseInline((bullet || ordered)[1]));
        continue;
      }
      flushList();
      paragraph.push(line.trim());
    }
    flushParagraph();
    flushList();
    return blocks;
  }

  root.WisperAgentCore = {
    createDoubleTapDetector,
    collapseWhitespace,
    cleanBlocks,
    sanitizeUrl,
    estimateTokens,
    parsePairingCode,
    parseEventStream,
    parseInline,
    parseMarkdown
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
