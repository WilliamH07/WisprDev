import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import Carbon
import os.log
private let recordingLog = OSLog(subsystem: "com.williamh07.wisper", category: "Recording")

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

struct PrecomputedMacro {
    let original: VoiceMacro
    let normalizedCommand: String
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case stats
    case memory
    case general
    case shortcuts
    case ai
    case audio
    case prompts
    case macros
    case runLog
    case debug

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            tab != .debug || AppBuild.isDevBundle
        }
    }

    var title: String {
        switch self {
        case .stats: return "Accueil"
        case .memory: return "Mémoire"
        case .general: return "Général"
        case .shortcuts: return "Raccourcis"
        case .ai: return "Intelligence IA"
        case .audio: return "Audio & Voix"
        case .prompts: return "Prompts"
        case .macros: return "Macros Vocales"
        case .runLog: return "Historique"
        case .debug: return "Débogage"
        }
    }

    var icon: String {
        switch self {
        case .stats: return "chart.xyaxis.line"
        case .memory: return "brain.head.profile"
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .ai: return "sparkles"
        case .audio: return "mic"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

public enum LocalSpeedMode: String, CaseIterable, Identifiable {
    case direct = "direct"       // Mode Éclair (~150ms)
    case smart = "smart"         // Mode Smart Flow (~400ms)
    case accurate = "accurate"   // Mode Précision (~1.2s)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .direct: return "⚡️ Mode Éclair (Direct - ~150 ms)"
        case .smart: return "🧠 Mode Smart Flow (Nettoyage IA - ~400 ms)"
        case .accurate: return "🎯 Mode Précision (Whisper Turbo - ~1,2 s)"
        }
    }

    public var subtitle: String {
        switch self {
        case .direct: return "Collage instantané dès le relâchement de la touche. Zéro latence LLM."
        case .smart: return "Whisper Base + Nettoyage IA 3B pour retirer les 'euh' et hésitations."
        case .accurate: return "Modèle Whisper Turbo 1.6 Go pour les dictées techniques ou complexes."
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) == "Wisper Dev"
    }
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

private struct TranscriptCommandParsingResult {
    let transcript: String
    let shouldPressEnterAfterPaste: Bool
}

private enum CommandInvocation: String {
    case automatic
    case manual
}

private enum SessionIntent {
    case dictation
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .command:
            return true
        }
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
        case .command(let invocation, _):
            switch invocation {
            case .automatic:
                return .commandAutomatic
            case .manual:
                return .commandManual
            }
        }
    }

    var persistedSelectedText: String? {
        switch self {
        case .dictation:
            return nil
        case .command(_, let selectedText):
            return selectedText
        }
    }

    var isManualCommand: Bool {
        switch self {
        case .command(invocation: .manual, _):
            return true
        default:
            return false
        }
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}

enum RewriteProvider: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case local = "local"
    case groqCloud = "groq_cloud"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter (Recommandé - Modèles gratuits)"
        case .local: return "Local (Ollama - Llama 3.2 3B)"
        case .groqCloud: return "Groq Cloud"
        }
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let rewriteProviderStorageKey = "rewrite_provider"
    private let openRouterAPIKeyStorageKey = "openrouter_api_key"
    private let openRouterModelStorageKey = "openrouter_model"
    public static let defaultOpenRouterModel = "google/gemini-2.5-flash"
    public static let defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
    private let transcriptionModelStorageKey = "transcription_model"
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let rewriteSelectionShortcutStorageKey = "rewrite_selection_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let savedRewriteSelectionCustomShortcutStorageKey = "saved_rewrite_selection_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let instructionExecutionGuardEnabledStorageKey = "instruction_execution_guard_enabled"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let contextScreenshotMaxDimensionStorageKey = "context_screenshot_max_dimension"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let preserveExactWordingStorageKey = "preserve_exact_wording"
    private let localSpeedModeStorageKey = "local_speed_mode"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let visualPointerEnabledStorageKey = "visual_pointer_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let doubleTapAIModeEnabledStorageKey = "double_tap_ai_mode_enabled"
    private let aiAssistantModelStorageKey = "ai_assistant_model"
    private let outputLanguageStorageKey = "output_language"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    static let maxContextWaitAfterTranscription: TimeInterval = 0.6
    @Published var lastDictationTimings: DictationTimings?
    private var focusAtRecordingStart: (bundleIdentifier: String?, hadTextInput: Bool)?
    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20
    static let defaultContextScreenshotMaxDimension = Int(AppContextService.defaultScreenshotMaxDimension)
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-local"
    static let transcriptionLanguageOptions: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("fr", "French"),
        ("en", "English"),
        ("es", "Spanish"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("no", "Norwegian"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("cs", "Czech"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("ca", "Catalan")
    ]
    static let defaultPostProcessingModel = "llama3.2:3b"
    static let defaultPostProcessingFallbackModel = "qwen2.5:3b"
    static let defaultContextModel = "qwen2.5:3b"
    private static let deprecatedDefaultPostProcessingFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let deprecatedDefaultContextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let trailingPressEnterCommandPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            rebuildContextService()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            rebuildContextService()
        }
    }

    @Published var transcriptionAPIURL: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        }
    }

    @Published var transcriptionAPIKey: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
        }
    }

    @Published var transcriptionModel: String {
        didSet {
            UserDefaults.standard.set(transcriptionModel, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var postProcessingFallbackModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingFallbackModel, forKey: postProcessingFallbackModelStorageKey)
        }
    }

    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
            rebuildContextService()
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var rewriteSelectionShortcut: ShortcutBinding {
        didSet {
            persistShortcut(rewriteSelectionShortcut, key: rewriteSelectionShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedRewriteSelectionCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedRewriteSelectionCustomShortcut, key: savedRewriteSelectionCustomShortcutStorageKey)
        }
    }

    @Published var isRewritingText = false

    @Published var rewriteProvider: RewriteProvider {
        didSet {
            UserDefaults.standard.set(rewriteProvider.rawValue, forKey: rewriteProviderStorageKey)
        }
    }

    @Published var openRouterAPIKey: String {
        didSet {
            persistOpenRouterAPIKey(openRouterAPIKey)
        }
    }

    @Published var openRouterModel: String {
        didSet {
            UserDefaults.standard.set(openRouterModel, forKey: openRouterModelStorageKey)
        }
    }

    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: commandModeEnabledStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var isVisualPointerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isVisualPointerEnabled, forKey: visualPointerEnabledStorageKey)
        }
    }

    @Published var isDoubleTapAIModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDoubleTapAIModeEnabled, forKey: doubleTapAIModeEnabledStorageKey)
        }
    }

    @Published var aiAssistantModel: String {
        didSet {
            UserDefaults.standard.set(aiAssistantModel, forKey: aiAssistantModelStorageKey)
        }
    }

    private var lastRewriteTriggerTimestamp: Date?
    private var pendingRewriteWorkItem: DispatchWorkItem?
    private var clipboardMonitoringTimer: Timer?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastZshHistoryModificationDate: Date?

    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: commandModeStyleStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: commandModeManualModifierStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var transcriptionLanguage: String {
        didSet {
            let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
            if normalized != transcriptionLanguage {
                transcriptionLanguage = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: transcriptionLanguageStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            rebuildContextService()
        }
    }

    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                instructionExecutionGuardEnabled,
                forKey: instructionExecutionGuardEnabledStorageKey
            )
        }
    }

    @Published var desktopScreenshotFallbackEnabled: Bool {
        didSet {
            DesktopScreenshotFallbackPreference.save(desktopScreenshotFallbackEnabled, to: .standard)
            rebuildContextService()
        }
    }

    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalizedDimension = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalizedDimension != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalizedDimension
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: contextScreenshotMaxDimensionStorageKey)
            rebuildContextService()
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var outputLanguage: String {
        didSet {
            UserDefaults.standard.set(outputLanguage, forKey: outputLanguageStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    /// Stream audio to the transcription backend during recording via the
    /// OpenAI Realtime WebSocket. Reduces wall-clock latency between "stop"
    /// and text-ready because most of the transcription work happens while
    /// the user is still speaking.
    @Published var realtimeStreamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(realtimeStreamingEnabled, forKey: realtimeStreamingEnabledStorageKey)
        }
    }

    /// Model ID the realtime WebSocket should transcribe with. Empty means
    /// "use the server's default".
    @Published var realtimeStreamingModel: String {
        didSet {
            UserDefaults.standard.set(realtimeStreamingModel, forKey: realtimeStreamingModelStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var preserveExactWording: Bool {
        didSet {
            UserDefaults.standard.set(preserveExactWording, forKey: preserveExactWordingStorageKey)
        }
    }

    @Published var localSpeedMode: LocalSpeedMode {
        didSet {
            UserDefaults.standard.set(localSpeedMode.rawValue, forKey: localSpeedModeStorageKey)
            applyLocalSpeedMode()
        }
    }

    func applyLocalSpeedMode() {
        if localSpeedMode == .accurate {
            LocalInferenceService.shared.selectedModelFilename = "ggml-large-v3-turbo.bin"
        } else {
            LocalInferenceService.shared.selectedModelFilename = "ggml-base.bin"
        }
        Task {
            _ = await LocalInferenceService.shared.restartServer()
        }
    }

    @Published var localWhisperModel: String {
        didSet {
            LocalInferenceService.shared.selectedModelFilename = localWhisperModel
            Task {
                _ = await LocalInferenceService.shared.restartServer()
            }
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    private var precomputedMacros: [PrecomputedMacro] = []

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
            precomputeMacros()
        }
    }

    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppState.writeRecordingStateFlag(isRecording)
        }
    }
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .stats
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName: String = ""
    @Published var lastContextBundleIdentifier: String = ""
    @Published var lastContextWindowTitle: String = ""
    @Published var lastContextSelectedText: String = ""
    @Published var lastContextLLMPrompt: String = ""
    @Published var hasScreenRecordingPermission = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcriptionTask: Task<Void, Never>?
    private var transcribingAudioFileName: String?
    private var contextService: AppContextService
    private var contextCaptureTask: Task<AppContext?, Never>?
    private var capturedContext: AppContext?
    private var hasShownScreenshotPermissionAlert = false
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var currentSessionIntent: SessionIntent = .dictation
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingManualCommandInvocation = false
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var realtimeService: RealtimeTranscriptionService?
    private var automaticTerminationDisabled = false
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init() {
        Self.migrateLegacyUserDefaultsIfNeeded()
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionAPIURL = Self.loadOptionalStoredAPIValue(account: transcriptionAPIURLStorageKey)
        let transcriptionAPIKey = Self.loadStoredAPIKey(account: transcriptionAPIKeyStorageKey)
        let postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? Self.defaultPostProcessingModel
        let postProcessingFallbackModel = Self.loadStoredPostProcessingFallbackModel(
            key: postProcessingFallbackModelStorageKey
        )
        let contextModel = Self.loadStoredContextModel(key: contextModelStorageKey)
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey,
            rewriteSelectionKey: rewriteSelectionShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let savedRewriteSelectionCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedRewriteSelectionCustomShortcutStorageKey,
            fallback: shortcuts.rewriteSelection.isCustom ? shortcuts.rewriteSelection : nil
        )
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let transcriptionLanguage = Self.normalizeTranscriptionLanguage(
            UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? ""
        )
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let instructionExecutionGuardEnabled = UserDefaults.standard.object(
            forKey: instructionExecutionGuardEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: instructionExecutionGuardEnabledStorageKey)
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let outputLanguage = UserDefaults.standard.string(forKey: outputLanguageStorageKey) ?? ""
        let storedContextScreenshotMaxDimension = UserDefaults.standard.object(forKey: contextScreenshotMaxDimensionStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: contextScreenshotMaxDimensionStorageKey)
            : Self.defaultContextScreenshotMaxDimension
        let desktopScreenshotFallbackEnabled = DesktopScreenshotFallbackPreference.load(from: .standard)
        let contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(storedContextScreenshotMaxDimension)
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let isCommandModeEnabled = UserDefaults.standard.object(forKey: commandModeEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: commandModeEnabledStorageKey)
        let isVisualPointerEnabled = UserDefaults.standard.object(forKey: visualPointerEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: visualPointerEnabledStorageKey)
        let isDoubleTapAIModeEnabled = UserDefaults.standard.object(forKey: doubleTapAIModeEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: doubleTapAIModeEnabledStorageKey)
        var resolvedAIModel = UserDefaults.standard.string(forKey: aiAssistantModelStorageKey)
        if resolvedAIModel == nil || resolvedAIModel == "openai/gpt-6.1-sol" {
            resolvedAIModel = AIAssistantModel.gpt4oMini.rawValue
            UserDefaults.standard.set(AIAssistantModel.gpt4oMini.rawValue, forKey: aiAssistantModelStorageKey)
        }
        let aiAssistantModel = resolvedAIModel ?? AIAssistantModel.gpt4oMini.rawValue
        let commandModeStyle = CommandModeStyle(
            rawValue: UserDefaults.standard.string(forKey: commandModeStyleStorageKey) ?? ""
        ) ?? .automatic
        let commandModeManualModifier = CommandModeManualModifier(
            rawValue: UserDefaults.standard.string(forKey: commandModeManualModifierStorageKey) ?? ""
        ) ?? .option
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let preserveExactWording = UserDefaults.standard.bool(forKey: preserveExactWordingStorageKey)
        let rawSpeedMode = UserDefaults.standard.string(forKey: localSpeedModeStorageKey) ?? LocalSpeedMode.direct.rawValue
        let localSpeedMode = LocalSpeedMode(rawValue: rawSpeedMode) ?? .direct
        let keepDictationInClipboardHistory = UserDefaults.standard.object(forKey: keepDictationInClipboardHistoryStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: realtimeStreamingEnabledStorageKey)
        let realtimeStreamingModel = UserDefaults.standard.string(forKey: realtimeStreamingModelStorageKey) ?? ""
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0
        
        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let storedRewriteProvider = UserDefaults.standard.string(forKey: rewriteProviderStorageKey) ?? ""
        let rewriteProvider = RewriteProvider(rawValue: storedRewriteProvider) ?? .openRouter
        let openRouterAPIKey = Self.loadStoredAPIKey(account: openRouterAPIKeyStorageKey)
        let rawOpenRouterModel = UserDefaults.standard.string(forKey: openRouterModelStorageKey) ?? ""
        let openRouterModel: String
        if rawOpenRouterModel.isEmpty
            || rawOpenRouterModel == "meta-llama/llama-3.3-70b-instruct:free"
            || rawOpenRouterModel == "nvidia/nemotron-3-ultra-550b-a55b:free"
            || rawOpenRouterModel == "nvidia/nemotron-3-super-120b-a12b:free" {
            openRouterModel = Self.defaultOpenRouterModel
            UserDefaults.standard.set(Self.defaultOpenRouterModel, forKey: openRouterModelStorageKey)
        } else {
            openRouterModel = rawOpenRouterModel
        }

        let rawLocalWhisperModel = UserDefaults.standard.string(forKey: LocalInferenceService.selectedModelKey) ?? ""
        if rawLocalWhisperModel.isEmpty || rawLocalWhisperModel == "ggml-base.bin" {
            UserDefaults.standard.set("ggml-large-v3-turbo.bin", forKey: LocalInferenceService.selectedModelKey)
            LocalInferenceService.shared.selectedModelFilename = "ggml-large-v3-turbo.bin"
        }

        let clipboardConfigMigratedKey = "clipboard_config_migrated_v2"
        if !UserDefaults.standard.bool(forKey: clipboardConfigMigratedKey) {
            UserDefaults.standard.set(true, forKey: preserveClipboardStorageKey)
            UserDefaults.standard.set(false, forKey: keepDictationInClipboardHistoryStorageKey)
            UserDefaults.standard.set(true, forKey: clipboardConfigMigratedKey)
        }

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionModel = transcriptionModel
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.rewriteProvider = rewriteProvider
        self.openRouterAPIKey = openRouterAPIKey
        self.openRouterModel = openRouterModel
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.copyAgainShortcut = shortcuts.copyAgain
        self.rewriteSelectionShortcut = shortcuts.rewriteSelection
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.savedRewriteSelectionCustomShortcut = savedRewriteSelectionCustomShortcut.binding
        self.isCommandModeEnabled = isCommandModeEnabled
        self.isVisualPointerEnabled = isVisualPointerEnabled
        self.isDoubleTapAIModeEnabled = isDoubleTapAIModeEnabled
        self.aiAssistantModel = aiAssistantModel
        self.commandModeStyle = commandModeStyle
        self.commandModeManualModifier = commandModeManualModifier
        self.customVocabulary = customVocabulary
        self.transcriptionLanguage = transcriptionLanguage
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.desktopScreenshotFallbackEnabled = desktopScreenshotFallbackEnabled
        self.contextScreenshotMaxDimension = contextScreenshotMaxDimension
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.outputLanguage = outputLanguage
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.preserveExactWording = preserveExactWording
        self.localSpeedMode = localSpeedMode
        self.localWhisperModel = LocalInferenceService.shared.selectedModelFilename
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.realtimeStreamingEnabled = realtimeStreamingEnabled
        self.realtimeStreamingModel = realtimeStreamingModel
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.precomputeMacros()

        refreshAvailableMicrophones()
        installAudioDeviceObservers()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if shortcuts.didUpdateRewriteSelectionStoredValue {
            persistShortcut(shortcuts.rewriteSelection, key: rewriteSelectionShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }
        if savedRewriteSelectionCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedRewriteSelectionCustomShortcut.binding, key: savedRewriteSelectionCustomShortcutStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onUpdateOverlayPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleUpdateOverlayPressed()
            }
        }

        // Clear any stale recording flag left over from an unclean exit.
        AppState.writeRecordingStateFlag(false)

        if transcriptionModel == "whisper-local" {
            Task {
                _ = await LocalInferenceService.shared.ensureServerRunning()
            }
        } else {
            // Open the TLS connection to the cloud provider now so the first
            // dictation after launch does not pay the handshake (no user content sent).
            LLMAPITransport.prewarm(baseURLs: [resolvedTranscriptionBaseURL, apiBaseURL])
        }

        startClipboardMonitoring()
    }

    private static func migrateLegacyUserDefaultsIfNeeded() {
        let migrationKey = "hasMigratedLegacyFreeFlowDefaults"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let legacySuites = ["com.zachlatta.freeflow.dev", "com.zachlatta.freeflow"]
        for suite in legacySuites {
            if let legacyDefaults = UserDefaults(suiteName: suite) {
                let dict = legacyDefaults.dictionaryRepresentation()
                for (key, value) in dict {
                    if UserDefaults.standard.object(forKey: key) == nil {
                        UserDefaults.standard.set(value, forKey: key)
                    }
                }
            }
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    deinit {
        stopClipboardMonitoring()
        removeAudioDeviceObservers()
        AppState.writeRecordingStateFlag(false)
    }

    private func startClipboardMonitoring() {
        stopClipboardMonitoring()
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        checkTerminalHistoryForSemanticMemory()
        clipboardMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkClipboardForSemanticMemory()
            self?.checkTerminalHistoryForSemanticMemory()
        }
    }

    private func stopClipboardMonitoring() {
        clipboardMonitoringTimer?.invalidate()
        clipboardMonitoringTimer = nil
    }

    private func checkTerminalHistoryForSemanticMemory() {
        guard SemanticMemoryService.shared.isEnabled,
              SemanticMemoryService.shared.captureTerminalHistoryEnabled else { return }

        let zshHistoryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: zshHistoryPath),
              let modDate = attrs[.modificationDate] as? Date else { return }

        if lastZshHistoryModificationDate == nil {
            lastZshHistoryModificationDate = modDate
            SemanticMemoryService.shared.syncTerminalHistory()
            return
        }

        if modDate > lastZshHistoryModificationDate! {
            lastZshHistoryModificationDate = modDate
            SemanticMemoryService.shared.syncTerminalHistory()
        }
    }

    private func checkClipboardForSemanticMemory() {
        guard SemanticMemoryService.shared.isEnabled,
              SemanticMemoryService.shared.captureClipboardEnabled else { return }

        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentChangeCount

        // Check if transient or concealed (e.g. from password managers or internal paste)
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

        if let types = pasteboard.types {
            if types.contains(transientType) || types.contains(concealedType) || types.contains(autoGeneratedType) || types.contains(legacyTransientType) {
                return
            }
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        SemanticMemoryService.shared.record(
            text: text,
            category: .clipboard,
            sourceAppName: frontApp
        )
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    private func persistOpenRouterAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: openRouterAPIKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: openRouterAPIKeyStorageKey)
        }
    }

    static let defaultAPIBaseURL = "http://127.0.0.1:11434/v1"

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let copyAgain: ShortcutBinding
        let rewriteSelection: ShortcutBinding
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
        let didUpdateRewriteSelectionStoredValue: Bool
    }

    private struct StoredOptionalShortcut {
        let binding: ShortcutBinding?
        let didUpdateStoredValue: Bool
    }

    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    private static func loadStoredContextModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultContextModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultContextModel {
            UserDefaults.standard.set(defaultContextModel, forKey: key)
            return defaultContextModel
        }

        return trimmed.isEmpty ? defaultContextModel : trimmed
    }

    private static func loadStoredPostProcessingFallbackModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultPostProcessingFallbackModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultPostProcessingFallbackModel {
            UserDefaults.standard.set(defaultPostProcessingFallbackModel, forKey: key)
            return defaultPostProcessingFallbackModel
        }

        return trimmed.isEmpty ? defaultPostProcessingFallbackModel : trimmed
    }

    private static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String,
        rewriteSelectionKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        let storedRewriteSelection = loadShortcut(forKey: rewriteSelectionKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            rewriteSelection: storedRewriteSelection.binding ?? ShortcutBinding.defaultRewriteSelection,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize,
            didUpdateRewriteSelectionStoredValue: storedRewriteSelection.binding == nil || storedRewriteSelection.didNormalize
        )
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }

    private static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }

        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value)
            ? value
            : defaultContextScreenshotMaxDimension
    }

    static func makeAppContextService(
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextModel: String,
        contextScreenshotMaxDimension: Int,
        desktopScreenshotFallbackEnabled: Bool
    ) -> AppContextService {
        AppContextService(
            apiKey: apiKey,
            baseURL: baseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            screenshotMaxDimension: CGFloat(normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)),
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    private static func loadOptionalStoredAPIValue(account: String) -> String {
        let stored = AppSettingsStorage.load(account: account) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeTranscriptionLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard transcriptionLanguageOptions.contains(where: { $0.code == normalized }) else {
            return ""
        }
        return normalized
    }

    private var resolvedTranscriptionBaseURL: String {
        TranscriptionRouting.baseURL(
            model: transcriptionModel,
            explicitURL: transcriptionAPIURL,
            defaultURL: apiBaseURL
        )
    }

    private var resolvedTranscriptionAPIKey: String {
        TranscriptionRouting.apiKey(
            model: transcriptionModel,
            explicitKey: transcriptionAPIKey,
            openRouterKey: openRouterAPIKey,
            defaultKey: apiKey
        )
    }

    func makeTranscriptionService() throws -> TranscriptionService {
        let vocabPrompt = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        return try TranscriptionService(
            apiKey: resolvedTranscriptionAPIKey,
            baseURL: resolvedTranscriptionBaseURL,
            transcriptionModel: transcriptionModel,
            language: resolvedTranscriptionLanguage,
            prompt: vocabPrompt.isEmpty ? nil : vocabPrompt
        )
    }

    func makePostProcessingService() -> PostProcessingService {
        if rewriteProvider == .openRouter && !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let model = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let primary = model.isEmpty ? Self.defaultOpenRouterModel : model
            let fallback = (primary == "nvidia/nemotron-3-super-120b-a12b:free")
                ? "nex-agi/nex-n2.5-pro:free"
                : "nvidia/nemotron-3-super-120b-a12b:free"
            return PostProcessingService(
                apiKey: openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: Self.defaultOpenRouterBaseURL,
                preferredModel: primary,
                preferredFallbackModel: fallback,
                instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
            )
        } else {
            return PostProcessingService(
                apiKey: apiKey,
                baseURL: apiBaseURL,
                preferredModel: postProcessingModel,
                preferredFallbackModel: postProcessingFallbackModel,
                instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
            )
        }
    }

    private var resolvedTranscriptionLanguage: String? {
        let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
        return normalized.isEmpty ? nil : normalized
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.displayName
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    /// URL of the flag file written while Wisper is actively recording.
    ///
    /// External tools (voice assistants, TTS barge-in pipelines, conversation
    /// apps) can poll this file to know when the user is dictating. The file
    /// exists while `isRecording` is true and is removed when it flips false.
    /// Contents are the UNIX timestamp (seconds, float) of when recording
    /// started — useful for stale-flag detection after an unclean exit.
    ///
    /// Path: `~/Library/Application Support/Wisper/is-recording`
    /// (or `Wisper Dev/is-recording` when running the dev bundle).
    static func recordingStateFlagURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Wisper"
        return appSupport.appendingPathComponent("\(appName)/is-recording")
    }

    /// Serial queue that owns every flag-file I/O so the recording
    /// start/stop hot path never blocks on disk.
    private static let recordingStateFlagQueue = DispatchQueue(
        label: "com.williamh07.wisper.recording-state-flag"
    )

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    static func writeRecordingStateFlag(_ recording: Bool) {
        let timestamp = recording ? String(Date().timeIntervalSince1970) : nil
        recordingStateFlagQueue.async {
            let url = recordingStateFlagURL()
            if let timestamp {
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? timestamp.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to persist audio file %{public}@ from %{public}@ to %{public}@ : %{public}@",
                fileName,
                tempURL.path,
                destURL.path,
                error.localizedDescription
            )
            return nil
        }
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName else { return }
        guard !retryingItemIDs.contains(item.id) else { return }

        retryingItemIDs.insert(item.id)

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            retryingItemIDs.remove(item.id)
            errorMessage = "Audio file not found for retry."
            return
        }

        let restoredContext = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
            screenshotError: nil
        )

        let postProcessingService = makePostProcessingService()
        let capturedCustomVocabulary = customVocabulary
        let capturedCustomSystemPrompt = customSystemPrompt

        Task {
            do {
                let transcriptionService = try makeTranscriptionService()
                let rawTranscript = try await transcriptionService.transcribe(fileURL: audioURL)
                let parsedTranscript = Self.parseTranscriptCommands(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                )

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                let restoredIntent = SessionIntent.fromPersisted(
                    intent: item.intent,
                    selectedText: item.selectedText
                )
                let result = await self.processTranscript(
                    parsedTranscript.transcript,
                    intent: restoredIntent,
                    context: restoredContext,
                    postProcessingService: postProcessingService,
                    customVocabulary: capturedCustomVocabulary,
                    customSystemPrompt: capturedCustomSystemPrompt,
                    outputLanguage: self.outputLanguage,
                    preserveExactWording: self.preserveExactWording
                )
                finalTranscript = result.finalTranscript
                processingStatus = Self.statusMessage(
                    for: result.outcome,
                    parsedTranscript: parsedTranscript,
                    isRetry: true
                )
                postProcessingPrompt = result.prompt

                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: parsedTranscript.transcript,
                        postProcessedTranscript: finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: processingStatus,
                        debugStatus: "Retried",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                        let trimmedRetryTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedRetryTranscript.isEmpty {
                            lastTranscript = trimmedRetryTranscript
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(trimmedRetryTranscript, forType: .string)
                        }
                    } catch {
                        errorMessage = "Failed to save retry result: \(error.localizedDescription)"
                    }
                    retryingItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: item.rawTranscript,
                        postProcessedTranscript: item.postProcessedTranscript,
                        postProcessingPrompt: item.postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: "Error: \(error.localizedDescription)",
                        debugStatus: "Retry failed",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {}
                    retryingItemIDs.remove(item.id)
                }
            }
        }
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecordingPermission = hasScreenCapturePermission()
        if hasAccessibility && hasScreenRecordingPermission {
            return
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasAccessibility = AXIsProcessTrusted()
                self.hasScreenRecordingPermission = self.hasScreenCapturePermission()
                if self.hasAccessibility && self.hasScreenRecordingPermission {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openPrivacySettingsPane("Privacy_Accessibility")
        }
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane("Privacy_Microphone")
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshAvailableMicrophones()
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.refreshAvailableMicrophones()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                let granted = CGPreflightScreenCaptureAccess()
                self?.hasScreenRecordingPermission = granted
                if !granted {
                    self?.openScreenCaptureSettings()
                }
            }
        }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        openPrivacySettingsPane("Privacy_ScreenCapture")
    }

    private func openPrivacySettingsPane(_ pane: String) {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        guard !isRecording, !audioRecorder.isRecording else {
            needsMicrophoneRefreshAfterRecording = true
            return
        }

        needsMicrophoneRefreshAfterRecording = false
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            self?.refreshAvailableMicrophones()
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey || rewriteSelectionShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return "Global shortcuts unavailable"
        }

        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or tap \(toggleShortcut.displayName) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "Tap \(toggleShortcut.displayName) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        case .copyAgain:
            return savedCopyAgainCustomShortcut
        case .rewriteSelection:
            return savedRewriteSelectionCustomShortcut
        }
    }

    var commandModeManualModifierValidationMessage: String? {
        guard isCommandModeEnabled, commandModeStyle == .manual else { return nil }
        return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
    }

    @discardableResult
    func setCommandModeEnabled(_ enabled: Bool) -> String? {
        isCommandModeEnabled = enabled
        if enabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeStyle(_ style: CommandModeStyle) -> String? {
        commandModeStyle = style
        if isCommandModeEnabled, style == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String? {
        // Match sibling setters: always commit, then validate.
        commandModeManualModifier = modifier
        if isCommandModeEnabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: modifier)
        }
        return nil
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? toggleShortcut : holdShortcut
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: copyAgainShortcut) {
            return "This shortcut is already used by Paste Again."
        }
        if role != .rewriteSelection, binding.conflicts(with: rewriteSelectionShortcut) {
            return "This shortcut is already used by Rewrite Selection."
        }
        if role == .copyAgain {
            if binding.conflicts(with: holdShortcut) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
            if binding.conflicts(with: rewriteSelectionShortcut) {
                return "Paste Again cannot share a shortcut with Rewrite Selection."
            }
            if isCommandModeEnabled, commandModeStyle == .manual,
               bindingCollides(binding, with: commandModeManualModifier) {
                return "Paste Again cannot share the Edit Mode modifier."
            }
        }
        if role == .rewriteSelection {
            if binding.conflicts(with: holdShortcut) {
                return "Rewrite Selection cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Rewrite Selection cannot share a shortcut with Tap to Toggle."
            }
            if binding.conflicts(with: copyAgainShortcut) {
                return "Rewrite Selection cannot share a shortcut with Paste Again."
            }
            if isCommandModeEnabled, commandModeStyle == .manual,
               bindingCollides(binding, with: commandModeManualModifier) {
                return "Rewrite Selection cannot share the Edit Mode modifier."
            }
        }

        switch role {
        case .hold:
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        case .toggle:
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        case .copyAgain:
            if binding.isCustom {
                savedCopyAgainCustomShortcut = binding
            }
            copyAgainShortcut = binding
        case .rewriteSelection:
            if binding.isCustom {
                savedRewriteSelectionCustomShortcut = binding
            }
            rewriteSelectionShortcut = binding
        }

        return nil
    }

    private func commandModeManualModifierCollisionMessage(
        for modifier: CommandModeManualModifier,
        holdBinding: ShortcutBinding? = nil,
        toggleBinding: ShortcutBinding? = nil,
        copyAgainBinding: ShortcutBinding? = nil
    ) -> String? {
        let holdBinding = holdBinding ?? holdShortcut
        let toggleBinding = toggleBinding ?? toggleShortcut
        let copyAgainBinding = copyAgainBinding ?? copyAgainShortcut
        let manualModifier = modifier.shortcutModifier

        if !holdBinding.isDisabled && holdBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the hold shortcut."
        }
        if !toggleBinding.isDisabled && toggleBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the tap shortcut."
        }
        if !copyAgainBinding.isDisabled && copyAgainBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Paste Again shortcut."
        }
        // Modifier-only bindings carry identity in keyCode, not modifiers.
        if !holdBinding.isDisabled,
           holdBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: holdBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the hold shortcut."
        }
        if !toggleBinding.isDisabled,
           toggleBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: toggleBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the tap shortcut."
        }
        if !copyAgainBinding.isDisabled,
           copyAgainBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: copyAgainBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the Paste Again shortcut."
        }

        return nil
    }

    private func bindingCollides(_ binding: ShortcutBinding, with modifier: CommandModeManualModifier) -> Bool {
        guard !binding.isDisabled else { return false }
        let manualModifier = modifier.shortcutModifier
        if binding.modifiers.contains(manualModifier) { return true }
        if binding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: binding.keyCode),
           bindingModifier == manualModifier {
            return true
        }
        return false
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            self?.handleEscapeKeyPress() ?? false
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
        hotkeyManager.onEscapeKeyPressed = nil
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        let permittedAdditionalExactMatchModifiers: ShortcutModifiers
        if isCommandModeEnabled, commandModeStyle == .manual {
            permittedAdditionalExactMatchModifiers = commandModeManualModifier.shortcutModifier
        } else {
            permittedAdditionalExactMatchModifiers = []
        }

        let alternativeRewriteShortcut: ShortcutBinding
        if let custom = savedRewriteSelectionCustomShortcut, custom != rewriteSelectionShortcut {
            alternativeRewriteShortcut = custom
        } else {
            alternativeRewriteShortcut = .disabled
        }

        return ShortcutConfiguration(
            hold: holdShortcut,
            toggle: toggleShortcut,
            copyAgain: copyAgainShortcut,
            rewriteSelection: rewriteSelectionShortcut,
            rewriteSelectionAlternative: alternativeRewriteShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        )
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission else {
            hotkeyManager.stop()
            return
        }

        if hotkeyManager.isRunning {
            hotkeyManager.updateConfiguration(activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
            return
        }

        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
            os_log(.error, log: recordingLog, "Hotkey monitoring failed to start: %{public}@", error.localizedDescription)
        }
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        if event == .copyAgainTriggered {
            copyLastTranscriptToPasteboard()
            return
        }
        if event == .rewriteSelectionTriggered {
            os_log(.info, log: recordingLog, "Rewrite selection shortcut event triggered")

            if isDoubleTapAIModeEnabled {
                let now = Date()
                if let lastTime = lastRewriteTriggerTimestamp,
                   now.timeIntervalSince(lastTime) < 0.38 {
                    os_log(.info, log: recordingLog, "Double-tap detected on rewrite shortcut -> toggling AI Mode")
                    lastRewriteTriggerTimestamp = nil
                    pendingRewriteWorkItem?.cancel()
                    pendingRewriteWorkItem = nil

                    playAlertSound(named: "Tink")

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        AIAssistantWindowManager.shared.toggle(appState: self)
                    }
                    return
                }

                lastRewriteTriggerTimestamp = now

                // Debounce single-tap rewrite slightly so double-tap can cancel it cleanly
                pendingRewriteWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingRewriteWorkItem = nil
                    self.triggerRewriteSelectedText()
                }
                pendingRewriteWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
                return
            } else {
                triggerRewriteSelectedText()
                return
            }
        }

        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            guard isRecording else {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                return
            }
            stopAndTranscribe()
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    private func handleEscapeKeyPress() -> Bool {
        if isTranscribing {
            cancelTranscription()
            return true
        }

        if pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
            cancelToggleShortcutSession()
            return true
        }

        return false
    }

    /// Copies the last transcript to the pasteboard and pastes it into the
    /// focused app — Wispr Flow style. Reuses the dictation paste pipeline so
    /// preserveClipboard is honored and the synthetic Cmd+V waits for the
    /// trigger shortcut to be fully released.
    func copyLastTranscriptToPasteboard() {
        guard !lastTranscript.isEmpty else { return }
        let pendingClipboardRestore = writeTranscriptToPasteboard(lastTranscript)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingClipboardRestore)
        }
    }

    /// Rewrites the selected text in the active application using AI cleanup.
    func triggerRewriteSelectedText() {
        os_log(.info, log: recordingLog, "triggerRewriteSelectedText called")
        guard !isRewritingText, !isRecording, !isTranscribing else {
            os_log(.info, log: recordingLog, "triggerRewriteSelectedText ignored: isRewritingText=%{public}d isRecording=%{public}d isTranscribing=%{public}d", isRewritingText, isRecording, isTranscribing)
            return
        }

        guard AXIsProcessTrusted() else {
            showAccessibilityAlert()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeRewriteSelectedText()
        }
    }

    @MainActor
    private func executeRewriteSelectedText() async {
        isRewritingText = true

        // 1. Attempt to grab selected text via Accessibility API
        let selectionSnapshot = contextService.collectSelectionSnapshot()
        var selectedText = selectionSnapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        var preservedClipboardForFallback: PreservedPasteboardSnapshot? = nil

        os_log(.info, log: recordingLog, "executeRewriteSelectedText: AX selectedText found=%{public}d", selectedText != nil && selectedText?.isEmpty == false)

        // 2. If Accessibility returned empty (common in web browsers/Electron), fall back to Cmd+C
        if selectedText == nil || selectedText?.isEmpty == true {
            // Wait for user to release the trigger shortcut so held keys/modifiers don't interfere with synthetic Cmd+C
            await waitForShortcutInputsReleased()

            let pasteboard = NSPasteboard.general
            preservedClipboardForFallback = PreservedPasteboardSnapshot(pasteboard: pasteboard)
            let initialChangeCount = pasteboard.changeCount

            await simulateCopyCommand()

            // Give the active application a window to process Cmd+C
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if pasteboard.changeCount != initialChangeCount {
                    break
                }
            }

            if pasteboard.changeCount != initialChangeCount,
               let copied = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !copied.isEmpty {
                selectedText = copied
            }
            os_log(.info, log: recordingLog, "executeRewriteSelectedText: fallback copy selectedText found=%{public}d", selectedText != nil && selectedText?.isEmpty == false)
        }

        guard let textToRewrite = selectedText, !textToRewrite.isEmpty else {
            if let preservedClipboardForFallback {
                preservedClipboardForFallback.restore(to: NSPasteboard.general)
            }
            overlayManager.showError("Aucun texte sélectionné")
            playAlertSound(named: "Basso")
            statusText = "No text selected"
            scheduleReadyStatusReset(after: 2, matching: ["No text selected"])
            isRewritingText = false
            return
        }

        statusText = "Rewriting..."
        overlayManager.showRewriting()

        if rewriteProvider == .openRouter {
            let key = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                if let preservedClipboardForFallback {
                    preservedClipboardForFallback.restore(to: NSPasteboard.general)
                }
                overlayManager.showError("Clé OpenRouter requise dans Réglages")
                playAlertSound(named: "Basso")
                statusText = "OpenRouter key required"
                scheduleReadyStatusReset(after: 3, matching: ["OpenRouter key required"])
                isRewritingText = false
                return
            }
        }

        do {
            let postProcessingService = makePostProcessingService()
            let resolvedContext = await contextService.collectContext()
            let result = try await postProcessingService.rewriteSelectedText(
                text: textToRewrite,
                context: resolvedContext,
                customVocabulary: customVocabulary,
                outputLanguage: outputLanguage
            )

            let rewritten = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rewritten.isEmpty else {
                throw PostProcessingError.emptyOutput
            }

            lastTranscript = rewritten
            recordPipelineHistoryEntry(
                rawTranscript: textToRewrite,
                postProcessedTranscript: rewritten,
                postProcessingPrompt: result.prompt,
                systemPrompt: Self.resolvedSystemPrompt(customSystemPrompt),
                context: resolvedContext,
                processingStatus: "rewritten",
                intent: .dictation
            )

            SemanticMemoryService.shared.record(
                text: rewritten,
                category: .rewrite,
                sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            )

            let pendingClipboardRestore = writeTranscriptToPasteboard(rewritten)
            pasteAtCursorWhenShortcutReleased { [weak self] in
                guard let self else { return }
                if let preservedClipboardForFallback {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.clipboardRestoreDelay) {
                        preservedClipboardForFallback.restore(to: NSPasteboard.general)
                    }
                } else {
                    self.restoreClipboardIfNeeded(pendingClipboardRestore)
                }
            }

            overlayManager.dismiss()
            statusText = "Rewritten"
            scheduleReadyStatusReset(after: 3, matching: ["Rewritten"])
        } catch {
            os_log(.error, log: recordingLog, "Rewrite failed: %{public}@", error.localizedDescription)
            if let preservedClipboardForFallback {
                preservedClipboardForFallback.restore(to: NSPasteboard.general)
            }
            overlayManager.showError("Erreur réécriture : \(error.localizedDescription)")
            playAlertSound(named: "Basso")
            errorMessage = "Rewrite failed: \(error.localizedDescription)"
            statusText = "Rewrite failed"
            scheduleReadyStatusReset(after: 3, matching: ["Rewrite failed"])
        }

        isRewritingText = false
    }

    @MainActor
    private func waitForShortcutInputsReleased(maxAttempts: Int = 24) async {
        var attempts = 0
        while hotkeyManager.hasPressedShortcutInputs && attempts < maxAttempts {
            attempts += 1
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        // Small delay to allow the operating system event queue to fully clear modifier states
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    @MainActor
    private func simulateCopyCommand() async {
        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        let cKeyCode = keyCodeForCharacter("c") ?? 8

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(nanoseconds: 15_000_000)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }

        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func cancelTranscription() {
        guard isTranscribing else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func cancelCurrentRecordingSession() {
        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        currentSessionIntent = .dictation
        isRecording = false
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
    }

    func beginVoiceCaptureForAIAssistant() {
        guard !audioRecorder.isRecording else { return }
        do {
            try audioRecorder.startRecording(deviceUID: selectedMicrophoneID)
        } catch {
            os_log(.error, log: recordingLog, "Failed to start AI voice capture: %{public}@", error.localizedDescription)
        }
    }

    func recordAndTranscribeSingleUtterance() async -> String? {
        guard audioRecorder.isRecording else { return nil }
        let audioURL: URL? = await withCheckedContinuation { continuation in
            audioRecorder.stopRecording { url in
                continuation.resume(returning: url)
            }
        }
        guard let audioURL else { return nil }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            let service = try makeTranscriptionService()
            let raw = try await service.transcribe(fileURL: audioURL)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            os_log(.error, log: recordingLog, "AI assistant transcription error: %{public}@", error.localizedDescription)
            return nil
        }
    }

    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingSelectionSnapshot = contextService.collectSelectionSnapshot()
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers.contains(
            commandModeManualModifier.shortcutModifier
        )
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func resolveSessionIntent(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot,
        manualCommandRequested: Bool
    ) -> SessionIntent? {
        guard isCommandModeEnabled else {
            return .dictation
        }

        let rawSelectedText = selectionSnapshot.selectedText ?? ""
        let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch commandModeStyle {
        case .automatic:
            if !trimmedSelectedText.isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelectedText)
            }
            return .dictation
        case .manual:
            // If the binding IS the manual modifier, the "modifier pressed"
            // signal is the binding's own press. Fall back to plain dictation.
            let activeBinding: ShortcutBinding = (triggerMode == .toggle) ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else {
                return .dictation
            }
            guard !trimmedSelectedText.isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelectedText)
        }
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = "Select text to transform first."
        statusText = "Select text to transform first"
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Select text to transform first"])
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = message
        statusText = "Fix Edit Mode modifier"
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Fix Edit Mode modifier"])
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording && !isTranscribing else { return }
        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()
        guard prepareRecordingStart(
            triggerMode: triggerMode,
            selectionSnapshot: scheduledSelectionSnapshot,
            manualCommandRequested: scheduledSelectionSnapshot == nil
                ? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
                : scheduledManualCommandInvocation,
            startedAt: t0
        ) else { return }
        guard ensureMicrophoneAccess() else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode)
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func prepareRecordingStart(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot? = nil,
        manualCommandRequested: Bool? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Bool {
        activeRecordingTriggerMode = triggerMode
        let isAccessibilityTrusted = AXIsProcessTrusted()
        hasAccessibility = isAccessibilityTrusted
        guard isAccessibilityTrusted else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return false
        }
        if let startedAt {
            os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        }

        let selectionSnapshot = selectionSnapshot ?? contextService.collectSelectionSnapshot()
        let manualCommandRequested = manualCommandRequested
            ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
        guard let resolvedIntent = resolveSessionIntent(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: manualCommandRequested
        ) else { return false }

        if resolvedIntent.isCommandMode {
            guard ensureScreenCaptureAccess() else { return false }
            if let startedAt {
                os_log(.info, log: recordingLog, "screen capture check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }

        currentSessionIntent = resolvedIntent
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    private func ensureScreenCaptureAccess() -> Bool {
        let granted = hasScreenCapturePermission()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            errorMessage = message
            statusText = "Screenshot Required"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
            return false
        }

        return true
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(
                triggerMode: triggerMode,
                selectionSnapshot: pendingSelectionSnapshot ?? contextService.collectSelectionSnapshot(),
                manualCommandRequested: currentSessionIntent.isManualCommand
            )
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    let pendingSelectionSnapshot = strongSelf.pendingMicrophonePermissionSelectionSnapshot
                    let pendingManualCommandRequested = strongSelf.pendingMicrophonePermissionManualCommandRequested
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.pendingMicrophonePermissionSelectionSnapshot = nil
                    strongSelf.pendingMicrophonePermissionManualCommandRequested = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            guard strongSelf.prepareRecordingStart(
                                triggerMode: .toggle,
                                selectionSnapshot: pendingSelectionSnapshot,
                                manualCommandRequested: pendingManualCommandRequested
                            ) else { return }
                            strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                            strongSelf.applyAudioInterruptionIfNeeded()
                            strongSelf.beginRecording(triggerMode: .toggle)
                        } else {
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = "Microphone access granted. Press and hold again to record."
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: ["Microphone access granted. Press and hold again to record."]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        strongSelf.statusText = "No Microphone"
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.currentSessionIntent = .dictation
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        overlayManager.dismiss()
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    private func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
            }
        }
    }

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("Wisper dictation in progress")
        automaticTerminationDisabled = true
    }

    private func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("Wisper dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil

        isRecording = true
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode,
                isCommandMode: self.currentSessionIntent.isCommandMode
            )
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                self.clearPendingOverlayDismissToken()
                if overlayShown {
                    self.overlayManager.transitionToRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                } else {
                    self.overlayManager.showRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                }
                overlayShown = true
                self.playAlertSound(named: "Tink")
                HapticFeedbackService.shared.trigger(.startRecording)
            }
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        startRealtimeStreamingIfEnabled()

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async { [self] in
                    guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                    self.startContextCapture()
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        tearDownRealtimeService()
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func formattedTranscriptionError(_ error: Error) -> String {
        TranscriptionErrorPresentationCore.message(
            for: error,
            isOnline: NetworkMonitor.shared.isOnline
        )
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func precomputeMacros() {
        precomputedMacros = voiceMacros.map { macro in
            PrecomputedMacro(
                original: macro,
                normalizedCommand: normalize(macro.command)
            )
        }
    }

    private func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let strippedPunctuation = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return strippedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTranscriptCommands(
        from transcript: String,
        pressEnterCommandEnabled: Bool
    ) -> TranscriptCommandParsingResult {
        guard pressEnterCommandEnabled else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard
            let match = trailingPressEnterCommandPattern.firstMatch(in: transcript, range: fullRange),
            let commandRange = Range(match.range, in: transcript)
        else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        var strippedTranscript = transcript
        strippedTranscript.removeSubrange(commandRange)

        return TranscriptCommandParsingResult(
            transcript: strippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldPressEnterAfterPaste: true
        )
    }

    private static func statusMessage(
        for outcome: TranscriptProcessingOutcome,
        parsedTranscript: TranscriptCommandParsingResult,
        isRetry: Bool = false
    ) -> String {
        let status = outcome.statusMessage(isRetry: isRetry)
        guard parsedTranscript.shouldPressEnterAfterPaste else { return status }
        return "\(status); detected press enter command"
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    private func findMatchingMacro(for transcript: String) -> VoiceMacro? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        return precomputedMacros.first {
            normalizedTranscript == $0.normalizedCommand
        }?.original
    }

    private enum TranscriptProcessingOutcome {
        case skippedEmptyRawTranscript
        case voiceMacro(command: String)
        case postProcessingSucceeded
        case postProcessingFailedFallback
        case preservedExactWording
        case fastPathShortDictation
        case preservedExactWordingTranslated
        case preservedExactWordingTranslationFailedFallback
        case commandModeSucceeded(invocation: CommandInvocation)
        case commandModeFailedFallback(invocation: CommandInvocation)

        func statusMessage(isRetry: Bool = false) -> String {
            switch self {
            case .skippedEmptyRawTranscript:
                return "Skipped macros and post-processing for empty raw transcript"
            case .voiceMacro(let command):
                return "Voice macro used: \(command)"
            case .postProcessingSucceeded:
                return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
            case .postProcessingFailedFallback:
                return isRetry
                    ? "Post-processing failed on retry, using raw transcript"
                    : "Post-processing failed, using raw transcript"
            case .preservedExactWording:
                return "Preserved exact wording, skipped post-processing"
            case .fastPathShortDictation:
                return "Short dictation, skipped post-processing for speed"
            case .preservedExactWordingTranslated:
                return "Preserved exact wording, translated to output language"
            case .preservedExactWordingTranslationFailedFallback:
                return "Verbatim translation failed, using untranslated raw transcript"
            case .commandModeSucceeded(let invocation):
                return "Edit mode succeeded (\(invocation.rawValue))"
            case .commandModeFailedFallback(let invocation):
                return "Edit mode failed, using selected text (\(invocation.rawValue))"
            }
        }
    }

    private func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String = "",
        preserveExactWording: Bool
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }

        if case .command(let invocation, let selectedText) = intent {
            do {
                let result = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: rawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage
                )
                return (result.transcript, .commandModeSucceeded(invocation: invocation), result.prompt)
            } catch {
                os_log(.error, log: recordingLog, "Edit mode failed: %{public}@", error.localizedDescription)
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }

        if let macro = findMatchingMacro(for: trimmedRawTranscript) {
            os_log(.info, log: recordingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "")
        }

        // Preserve-exact-wording mode. Two sub-cases so translation
        // stays honored:
        //
        //   1. No Output Language set — skip the LLM entirely and
        //      return the raw transcript verbatim.
        //   2. Output Language IS set — route through a stripped-down
        //      translate-only prompt. The user asked for another
        //      language; silently dropping translation defeats their
        //      settings. The translate-only path preserves filler,
        //      informal wording, and profanity 1:1 while still hitting
        //      the target language.
        if preserveExactWording {
            let targetLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if targetLanguage.isEmpty {
                return (trimmedRawTranscript, .preservedExactWording, "")
            }
            do {
                let result = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: targetLanguage
                )
                return (result.transcript, .preservedExactWordingTranslated, result.prompt)
            } catch {
                os_log(.error, log: recordingLog,
                       "Verbatim translation failed: %{public}@",
                       error.localizedDescription)
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }

        // Fast path: short, plain utterances skip the LLM round-trip entirely,
        // which removes the largest share of the release-to-paste delay.
        if TranscriptFastPath.isEnabled,
           TranscriptFastPath.shouldSkipPostProcessing(
                transcript: trimmedRawTranscript,
                outputLanguage: outputLanguage,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt
           ) {
            return (trimmedRawTranscript, .fastPathShortDictation, "")
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
            return (result.transcript, .postProcessingSucceeded, result.prompt)
        } catch {
            os_log(.error, log: recordingLog, "Post-processing failed: %{public}@", error.localizedDescription)
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: RealtimeTranscriptionService?,
        fileService: TranscriptionService,
        fileURL: URL
    ) async throws -> String {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        let releaseTime = CFAbsoluteTimeGetCurrent()
        let sessionIntent = currentSessionIntent
        currentSessionIntent = .dictation
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        let duration = audioRecorder.recordingDuration
        let hasSpeech = audioRecorder.hasDetectedSpeech
        let bufferCount = audioRecorder.bufferCount

        // Accidental tap or pure silence check:
        // If the shortcut was tapped and released very quickly (< 0.40s) without speech,
        // or if fewer than 3 buffers arrived, or if no active speech was detected and peak RMS is negligible:
        let isAccidentalOrSilent = bufferCount <= 2
            || (duration < 0.40 && !hasSpeech)
            || (!hasSpeech && audioRecorder.peakRMS < 0.003)

        if isAccidentalOrSilent {
            os_log(.info, log: recordingLog, "Discarding silent/accidental recording: duration=%.3fs buffers=%d speech=%{public}d peakRMS=%.5f", duration, bufferCount, hasSpeech, audioRecorder.peakRMS)
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            tearDownRealtimeService()
            audioRecorder.cancelRecording()
            audioRecorder.cleanup()
            isRecording = false
            restoreAudioInterruptionIfNeeded()
            overlayManager.dismiss()
            statusText = "Ready"
            clearPendingOverlayDismissToken()
            endCriticalDictationActivity()
            refreshAvailableMicrophonesIfNeeded()
            return
        }

        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        HapticFeedbackService.shared.trigger(.stopRecording)
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.isTranscribing = false
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.errorMessage = "No audio recorded"
                self.statusText = "Error"
                self.overlayManager.dismiss()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            guard self.isTranscribing else {
                self.tearDownRealtimeService()
                self.audioRecorder.cleanup()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            var timings = DictationTimings()
            timings.audioFinalize = CFAbsoluteTimeGetCurrent() - releaseTime
            let savedAudioFile = Self.saveAudioFile(from: fileURL)
            let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
            self.transcribingAudioFileName = savedAudioFile?.fileName
            self.statusText = "Transcribing..."
            self.debugStatusMessage = "Transcribing audio"

            let postProcessingService = self.makePostProcessingService()

            let activeRealtime = self.realtimeService
            self.realtimeService = nil
            self.audioRecorder.onPCM16Samples = nil
            self.transcriptionTask?.cancel()
            guard self.isTranscribing else {
                if let savedAudioFile {
                    Self.deleteAudioFile(savedAudioFile.fileName)
                }
                self.transcribingAudioFileName = nil
                activeRealtime?.cancel()
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            self.transcriptionTask = Task {
                defer {
                    activeRealtime?.cancel()
                }
                do {
                    let transcriptionService = try self.makeTranscriptionService()
                    async let transcript = Self.resolveRawTranscript(
                        realtimeService: activeRealtime,
                        fileService: transcriptionService,
                        fileURL: transcriptionFileURL
                    )
                    let transcriptionStart = CFAbsoluteTimeGetCurrent()
                    let rawTranscript = try await transcript
                    timings.transcription = CFAbsoluteTimeGetCurrent() - transcriptionStart
                    if activeRealtime != nil {
                        timings.engine = "Streaming temps réel"
                    } else if transcriptionService.usesLocalEngine {
                        timings.engine = LocalInferenceService.shared.lastEngineDescription
                    } else {
                        timings.engine = "Cloud · \(self.transcriptionModel)"
                    }
                    let parsedTranscript = Self.parseTranscriptCommands(
                        from: rawTranscript,
                        pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                    )
                    try Task.checkCancellation()
                    // Capture the parsed raw transcript as lastTranscript before
                    // post-processing runs. If anything after this throws or focus
                    // shifts mid-paste, the Paste Again shortcut still has the raw
                    // text instead of the previous dictation's stale value.
                    let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bootstrapTranscript.isEmpty {
                        await MainActor.run { [weak self] in
                            self?.lastTranscript = bootstrapTranscript
                        }
                    }
                    // The screen-context task (screenshot + vision call) can take several
                    // seconds. Do not hold the paste hostage to it: wait briefly, then fall
                    // back to lightweight app metadata. A short utterance that will skip
                    // cleanup does not need the context at all.
                    let willSkipCleanup = !sessionIntent.isCommandMode
                        && TranscriptFastPath.isEnabled
                        && TranscriptFastPath.shouldSkipPostProcessing(
                            transcript: parsedTranscript.transcript,
                            outputLanguage: self.outputLanguage,
                            customVocabulary: self.customVocabulary,
                            customSystemPrompt: self.customSystemPrompt
                        )
                    let contextWaitStart = CFAbsoluteTimeGetCurrent()
                    let appContext: AppContext
                    if let sessionContext {
                        appContext = sessionContext
                    } else if let inFlightContextTask,
                              let inFlightContext = await AsyncTimeout.value(
                                of: inFlightContextTask,
                                timeout: willSkipCleanup ? 0 : Self.maxContextWaitAfterTranscription
                              ) ?? nil {
                        appContext = inFlightContext
                    } else {
                        appContext = self.fallbackContextAtStop()
                    }
                    timings.contextWait = CFAbsoluteTimeGetCurrent() - contextWaitStart
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Running post-processing"
                    }
                    let postProcessingStart = CFAbsoluteTimeGetCurrent()
                    let result = await self.processTranscript(
                        parsedTranscript.transcript,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: self.customVocabulary,
                        customSystemPrompt: self.customSystemPrompt,
                        outputLanguage: self.outputLanguage,
                        preserveExactWording: self.preserveExactWording
                    )
                    timings.postProcessing = CFAbsoluteTimeGetCurrent() - postProcessingStart
                    if case .fastPathShortDictation = result.outcome { timings.skippedPostProcessing = true }
                    let finishedTimings = timings
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.lastDictationTimings = finishedTimings
                        os_log(.info, log: recordingLog, "Dictation latency: %{public}@", finishedTimings.summary)
                        self.lastContextSummary = appContext.contextSummary
                        self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                        self.lastContextScreenshotStatus = appContext.screenshotError
                            ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                        self.lastContextAppName = appContext.appName ?? ""
                        self.lastContextBundleIdentifier = appContext.bundleIdentifier ?? ""
                        self.lastContextWindowTitle = appContext.windowTitle ?? ""
                        self.lastContextSelectedText = appContext.selectedText ?? ""
                        self.lastContextLLMPrompt = appContext.contextPrompt ?? ""
                        let trimmedRawTranscript = parsedTranscript.transcript
                        let trimmedFinalTranscript = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let processingStatus = Self.statusMessage(
                            for: result.outcome,
                            parsedTranscript: parsedTranscript
                        )
                        self.lastPostProcessingPrompt = result.prompt
                        self.lastRawTranscript = trimmedRawTranscript
                        self.lastPostProcessedTranscript = trimmedFinalTranscript
                        self.lastPostProcessingStatus = processingStatus
                        self.recordPipelineHistoryEntry(
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: trimmedFinalTranscript,
                            postProcessingPrompt: result.prompt,
                            systemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: appContext,
                            processingStatus: processingStatus,
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.lastTranscript = trimmedFinalTranscript
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.debugStatusMessage = "Done"
                        let completionStatusText = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                        let enterOnlyStatusText = "Pressed Enter"
                        let shouldPressEnterAfterPaste = parsedTranscript.shouldPressEnterAfterPaste

                        let shouldPersistRawDictationFallback: Bool
                        switch result.outcome {
                        case .postProcessingFailedFallback,
                             .preservedExactWordingTranslationFailedFallback:
                            shouldPersistRawDictationFallback = !trimmedFinalTranscript.isEmpty
                        default:
                            shouldPersistRawDictationFallback = false
                        }

                        if trimmedFinalTranscript.isEmpty {
                            self.statusText = shouldPressEnterAfterPaste ? enterOnlyStatusText : "Nothing to transcribe"
                            self.clearPendingOverlayDismissToken()
                            if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                self.overlayManager.dismiss()
                            }
                            if shouldPressEnterAfterPaste {
                                self.pressEnterWhenShortcutReleased()
                            }
                        } else if SemanticMemoryService.shared.isEnabled && SemanticMemoryService.isMemorySearchQuery(trimmedFinalTranscript) {
                            self.executeMemorySearchQuery(trimmedFinalTranscript)
                        } else if self.isVisualPointerEnabled && VisualPointerService.isVisualPointerQuery(trimmedFinalTranscript) {
                            self.executeVisualPointerQuery(trimmedFinalTranscript)
                        } else {
                            UsageStatsStore.shared.record(
                                wordCount: DictationStatsCalculator.wordCount(in: trimmedFinalTranscript),
                                speakingSeconds: duration,
                                appName: appContext.appName
                            )
                            SemanticMemoryService.shared.record(
                                text: trimmedFinalTranscript,
                                category: .dictation,
                                sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                            )
                            if self.hasFocusedTextInput() {
                                self.statusText = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                                if shouldPersistRawDictationFallback {
                                    self.scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
                                } else {
                                    self.clearPendingOverlayDismissToken()
                                    if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                        self.overlayManager.dismiss()
                                    }
                                }

                                let pendingClipboardRestore = self.writeTranscriptToPasteboard(trimmedFinalTranscript)
                                self.pasteAtCursorWhenShortcutReleased {
                                    if shouldPressEnterAfterPaste {
                                        self.pressEnterAfterPaste {
                                            self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                        }
                                    } else {
                                        self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                    }
                                }
                            } else {
                                self.statusText = "Ready to copy"
                                self.clearPendingOverlayDismissToken()
                                if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                    self.overlayManager.showCopiedFallback(
                                        snippet: trimmedFinalTranscript,
                                        fullTranscript: trimmedFinalTranscript
                                    )
                                }
                            }
                        }

                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()

                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", enterOnlyStatusText, "Ready to copy", "Pasted at cursor!"])
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.transcriptionTask = nil
                        self.endCriticalDictationActivity()
                    }
                } catch {
                    let resolvedContext: AppContext
                    if let sessionContext {
                        resolvedContext = sessionContext
                    } else if let inFlightContextTask,
                              let inFlightContext = await AsyncTimeout.value(
                                of: inFlightContextTask,
                                timeout: Self.maxContextWaitAfterTranscription
                              ) ?? nil {
                        resolvedContext = inFlightContext
                    } else {
                        resolvedContext = self.fallbackContextAtStop()
                    }
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        self.errorMessage = userFacingErrorMessage
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.statusText = "Error"
                        self.overlayManager.showError(userFacingErrorMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.recordPipelineHistoryEntry(
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
                    }
                }
            }
        }
    }

    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
    }

    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        systemPrompt: String,
        context: AppContext,
        processingStatus: String,
        intent: SessionIntent,
        audioFileName: String? = nil
    ) {
        let newEntry = PipelineHistoryItem(
            intent: intent.persistedIntent,
            selectedText: intent.persistedSelectedText,
            capturedSelection: context.selectedText,
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    private func startRealtimeStreamingIfEnabled() {
        guard realtimeStreamingEnabled else { return }
        // OpenRouter's transcription endpoint is request/response only: no realtime socket.
        guard !TranscriptionRouting.isOpenRouterModel(transcriptionModel) else { return }
        let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            os_log(.info, log: recordingLog, "realtime streaming requested but base URL is empty — skipping")
            return
        }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = RealtimeTranscriptionService.Configuration(
            baseURL: trimmedBase,
            apiKey: resolvedTranscriptionAPIKey,
            model: model,
            language: resolvedTranscriptionLanguage
        )
        let service = RealtimeTranscriptionService(config: config)
        do {
            try service.start()
        } catch {
            os_log(.error, log: recordingLog, "failed to start realtime service: %{public}@", error.localizedDescription)
            return
        }
        realtimeService = service
        audioRecorder.onPCM16Samples = { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        audioRecorder.onPCM16Samples = nil
        realtimeService?.cancel()
        realtimeService = nil
    }

    /// Remembers whether a text field had focus when recording began. Probed off
    /// the main thread because Accessibility calls can block on unresponsive apps.
    private func recordFocusAtRecordingStart() {
        focusAtRecordingStart = nil
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let bundleIdentifier = app.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appElement = AXUIElementCreateApplication(pid)
            AppContextService.enableEnhancedAccessibility(for: appElement)
            let probe = Self.probeFocusedElement(in: appElement)
            let hadTextInput = probe.status == .found && FocusedInputClassifier.isTextInputFocused(probe)
            DispatchQueue.main.async {
                self?.focusAtRecordingStart = (bundleIdentifier: bundleIdentifier, hadTextInput: hadTextInput)
            }
        }
    }

    private func startContextCapture() {
        recordFocusAtRecordingStart()
        var prewarmURLs = [resolvedTranscriptionBaseURL, apiBaseURL]
        if rewriteProvider == .openRouter { prewarmURLs.append("https://openrouter.ai/api/v1") }
        LLMAPITransport.prewarm(baseURLs: prewarmURLs)
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastContextSummary = "Collecting app context..."
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastContextAppName = context.appName ?? ""
                self.lastContextBundleIdentifier = context.bundleIdentifier ?? ""
                self.lastContextWindowTitle = context.windowTitle ?? ""
                self.lastContextSelectedText = context.selectedText ?? ""
                self.lastContextLLMPrompt = context.contextPrompt ?? ""
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextSystemPrompt: resolvedContextSystemPrompt(),
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    private func resolvedContextSystemPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? AppContextService.defaultContextPrompt : trimmedPrompt
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasScreenRecordingPermission = false
            guard currentSessionIntent.isCommandMode else { return }
            errorMessage = message
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — stop recording
            tearDownRealtimeService()
            audioRecorder.cancelRecording()
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            isRecording = false
            restoreAudioInterruptionIfNeeded()
            shortcutSessionController.reset()
            activeRecordingTriggerMode = nil
            endCriticalDictationActivity()
            statusText = "Screenshot Required"
            overlayManager.dismiss()

            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("screen recording permission not granted")
            || lowered.contains("requires screen recording permission")
    }

    private func showScreenshotPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "\(message)\n\n\(AppName.displayName) requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Capture Failed"
        alert.informativeText = "\(message)\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    @MainActor
    private func showPostTranscriptionUpdateReminderIfNeeded() -> Bool {
        if debugShowsUpdateReminderAfterDictation {
            showDebugUpdateAvailableOverlay()
            return true
        }

        let updateManager = UpdateManager.shared
        guard updateManager.shouldShowPostTranscriptionReminder() else { return false }

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        updateManager.markPostTranscriptionReminderShown()
        overlayManager.showUpdateAvailable(version: updateManager.latestReleaseVersion)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }

        return true
    }

    @MainActor
    func showDebugUpdateAvailableOverlay() {
        let updateManager = UpdateManager.shared
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        let dismissToken = UUID()
        if isDebugOverlayActive || debugOverlayTimer != nil {
            stopDebugOverlay()
        }
        pendingOverlayDismissToken = dismissToken
        overlayManager.showUpdateAvailable(version: version)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    private func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)

        DispatchQueue.main.async {
            if UpdateManager.shared.updateAvailable {
                UpdateManager.shared.showUpdateAlert()
            }
        }
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .combinedSessionState) ?? CGEventSource(stateID: .hidSystemState)
        let vKeyCode = keyCodeForCharacter("v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        HapticFeedbackService.shared.trigger(.success)
    }

    private func keyCodeForCharacter(_ character: String) -> CGKeyCode? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { [self] in
                keyCodeForCharacter(character)
            }
        }
        guard let char = character.lowercased().utf16.first else { return nil }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    /// Executes a voice-driven search query against local semantic memory and displays results in the overlay.
    @MainActor
    private func executeMemorySearchQuery(_ query: String) {
        statusText = "Recherche en mémoire..."
        overlayManager.showTranscribing()

        Task {
            let extractedQuery = SemanticMemoryService.extractSearchQuery(query)
            let results = SemanticMemoryService.shared.search(query: extractedQuery, limit: 3)

            await MainActor.run {
                if let topResult = results.first {
                    self.overlayManager.showMemoryResult(
                        snippet: topResult.item.snippet,
                        fullText: topResult.item.text,
                        sourceApp: topResult.item.sourceAppName
                    )
                    self.statusText = "Souvenir trouvé !"
                    self.playAlertSound(named: "Glass")
                } else {
                    self.overlayManager.showError("Aucun souvenir correspondant")
                    self.playAlertSound(named: "Basso")
                    self.statusText = "Non trouvé"
                    self.scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
                }
                self.scheduleReadyStatusReset(after: 4, matching: ["Souvenir trouvé !", "Non trouvé"])
            }
        }
    }

    /// Executes an on-screen visual grounding query using Gemini 2.5 Flash and displays the target overlay.
    @MainActor
    private func executeVisualPointerQuery(_ query: String) {
        statusText = "Searching screen..."
        overlayManager.showTranscribing()

        Task {
            do {
                guard let target = try await VisualPointerService.shared.locateElement(
                    query: query,
                    apiKey: self.openRouterAPIKey,
                    model: self.openRouterModel
                ) else {
                    await MainActor.run {
                        self.overlayManager.showError("Élément introuvable sur l'écran")
                        self.playAlertSound(named: "Basso")
                        self.statusText = "Not found"
                        self.scheduleReadyStatusReset(after: 3, matching: ["Not found"])
                    }
                    return
                }

                await MainActor.run {
                    self.overlayManager.dismiss()
                    VisualPointerOverlayManager.shared.show(target: target)
                    self.statusText = "Found: \(target.label)"
                    self.scheduleReadyStatusReset(after: 4, matching: ["Found: \(target.label)"])
                }
            } catch {
                await MainActor.run {
                    self.overlayManager.showError("Erreur : \(error.localizedDescription)")
                    self.playAlertSound(named: "Basso")
                    self.statusText = "Error"
                    self.scheduleReadyStatusReset(after: 3, matching: ["Error"])
                }
            }
        }
    }

    /// Checks whether the user's active window currently has a focused text field, textarea, or text cursor.
    @MainActor
    private func hasFocusedTextInput() -> Bool {
        guard AXIsProcessTrusted() else { return true }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AppContextService.enableEnhancedAccessibility(for: appElement)

        var probe = Self.probeFocusedElement(in: appElement)
        // A first read can fail transiently right after a window or focus change;
        // one short retry avoids a false "no text field" verdict.
        if probe.status != .found {
            Thread.sleep(forTimeInterval: 0.05)
            probe = Self.probeFocusedElement(in: appElement)
        }
        if FocusedInputClassifier.isTextInputFocused(probe) { return true }

        // Fall back to what was focused when recording began, if still in the same app.
        if let start = focusAtRecordingStart,
           start.bundleIdentifier == frontmostApp.bundleIdentifier {
            return start.hadTextInput
        }
        return false
    }

    private static func probeFocusedElement(in appElement: AXUIElement) -> FocusedInputProbe {
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        switch result {
        case .success:
            break
        case .noValue:
            return FocusedInputProbe(status: .nothingFocused)
        default:
            return FocusedInputProbe(status: .unavailable)
        }
        guard let rawFocused = focusedValue, CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            return FocusedInputProbe(status: .unavailable)
        }
        let focusedElement = unsafeBitCast(rawFocused, to: AXUIElement.self)

        var probe = FocusedInputProbe(status: .found)
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleValue) == .success {
            probe.role = roleValue as? String
        }
        var rangeValue: CFTypeRef?
        probe.hasSelectedTextRange = AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
        var lineValue: CFTypeRef?
        probe.hasInsertionPointLine = AXUIElementCopyAttributeValue(
            focusedElement, kAXInsertionPointLineNumberAttribute as CFString, &lineValue) == .success
        var isSettable: DarwinBoolean = false
        probe.isValueSettable = AXUIElementIsAttributeSettable(
            focusedElement, kAXValueAttribute as CFString, &isSettable) == .success && isSettable.boolValue
        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, "AXEditable" as CFString, &editableValue) == .success {
            probe.isMarkedEditable = (editableValue as? Bool) == true
        }
        return probe
    }

    private func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Writes the final transcript to the system pasteboard.
    /// Also handles appending necessary trailing spaces, declaring transient
    /// types for clipboard managers, and saving the clipboard state for later restoration.
    /// - Parameter transcript: The text to be pasted.
    /// - Returns: A `PendingClipboardRestore` object if clipboard preservation is enabled, otherwise nil.
    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        // Append a space when ending with sentence-ending punctuation so the
        // next dictation does not jam against the prior period.
        let textToWrite: String
        if let last = transcript.last, ".!?".contains(last) {
            textToWrite = transcript + " "
        } else {
            textToWrite = transcript
        }

        if keepDictationInClipboardHistory {
            // Plain write so clipboard managers record the dictation in history.
            pasteboard.clearContents()
            pasteboard.setString(textToWrite, forType: .string)
        } else {
            // Declare standard transient types alongside .string so well-behaved
            // clipboard managers (Maccy, Raycast, Paste, Clipy, Flycut, etc.) skip
            // recording this entry in their history. The text still pastes normally
            // via Cmd-V — only clipboard history is affected.
            //
            // See: https://github.com/nicke5012/TransientPasteboardType
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

            pasteboard.declareTypes([
                .string,
                transientType,
                concealedType,
                autoGeneratedType,
                legacyTransientType
            ], owner: nil)

            pasteboard.setString(textToWrite, forType: .string)

            // Populate empty values for the marker types — some clipboard managers
            // check the data presence rather than just the declared type.
            pasteboard.setString("", forType: transientType)
            pasteboard.setString("", forType: concealedType)
            pasteboard.setString("", forType: autoGeneratedType)
            pasteboard.setString("", forType: legacyTransientType)
        }

        guard let snapshot else { return nil }
        return PendingClipboardRestore(
            snapshot: snapshot,
            expectedChangeCount: pasteboard.changeCount,
            writtenTranscript: textToWrite
        )
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        // Some apps consume Cmd-V asynchronously, so restoring too quickly can paste
        // the pre-dictation clipboard instead of the transcript.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            // A bare changeCount check is too strict: browsers, iCloud Universal
            // Clipboard sync, and other background apps bump the change count
            // without the user copying anything, which left the transcript
            // stranded on the clipboard. Restore when nothing changed, or when the
            // clipboard still holds exactly the transcript we wrote (so the user
            // has not deliberately copied something new that we would clobber).
            let clipboardStillHoldsTranscript =
                pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount
                || clipboardStillHoldsTranscript else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay) {
            action()
        }
    }

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }

    private func pressEnterWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func pressEnterAfterPaste(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = "Ready"
        }
    }
}
