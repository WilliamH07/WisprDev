import Foundation
import JavaScriptCore

/// Exercises the Safari extension's pure JavaScript helpers in JavaScriptCore
/// and checks that every extension script parses.
struct SafariAgentScriptTests {
    private static let resources = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SafariExtension/Resources")

    static func run() {
        testScriptsParse()
        testCoreHelpers()
    }

    private static func source(_ name: String) -> String {
        let text = (try? String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)) ?? ""
        TestSupport.expect(!text.isEmpty, "\(name) is readable")
        return text
    }

    private static func testScriptsParse() {
        for name in ["agent-core.js", "content.js", "background.js", "popup.js"] {
            guard let context = JSContext() else {
                TestSupport.expect(false, "JavaScriptCore context")
                return
            }
            let script = JSStringCreateWithCFString(source(name) as CFString)
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            let valid = JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception)
            TestSupport.expect(valid && exception == nil, "\(name) must be valid JavaScript")
        }
    }

    private static func testCoreHelpers() {
        guard let context = JSContext() else {
            TestSupport.expect(false, "JavaScriptCore context")
            return
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, value in
            exceptionMessage = value?.toString()
        }
        context.evaluateScript(source("agent-core.js"))
        TestSupport.expect(exceptionMessage == nil, "agent-core.js loads: \(exceptionMessage ?? "")")

        let result = context.evaluateScript(coreTestScript)?.toString() ?? "no result"
        TestSupport.expectEqual(result, "ok")
    }

    private static let coreTestScript = #"""
    (function () {
      const c = globalThis.WisperAgentCore;
      function check(condition, message) { if (!condition) throw new Error(message); }
      function tap(detector, start, hold) {
        detector.keyDown({ key: 'Control', time: start });
        return detector.keyUp({ key: 'Control', time: start + (hold || 80) });
      }
      try {
        let d = c.createDoubleTapDetector({});
        check(tap(d, 0) === 'single', 'first tap');
        check(tap(d, 200) === 'double', 'second tap opens');
        check(tap(d, 350) === 'single', 'detector resets after a double tap');

        d = c.createDoubleTapDetector({});
        d.keyDown({ key: 'Control', time: 0 });
        d.keyDown({ key: 'c', time: 20 });
        check(d.keyUp({ key: 'Control', time: 60 }) === null, 'Ctrl+C is not a tap');
        check(tap(d, 100) === 'single', 'a chord never counts toward a double tap');

        d = c.createDoubleTapDetector({});
        tap(d, 0);
        check(tap(d, 900) === 'single', 'taps too far apart');
        d = c.createDoubleTapDetector({});
        check(tap(d, 0, 600) === null, 'long press is not a tap');
        d = c.createDoubleTapDetector({});
        tap(d, 0);
        d.pointerDown();
        check(tap(d, 150) === 'single', 'Ctrl+click cancels');
        d = c.createDoubleTapDetector({});
        d.keyDown({ key: 'Control', time: 0, shiftKey: true });
        check(d.keyUp({ key: 'Control', time: 50 }) === null, 'Ctrl with another modifier is not a tap');
        d = c.createDoubleTapDetector({});
        d.keyDown({ key: 'Control', time: 0 });
        d.keyDown({ key: 'Control', time: 30, repeat: true });
        check(d.keyUp({ key: 'Control', time: 60 }) === 'single', 'key repeat ignored');

        const cleaned = c.cleanBlocks([
          { t: 'p', x: '  Bonjour \n le monde ' },
          { t: 'p', x: 'Menu' },
          { t: 'p', x: 'menu' },
          { t: 'p', x: 'Accueil Boutique', ld: 0.9 },
          { t: 'p', x: 'Lien choisi', ld: 0.9, s: 1 },
          { t: 'h', x: 'Titre', l: 2, v: 1 },
          { t: 'p', x: '' }
        ]);
        check(JSON.stringify(cleaned) === JSON.stringify([
          { t: 'p', x: 'Bonjour le monde' },
          { t: 'p', x: 'Menu' },
          { t: 'p', x: 'Lien choisi', s: 1 },
          { t: 'h', x: 'Titre', l: 2, v: 1 }
        ]), 'cleanBlocks: ' + JSON.stringify(cleaned));

        check(c.sanitizeUrl('https://ex.com/a/b?token=1#x') === 'https://ex.com/a/b', 'query stripped');
        check(c.sanitizeUrl('https://ex.com?x=1') === 'https://ex.com/', 'root path');
        check(c.sanitizeUrl('javascript:alert(1)') === '', 'non-URL rejected');

        const token = 'A'.repeat(43);
        const pairing = c.parsePairingCode(' wisper-agent:47821:' + token + ' ');
        check(pairing && pairing.port === 47821 && pairing.token === token, 'pairing code parsed');
        check(c.parsePairingCode('wisper-agent:80:' + token) === null, 'privileged port refused');
        check(c.parsePairingCode('wisper-agent:47821:short') === null, 'short token refused');

        let stream = c.parseEventStream('data: {"type":"delta","text":"a"}\n\ndata: {"type":"de');
        check(stream.events.length === 1 && stream.events[0].text === 'a', 'first event');
        stream = c.parseEventStream(stream.rest + 'lta","text":"b"}\r\n\r\ndata: oops\n\n');
        check(stream.events.length === 1 && stream.events[0].text === 'b' && stream.rest === '', 'split event joined, bad JSON skipped');

        const md = c.parseMarkdown('# Titre\nTexte **gras** *it* et `code` <script>x</script>\n\n- un\n- [lien](https://a.b/c)\n1. a\n```\n<b>raw</b>\n```\nVoir [cours.pdf p. 12]\n[x](javascript:alert(1))');
        check(md[0].type === 'h' && md[0].level === 1, 'heading');
        const line = md[1].lines[0];
        check(line[1].type === 'strong' && line[3].type === 'em' && line[5].type === 'code', 'inline styles');
        check(line[6].type === 'text' && line[6].text.indexOf('<script>') !== -1, 'markup stays plain text');
        check(md[2].type === 'ul' && md[2].items[1][0].type === 'link' && md[2].items[1][0].href === 'https://a.b/c', 'http link');
        check(md[3].type === 'ol', 'ordered list');
        check(md[4].type === 'pre' && md[4].text === '<b>raw</b>', 'code fence kept verbatim');
        check(md[5].lines[0][1].type === 'cite' && md[5].lines[0][1].text === 'cours.pdf p. 12', 'citation chip');
        check(md[5].lines[1].every(function (node) { return node.type === 'text'; }), 'javascript: links stay text');
        return 'ok';
      } catch (error) {
        return error.message;
      }
    })()
    """#
}
