import Foundation

enum AudioSilenceFilterTests {
    static func run() {
        testNormalizerDetectsActiveSpeech()
        testNormalizerDetectsSilence()
        testVisualPointerQueryMatching()
    }

    private static func testNormalizerDetectsActiveSpeech() {
        var normalizer = LiveAudioLevelNormalizer()
        TestSupport.expectEqual(normalizer.hasDetectedActiveSpeech, false)
        TestSupport.expectEqual(normalizer.activeSpeechFrameCount, 0)

        // Feed speech-level RMS buffers (> 0.02)
        _ = normalizer.normalizedLevel(forRMS: 0.05)
        _ = normalizer.normalizedLevel(forRMS: 0.06)
        _ = normalizer.normalizedLevel(forRMS: 0.07)

        TestSupport.expectEqual(normalizer.hasDetectedActiveSpeech, true)
        TestSupport.expect(normalizer.activeSpeechFrameCount >= 2, "Active speech frame count should be >= 2")
        TestSupport.expect(normalizer.peakRMS >= 0.07, "Peak RMS should record maximum buffer level")

        normalizer.reset()
        TestSupport.expectEqual(normalizer.hasDetectedActiveSpeech, false)
        TestSupport.expectEqual(normalizer.activeSpeechFrameCount, 0)
        TestSupport.expectEqual(normalizer.peakRMS, 0)
    }

    private static func testNormalizerDetectsSilence() {
        var normalizer = LiveAudioLevelNormalizer()

        // Feed background ambient silence (< 0.0005)
        _ = normalizer.normalizedLevel(forRMS: 0.0001)
        _ = normalizer.normalizedLevel(forRMS: 0.00015)
        _ = normalizer.normalizedLevel(forRMS: 0.00012)

        TestSupport.expectEqual(normalizer.hasDetectedActiveSpeech, false)
        TestSupport.expectEqual(normalizer.activeSpeechFrameCount, 0)
    }

    private static func testVisualPointerQueryMatching() {
        // Queries that MUST match
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Où se trouve le bouton pour exporter ?"), "Should match 'Où se trouve...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Où est la clé API ?"), "Should match 'Où est...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("c'est où les paramètres ?"), "Should match 'c'est où...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Montre-moi le tableau des logs"), "Should match 'Montre-moi...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Trouve le lien de téléchargement"), "Should match 'Trouve le...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Where is the submit button?"), "Should match 'Where is...'")
        TestSupport.expect(VisualPointerService.isVisualPointerQuery("Show me the search bar"), "Should match 'Show me...'")

        // Regular dictation that MUST NOT match
        TestSupport.expect(!VisualPointerService.isVisualPointerQuery("Bonjour comment vas-tu aujourd'hui ?"), "Should not match general greeting")
        TestSupport.expect(!VisualPointerService.isVisualPointerQuery("const user = await fetchUser(id);"), "Should not match code snippet")
        TestSupport.expect(!VisualPointerService.isVisualPointerQuery("Refactorer la base de données PostgreSQL"), "Should not match developer command")
        TestSupport.expect(!VisualPointerService.isVisualPointerQuery("Je pense qu'il faudrait revoir la PR"), "Should not match thought dictation")
    }
}
