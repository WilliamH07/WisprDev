import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Shared Helpers

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

struct ProviderSettingsFields: View {
    @EnvironmentObject var appState: AppState
    @Binding var apiBaseURLInput: String
    @Binding var transcriptionAPIURLInput: String
    @Binding var transcriptionAPIKeyInput: String
    @FocusState private var isEditingAPIBaseURL: Bool
    @FocusState private var isEditingTranscriptionModel: Bool
    @FocusState private var isEditingRealtimeStreamingModel: Bool
    @FocusState private var isEditingPostProcessingModel: Bool
    @FocusState private var isEditingPostProcessingFallbackModel: Bool
    @FocusState private var isEditingContextModel: Bool
    @FocusState private var transcriptionAPIURLFocused: Bool
    @FocusState private var transcriptionAPIKeyFocused: Bool
    @State private var transcriptionModelDraft: String = ""
    @State private var realtimeStreamingModelDraft: String = ""
    @State private var postProcessingModelDraft: String = ""
    @State private var postProcessingFallbackModelDraft: String = ""
    @State private var contextModelDraft: String = ""
    /// Updated by the cooldown timer so warning labels clear at expiry without user interaction.
    @State private var now: Date = Date()
    /// Tracks whether the Settings window is the frontmost active window.
    @Environment(\.controlActiveState) private var controlActiveState

    let showsModelDescription: Bool

    private func commitAPIBaseURL() {
        let trimmed = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = trimmed.isEmpty ? AppState.defaultAPIBaseURL : trimmed
        apiBaseURLInput = resolvedBaseURL
        appState.apiBaseURL = resolvedBaseURL
    }

    private func commitTranscriptionModel() {
        let trimmed = transcriptionModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionModelDraft = trimmed
        guard appState.transcriptionModel != trimmed else { return }
        appState.transcriptionModel = trimmed
    }

    private func commitRealtimeStreamingModel() {
        let trimmed = realtimeStreamingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        realtimeStreamingModelDraft = trimmed
        guard appState.realtimeStreamingModel != trimmed else { return }
        appState.realtimeStreamingModel = trimmed
    }

    private func commitPostProcessingModel() {
        let trimmed = postProcessingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        postProcessingModelDraft = trimmed
        guard appState.postProcessingModel != trimmed else { return }
        appState.postProcessingModel = trimmed
    }

    private func commitPostProcessingFallbackModel() {
        let trimmed = postProcessingFallbackModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        postProcessingFallbackModelDraft = trimmed
        guard appState.postProcessingFallbackModel != trimmed else { return }
        appState.postProcessingFallbackModel = trimmed
    }

    /// True when this view's hosting window is the frontmost key window. While true a 5s timer
    /// advances `now`, so a daily-limit warning appears within ~5s of being written and clears
    /// within ~5s of expiry. SwiftUI removes the timer when this view leaves the hierarchy
    /// (switching tabs or dismissing the Setup sheet). The timer must NOT be gated on a warning
    /// already being visible: nothing else observes the UserDefaults cooldown keys, so a freshly
    /// written cooldown would otherwise never trigger a re-render. Cost is negligible.
    private var shouldRunCooldownTimer: Bool {
        controlActiveState == .key
    }

    /// Reads the persisted daily-limit expiry date for a model directly from UserDefaults.
    /// Uses the shared key from LLMCooldownManager to avoid duplicating the storage contract.
    /// Returns nil if no daily limit is active or if the entry has already expired.
    private func dailyCooldownExpiry(for model: String) -> Date? {
        let key = LLMCooldownManager.udKey(for: model)
        let timestamp = UserDefaults.standard.double(forKey: key)
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return date > now ? date : nil
    }

    /// Formats a cooldown reset time, including the date only when the reset falls on a later day,
    /// so a daily limit that resets after midnight is not shown as an ambiguous bare time.
    private func formattedCooldownReset(_ expiry: Date) -> String {
        // Calendar.isDate(_:inSameDayAs:) is a macOS-native calendar-aware same-day comparison.
        if Calendar.current.isDate(expiry, inSameDayAs: now) {
            return expiry.formatted(date: .omitted, time: .shortened)
        }
        return expiry.formatted(date: .abbreviated, time: .shortened)
    }

    private func commitContextModel() {
        let trimmed = contextModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        contextModelDraft = trimmed
        guard appState.contextModel != trimmed else { return }
        appState.contextModel = trimmed
    }

    private func commitTranscriptionAPIURL() {
        let trimmed = transcriptionAPIURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionAPIURLInput = trimmed
        guard appState.transcriptionAPIURL != trimmed else { return }
        appState.transcriptionAPIURL = trimmed
    }

    private func commitTranscriptionAPIKey() {
        let trimmed = transcriptionAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionAPIKeyInput = trimmed
        guard appState.transcriptionAPIKey != trimmed else { return }
        appState.transcriptionAPIKey = trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Base URL")
                .font(.caption.weight(.semibold))

            Text("Change this to use a different OpenAI-compatible API provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(AppState.defaultAPIBaseURL, text: $apiBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isEditingAPIBaseURL)
                    .onSubmit {
                        commitAPIBaseURL()
                    }
                    .onChange(of: isEditingAPIBaseURL) { isEditing in
                        if !isEditing {
                            commitAPIBaseURL()
                        }
                    }

                Button("Reset to Default") {
                    apiBaseURLInput = AppState.defaultAPIBaseURL
                    appState.apiBaseURL = AppState.defaultAPIBaseURL
                }
                .font(.caption)
            }

            if showsModelDescription {
                Text("If you use another provider, enter that provider's model IDs here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ModelDropdownView(
                title: "Post-Processing Model",
                subtitle: "Used for transcript cleanup and Edit Mode transforms.",
                predefinedModels: ModelConfiguration.llmModels,
                defaultModel: AppState.defaultPostProcessingModel,
                textDraft: $postProcessingModelDraft,
                onCommit: commitPostProcessingModel,
                onReset: {
                    postProcessingModelDraft = AppState.defaultPostProcessingModel
                    appState.postProcessingModel = AppState.defaultPostProcessingModel
                }
            )

            // Shows when this model has hit its daily Groq rate limit.
            // Disappears automatically once the limit window resets.
            if let expiry = dailyCooldownExpiry(for: appState.postProcessingModel) {
                Label {
                    Text("Daily limit reached — resets at \(formattedCooldownReset(expiry))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            ModelDropdownView(
                title: "Post-Processing Fallback Model",
                subtitle: "Used as the explicit retry model for transcript cleanup and Edit Mode transforms.",
                predefinedModels: ModelConfiguration.llmModels,
                defaultModel: AppState.defaultPostProcessingFallbackModel,
                textDraft: $postProcessingFallbackModelDraft,
                onCommit: commitPostProcessingFallbackModel,
                onReset: {
                    postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
                    appState.postProcessingFallbackModel = AppState.defaultPostProcessingFallbackModel
                }
            )

            // Shows when the fallback model has also hit its daily limit.
            // In this state, both models are unavailable until their limits reset.
            if let expiry = dailyCooldownExpiry(for: appState.postProcessingFallbackModel) {
                Label {
                    Text("Fallback daily limit reached — resets at \(formattedCooldownReset(expiry))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            ModelDropdownView(
                title: "Context Model",
                subtitle: "Used for context inference, with a text-only retry when screenshot analysis fails. Screenshot analysis requires a model that accepts image input.",
                predefinedModels: ModelConfiguration.visionModels,
                defaultModel: AppState.defaultContextModel,
                textDraft: $contextModelDraft,
                onCommit: commitContextModel,
                onReset: {
                    contextModelDraft = AppState.defaultContextModel
                    appState.contextModel = AppState.defaultContextModel
                }
            )

            ModelDropdownView(
                title: "Transcription Model",
                subtitle: "Used for speech-to-text transcription.",
                predefinedModels: ModelConfiguration.transcriptionModels,
                defaultModel: AppState.defaultTranscriptionModel,
                textDraft: $transcriptionModelDraft,
                onCommit: commitTranscriptionModel,
                onReset: {
                    transcriptionModelDraft = AppState.defaultTranscriptionModel
                    appState.transcriptionModel = AppState.defaultTranscriptionModel
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription Language")
                    .font(.caption.weight(.semibold))
                Picker("", selection: $appState.transcriptionLanguage) {
                    ForEach(AppState.transcriptionLanguageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .accessibilityLabel("Transcription Language")
                .labelsHidden()
                Text("Hint to the transcription model. Auto-detect works for most users. Pick a specific language if you see wrong-script characters (for example Chinese) appear in your output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API URL")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Uses API Base URL when empty", text: $transcriptionAPIURLInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($transcriptionAPIURLFocused)
                        .onSubmit {
                            commitTranscriptionAPIURL()
                        }
                        .onChange(of: transcriptionAPIURLFocused) { isFocused in
                            if !isFocused {
                                commitTranscriptionAPIURL()
                            }
                        }
                    if !transcriptionAPIURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            transcriptionAPIURLInput = ""
                            appState.transcriptionAPIURL = ""
                        }
                        .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API Key")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Uses API Key when empty", text: $transcriptionAPIKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($transcriptionAPIKeyFocused)
                        .onSubmit {
                            commitTranscriptionAPIKey()
                        }
                        .onChange(of: transcriptionAPIKeyFocused) { isFocused in
                            if !isFocused {
                                commitTranscriptionAPIKey()
                            }
                        }
                    if !transcriptionAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear") {
                            transcriptionAPIKeyInput = ""
                            appState.transcriptionAPIKey = ""
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            Toggle(
                "Stream audio while recording (realtime)",
                isOn: $appState.realtimeStreamingEnabled
            )
            Text("Streams audio through the provider's OpenAI-compatible /v1/realtime WebSocket so transcription runs while you speak.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Realtime Transcription Model")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Required by some providers, e.g. gpt-4o-transcribe", text: $realtimeStreamingModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isEditingRealtimeStreamingModel)
                        .onSubmit {
                            commitRealtimeStreamingModel()
                        }
                        .onChange(of: isEditingRealtimeStreamingModel) { isEditing in
                            if !isEditing {
                                commitRealtimeStreamingModel()
                            }
                        }
                    if !realtimeStreamingModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Reset") {
                            realtimeStreamingModelDraft = ""
                            appState.realtimeStreamingModel = ""
                        }
                        .font(.caption)
                    }
                }
                Text("Used only for realtime streaming. Leave empty for providers that supply a server default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            transcriptionModelDraft = appState.transcriptionModel
            realtimeStreamingModelDraft = appState.realtimeStreamingModel
            postProcessingModelDraft = appState.postProcessingModel
            postProcessingFallbackModelDraft = appState.postProcessingFallbackModel
            contextModelDraft = appState.contextModel
        }
        .onChange(of: appState.transcriptionModel) { value in
            if !isEditingTranscriptionModel {
                transcriptionModelDraft = value
            }
        }
        .onChange(of: appState.realtimeStreamingModel) { value in
            if !isEditingRealtimeStreamingModel {
                realtimeStreamingModelDraft = value
            }
        }
        .onChange(of: appState.postProcessingModel) { value in
            if !isEditingPostProcessingModel {
                postProcessingModelDraft = value
            }
        }
        .onChange(of: appState.postProcessingFallbackModel) { value in
            if !isEditingPostProcessingFallbackModel {
                postProcessingFallbackModelDraft = value
            }
        }
        .onChange(of: appState.contextModel) { value in
            if !isEditingContextModel {
                contextModelDraft = value
            }
        }
        // Tick every 5s while this view's window is key so a daily-limit warning can appear and
        // auto-clear without any external state change. SwiftUI removes this timer when the
        // window is backgrounded or this view leaves the hierarchy (tab switch or sheet dismissal).
        if shouldRunCooldownTimer {
            Color.clear.frame(width: 0, height: 0)
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { value in
                    now = value
                }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.visibleCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        SettingsSidebarRow(
                            title: tab.title,
                            icon: tab.icon,
                            isSelected: appState.selectedSettingsTab == tab
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(10)
            .frame(width: 190)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .ai:
                    AISettingsView()
                case .audio:
                    AudioSettingsView()
                case .prompts:
                    PromptsSettingsView()
                case .macros:
                    VoiceMacrosSettingsView()
                case .runLog:
                    RunLogView()
                case .debug:
                    DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18, alignment: .center)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)

            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Debug Settings

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Débogage")
                    .font(.largeTitle.bold())

                SettingsCard("Overlay", icon: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show the recording overlay with simulated audio levels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                    }
                }

                SettingsCard("Update Overlay", icon: "arrow.down.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Display the update available overlay after dictation finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Show after dictation", isOn: $appState.debugShowsUpdateReminderAfterDictation)

                        Button("Show Update Overlay Now") {
                            appState.showDebugUpdateAvailableOverlay()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0
    @AppStorage("use_compact_overlay") private var useCompactOverlay = false
    @AppStorage("overlay_glass_style") private var overlayGlassStyle = OverlayGlassStyle.liquidGlass.rawValue
    @State private var screensVersion = 0
    @State private var micPermissionGranted = false
    @State private var copiedBuildInfo = false
    @State private var copiedBuildInfoResetWorkItem: DispatchWorkItem?
    @StateObject private var githubCache = GitHubMetadataCache.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    private let wisperRepoURL = URL(string: "https://github.com/WilliamH07/Wisper")!

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "\(AppName.displayName)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "WisperBuildTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "FreeFlowBuildTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var appArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var buildDiagnosticsText: String {
        "\(appDisplayName) \(appVersion) (\(appBuildNumber))\nmacOS \(macOSVersion) (\(appArchitecture))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App Branding Header
                brandingHeader

                SettingsCard("Application", icon: "power") {
                    startupSection
                }

                SettingsCard("Affichage & Overlay d'enregistrement", icon: "rectangle.dashed") {
                    overlaySection
                }

                SettingsCard("Presse-papiers & Saisie", icon: "doc.on.clipboard") {
                    clipboardSection
                }

                SettingsCard("Permissions Système", icon: "lock.shield") {
                    permissionsSection
                }

                SettingsCard("Mises à jour & Informations", icon: "arrow.triangle.2.circlepath") {
                    updatesSection
                    Divider()
                    buildInfoSection
                }
            }
            .padding(24)
        }
        .onAppear {
            checkMicPermission()
            appState.refreshLaunchAtLoginStatus()
            Task { await githubCache.fetchIfNeeded() }
        }
    }

    // MARK: Branding Header

    private var brandingHeader: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)

            Text(AppName.displayName)
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // GitHub Author card
            HStack(spacing: 8) {
                AsyncImage(url: URL(string: "https://github.com/WilliamH07.png")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())

                Button {
                    openURL(wisperRepoURL)
                } label: {
                    Text("WilliamH07/Wisper")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                    if githubCache.isLoading {
                        ProgressView().scaleEffect(0.5)
                    } else if let count = githubCache.starCount {
                        Text("\(count.formatted()) \(count == 1 ? "star" : "stars")")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.yellow.opacity(0.14)))

                Button {
                    openURL(wisperRepoURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                        Text("Star")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Lancer \(AppName.displayName) au démarrage", isOn: $appState.launchAtLogin)

            Toggle("Afficher dans la barre des menus", isOn: $showMenuBarIcon)

            Text("Les changements prennent effet immédiatement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Disposition :")
                .font(.system(size: 13, weight: .semibold))

            OverlayStyleOptionRow(
                title: "Overlay minimaliste barre des menus",
                subtitle: "Deux fines ailes discrètes de chaque côté de l'encoche, sans couvrir les fenêtres.",
                isMinimalist: true,
                selection: $useCompactOverlay
            )
            OverlayStyleOptionRow(
                title: "Pilule flottante classique",
                subtitle: "Pilule élégante sous la barre des menus affichant les niveaux audio.",
                isMinimalist: false,
                selection: $useCompactOverlay
            )

            Divider()

            Text("Finition visuelle (Design) :")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(OverlayGlassStyle.allCases) { style in
                    Button {
                        overlayGlassStyle = style.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: overlayGlassStyle == style.rawValue ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(overlayGlassStyle == style.rawValue ? Color.accentColor : Color.secondary)
                                .font(.system(size: 14))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(style.title)
                                        .font(.system(size: 13, weight: .medium))
                                    if style == .liquidGlass {
                                        Text("RECOMMANDÉ")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    }
                                }

                                Text(style.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(overlayGlassStyle == style.rawValue ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(overlayGlassStyle == style.rawValue ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            overlayDisplaySection
        }
    }

    private var overlayDisplaySection: some View {
        HStack {
            Text("Afficher sur :")
                .font(.system(size: 13))
            Spacer()
            Picker("", selection: $overlayDisplayID) {
                Text("Fenêtre active (défaut)").tag(0)
                Text("Écran principal").tag(-1)
                ForEach(connectedScreenEntries, id: \.tag) { entry in
                    Text(entry.name).tag(entry.tag)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Afficher sur")
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screensVersion &+= 1
        }
    }

    private var connectedScreenEntries: [(name: String, tag: Int)] {
        _ = screensVersion
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (name: screen.localizedName, tag: Int(id))
        }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Préserver le presse-papiers après collage", isOn: $appState.preserveClipboard)

            Text("Wisper place temporairement la transcription sur le presse-papiers pour coller votre texte, puis restaure immédiatement le contenu précédent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Exclure de l'historique du presse-papiers", isOn: Binding(
                get: { !appState.keepDictationInClipboardHistory },
                set: { appState.keepDictationInClipboardHistory = !$0 }
            ))

            Text("Empêche les gestionnaires de presse-papiers (Raycast, Maccy, Paste, etc.) d'accumuler vos dictées vocales.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Dire « press enter » pour valider automatiquement", isOn: $appState.isPressEnterVoiceCommandEnabled)

            Text("Si la dictée se termine par « press enter », Wisper supprime ces mots et simule la touche Entrée après le collage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: micPermissionGranted,
                action: {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
            )

            permissionRow(
                title: "Accessibilité",
                icon: "hand.raised.fill",
                granted: appState.hasAccessibility,
                action: {
                    appState.openAccessibilitySettings()
                }
            )

            permissionRow(
                title: "Enregistrement de l'écran",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                action: {
                    appState.requestScreenCapturePermission()
                }
            )
        }
    }

    private func permissionRow(title: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Autorisé")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Autoriser l'accès") {
                    action()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Vérifier automatiquement les mises à jour", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }
            ))

            HStack(spacing: 10) {
                Button {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if updateManager.isChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Vérification en cours…")
                        }
                    } else {
                        Text("Vérifier les mises à jour maintenant")
                    }
                }
                .disabled(updateManager.isChecking)

                if let date = updateManager.lastCheckDate {
                    Text("Dernière vérification : \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buildInfoSection: some View {
        HStack {
            Text(buildDiagnosticsText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button(copiedBuildInfo ? "Copié !" : "Copier les infos") {
                copyBuildDiagnostics()
            }
            .font(.caption)
        }
    }

    private func copyBuildDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildDiagnosticsText, forType: .string)
        copiedBuildInfo = true

        copiedBuildInfoResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedBuildInfo = false
            copiedBuildInfoResetWorkItem = nil
        }
        copiedBuildInfoResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Dictée Vocale (Touche Parler)", icon: "keyboard.fill") {
                    hotkeySection
                }

                SettingsCard("Réécriture de Texte Sélectionné", icon: "pencil.and.outline") {
                    rewriteShortcutSection
                }

                SettingsCard("Mode Assistant IA", icon: "sparkles") {
                    aiAssistantShortcutSection
                }

                SettingsCard("Gestion Audio pendant la dictée", icon: "speaker.slash.fill") {
                    dictationAudioSection
                }
            }
            .padding(24)
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictationShortcutEditor { isCapturing in
                if isCapturing {
                    appState.suspendHotkeyMonitoringForShortcutCapture()
                } else {
                    appState.resumeHotkeyMonitoringAfterShortcutCapture()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Délai de démarrage du raccourci")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(appState.shortcutStartDelayMilliseconds) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $appState.shortcutStartDelay,
                    in: 0...0.5,
                    step: 0.025
                )

                Text("Délai appliqué avant le début de capture audio pour éviter les à-coups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rewriteShortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Touche de Réécriture :")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Option (⌥ Gauche ou Droite)")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }

            Text("Sélectionnez du texte dans n'importe quelle application (IDE, navigateur, messagerie) et appuyez une fois sur Option pour le corriger, ponctuer et reformuler avec l'IA.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aiAssistantShortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Ouvrir l'Assistant IA par double-appui sur la touche Réécriture (Option)",
                isOn: $appState.isDoubleTapAIModeEnabled
            )
            .toggleStyle(.switch)

            Text("Appuyez rapidement deux fois de suite sur la touche Option pour ouvrir instantanément la fenêtre flottante de l'Assistant IA. Vous pouvez lui poser des questions au clavier, dicter votre demande à la voix ou capturer une zone de votre écran.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Tester l'accès :")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    AIAssistantWindowManager.shared.toggle(appState: appState)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("Ouvrir la fenêtre Assistant IA maintenant")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.link)
            }
        }
    }

    private var dictationAudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Couper le son système pendant la dictée",
                isOn: $appState.dictationAudioInterruptionEnabled
            )

            Text("Wisper rétablit automatiquement le volume sonore initial dès la fin de votre dictée.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    @State private var openRouterAPIKeyInput: String = ""
    @State private var isValidatingOpenRouterKey = false
    @State private var openRouterValidationError: String?
    @State private var openRouterValidationSuccess = false

    // Advanced provider
    @State private var advancedProviderSettingsExpanded = false
    @State private var apiKeyInput: String = ""
    @State private var apiBaseURLInput: String = ""
    @State private var transcriptionAPIURLInput: String = ""
    @State private var transcriptionAPIKeyInput: String = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var keyValidationSuccess = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Clé API OpenRouter", icon: "key.fill") {
                    openRouterKeySection
                }

                SettingsCard("Mode Assistant IA", icon: "sparkles") {
                    aiAssistantModelSection
                }

                SettingsCard("Réécriture & Post-traitement", icon: "wand.and.stars") {
                    rewriteModelSection
                }

                SettingsCard("Assistant Visuel d'Écran (\"Où se trouve...\")", icon: "viewfinder") {
                    visualPointerSection
                }

                SettingsCard("Mémoire Sémantique Locale (« Deuxième Cerveau »)", icon: "brain.head.profile") {
                    semanticMemorySection
                }

                SettingsCard("Serveur OpenAI / Groq personnalisé (Optionnel)", icon: "server.rack") {
                    advancedCustomProviderSection
                }
            }
            .padding(24)
        }
        .onAppear {
            openRouterAPIKeyInput = appState.openRouterAPIKey
            apiKeyInput = appState.apiKey
            apiBaseURLInput = appState.apiBaseURL
            transcriptionAPIURLInput = appState.transcriptionAPIURL
            transcriptionAPIKeyInput = appState.transcriptionAPIKey
        }
        .onChange(of: appState.openRouterAPIKey) { value in
            if openRouterAPIKeyInput != value {
                openRouterAPIKeyInput = value
            }
        }
    }

    // MARK: OpenRouter Key Section

    private var openRouterKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clé API OpenRouter (sk-or-v1-...)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Obtenir une clé sur openrouter.ai ↗") {
                    if let url = URL(string: "https://openrouter.ai/keys") {
                        openURL(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            HStack {
                SecureField("sk-or-v1-...", text: $openRouterAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: openRouterAPIKeyInput) { newValue in
                        appState.openRouterAPIKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        openRouterValidationSuccess = false
                        openRouterValidationError = nil
                    }

                Button(isValidatingOpenRouterKey ? "Test en cours…" : "Valider") {
                    testOpenRouterConnection()
                }
                .disabled(openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingOpenRouterKey)
            }

            if let error = openRouterValidationError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if openRouterValidationSuccess {
                Label("Connexion OpenRouter réussie !", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Text("Wisper utilise OpenRouter pour acheminer vos requêtes d'IA en toute flexibilité vers les meilleurs modèles mondiaux (OpenAI, Anthropic, Google Gemini, Mistral).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func testOpenRouterConnection() {
        let key = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isValidatingOpenRouterKey = true
        openRouterValidationError = nil
        openRouterValidationSuccess = false

        let model = appState.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppState.defaultOpenRouterModel : appState.openRouterModel

        Task {
            do {
                _ = try await AIAssistantService.shared.sendQuery(
                    prompt: "Ping",
                    model: model,
                    apiKey: key
                )
                await MainActor.run {
                    self.isValidatingOpenRouterKey = false
                    self.openRouterValidationSuccess = true
                }
            } catch {
                await MainActor.run {
                    self.isValidatingOpenRouterKey = false
                    self.openRouterValidationError = error.localizedDescription
                }
            }
        }
    }

    // MARK: AI Assistant Model Section

    private var aiAssistantModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Modèle par défaut :", selection: $appState.aiAssistantModel) {
                ForEach(AIAssistantModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)

            Text("Ce modèle est utilisé par la fenêtre dédiée de l'Assistant IA pour répondre à vos questions et analyser vos captures d'écran.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rewrite Model Section

    private var rewriteModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Modèle de réécriture :", selection: $appState.openRouterModel) {
                Text("Gemini 2.5 Flash (Ultra-rapide, Recommandé)").tag("google/gemini-2.5-flash")
                Text("Gemini 2.5 Flash Lite (0.4s)").tag("google/gemini-2.5-flash-lite")
                Text("Claude 3.5 Sonnet").tag("anthropic/claude-3.5-sonnet")
                Text("Nvidia Nemotron 3 Super 120B Free").tag("nvidia/nemotron-3-super-120b-a12b:free")
                Text("Mistral Small 24B Free (Français)").tag("mistralai/mistral-small-24b-instruct-2501:free")
            }
            .pickerStyle(.menu)

            HStack {
                Text("Identifiant modèle :")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("google/gemini-2.5-flash", text: $appState.openRouterModel)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Garde-fous actifs :")
                    .font(.caption.weight(.semibold))
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                    Text("Règle absolue anti-réponse : les questions sélectionnées sont corrigées, jamais répondues.")
                        .font(.caption)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                    Text("Respect du ton naturel : pas de transformation en formulation pompeuse ou diplomatique.")
                        .font(.caption)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                    Text("Vocabulaire dev & Markdown automatique (backticks, listes).")
                        .font(.caption)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: Visual Pointer Section

    private var visualPointerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Assistant d'écran visuel (\"Où se trouve...\")", isOn: $appState.isVisualPointerEnabled)

            Text("Quand cette option est activée, si vous demandez oralement \"Où se trouve le bouton X ?\" ou \"Où est Y ?\", Wisper repère l'élément sur votre écran avec Gemini 2.5 Flash et l'entoure d'un halo radar lumineux.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Semantic Memory Section

    @AppStorage("semantic_memory_enabled") private var semanticMemoryEnabled: Bool = true
    @AppStorage("semantic_memory_capture_clipboard") private var captureClipboardEnabled: Bool = false
    @AppStorage("semantic_memory_capture_terminal") private var captureTerminalEnabled: Bool = false
    @AppStorage("semantic_memory_retention_days") private var retentionDays: Int = 7
    @State private var memoryItemCount: Int = 0
    @State private var isShowingClearConfirmation = false
    @State private var manualNoteInput = ""

    private var semanticMemorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Activer la mémoire sémantique locale", isOn: $semanticMemoryEnabled)

            Text("Mémorise localement vos dictées et réécritures avec les embeddings vectoriels natifs d'Apple. 100% privé, sans aucun envoi vers des serveurs externes. La capture du presse-papiers et de l'historique du Terminal est désactivée par défaut et reste optionnelle.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if semanticMemoryEnabled {
                Divider()

                Toggle("Capturer l'historique du presse-papier", isOn: $captureClipboardEnabled)

                Text("Mémorise automatiquement vos copier-coller de texte. Les gestionnaires de mots de passe (1Password, Bitwarden, Trousseaux) et les clés privées sont strictement ignorés.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Indexer les commandes du Terminal (~/.zsh_history)", isOn: $captureTerminalEnabled)
                    .onChange(of: captureTerminalEnabled) { enabled in
                        if enabled {
                            SemanticMemoryService.shared.syncTerminalHistory()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                memoryItemCount = SemanticMemoryStore.shared.count()
                            }
                        }
                    }

                Text("Lit uniquement votre fichier d'historique de shell local (~/.zsh_history). Zéro enregistreur de frappe (aucun keylogger) et les mots de passe/tokens sont strictement filtrés. Désactivé par défaut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ajouter une note manuelle")
                        .font(.headline)

                    HStack {
                        TextField("Ex. : commande de déploiement du projet X…", text: $manualNoteInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addManualNoteFromInput()
                            }
                        Button("Ajouter") {
                            addManualNoteFromInput()
                        }
                        .buttonStyle(.bordered)
                        .disabled(manualNoteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Les notes que vous saisissez ici sont conservées en mémoire et retrouvables par recherche vocale (« Wisper, retrouve... ») et par l'Assistant IA.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Durée de conservation")
                        .font(.body)
                    Spacer()
                    Picker("", selection: $retentionDays) {
                        Text("7 jours").tag(7)
                        Text("30 jours").tag(30)
                        Text("Illimitée").tag(-1)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text("\(memoryItemCount) souvenir\(memoryItemCount > 1 ? "s" : "") en mémoire")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        SemanticMemoryService.shared.syncTerminalHistory()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            memoryItemCount = SemanticMemoryStore.shared.count()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text("Indexer le Terminal")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        isShowingClearConfirmation = true
                    } label: {
                        Text("Vider la mémoire")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Effacer tous les souvenirs ?",
                        isPresented: $isShowingClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Tout supprimer", role: .destructive) {
                            SemanticMemoryStore.shared.clearAll()
                            memoryItemCount = 0
                        }
                        Button("Annuler", role: .cancel) {}
                    } message: {
                        Text("Cette action supprimera définitivement tous les éléments indexés dans votre base de mémoire locale.")
                    }
                }
                .padding(.top, 4)

                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text("Astuce : dites oralement « Wisper, retrouve... » ou « C'était quoi... » pour rechercher un souvenir instantanément.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
        }
        .onAppear {
            memoryItemCount = SemanticMemoryStore.shared.count()
        }
    }

    private func addManualNoteFromInput() {
        let note = manualNoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        if SemanticMemoryService.shared.addManualNote(note) {
            manualNoteInput = ""
            memoryItemCount = SemanticMemoryStore.shared.count()
        }
    }

    // MARK: Advanced Custom Provider Section

    private var advancedCustomProviderSection: some View {
        DisclosureGroup(isExpanded: $advancedProviderSettingsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text("Cette section est optionnelle. Wisper utilise par défaut Whisper Local (pour l'audio) et OpenRouter (pour l'IA). Si vous disposez d'un serveur local ou d'un compte OpenAI / Groq dédié, vous pouvez configurer vos clés et URL ici.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    SecureField("Clé API OpenAI / Groq (Optionnel)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isValidatingKey)
                        .onChange(of: apiKeyInput) { _ in
                            keyValidationError = nil
                            keyValidationSuccess = false
                        }

                    Button(isValidatingKey ? "Validation…" : "Enregistrer") {
                        validateAndSaveKey()
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
                }

                if let error = keyValidationError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else if keyValidationSuccess {
                    Label("Clé API enregistrée", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                ProviderSettingsFields(
                    apiBaseURLInput: $apiBaseURLInput,
                    transcriptionAPIURLInput: $transcriptionAPIURLInput,
                    transcriptionAPIKeyInput: $transcriptionAPIKeyInput,
                    showsModelDescription: false
                )
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Configuration avancée de serveur tiers (Optionnel)")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                advancedProviderSettingsExpanded.toggle()
            }
        }
    }

    private func validateAndSaveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingKey = true
        keyValidationError = nil
        keyValidationSuccess = false

        Task {
            let valid = await TranscriptionService.validateAPIKey(
                key,
                baseURL: baseURL.isEmpty ? AppState.defaultAPIBaseURL : baseURL
            )
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    keyValidationSuccess = true
                } else {
                    keyValidationError = "Échec de validation. Vérifiez votre clé et URL, puis réessayez."
                }
            }
        }
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("haptic_feedback_enabled") private var hapticFeedbackEnabled = true
    @State private var customVocabularyInput: String = ""
    @FocusState private var customVocabularyFocused: Bool
    @State private var showMutedHint = false

    private static let outputLanguageOptions = [
        "",
        "English",
        "Chinese (Simplified)",
        "Chinese (Traditional)",
        "Spanish",
        "French",
        "Japanese",
        "Korean",
        "German",
        "Portuguese",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Source Microphone", icon: "mic.fill") {
                    microphoneSection
                    Divider()
                    soundVolumeSection
                }

                SettingsCard("Sensations Tactiles (Trackpad Force Touch)", icon: "hand.tap.fill") {
                    hapticFeedbackSection
                }

                SettingsCard("Filtre Anti-Bruit & Anti-Silence", icon: "waveform.badge.minus") {
                    antiSilenceFilterSection
                }

                SettingsCard("Langue de Dictée", icon: "globe") {
                    outputLanguageSection
                }

                SettingsCard("Vocabulaire Personnalisé", icon: "character.book.closed") {
                    vocabularySection
                }

                SettingsCard("Moteur Whisper Local (Metal GPU)", icon: "cpu") {
                    whisperLocalStatusSection
                }
            }
            .padding(24)
        }
        .onAppear {
            customVocabularyInput = appState.customVocabulary
            appState.refreshAvailableMicrophones()
        }
        .onDisappear {
            commitCustomVocabulary()
        }
    }

    // MARK: Microphone Section

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sélectionnez le microphone utilisé pour la dictée vocale.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                MicrophoneOptionRow(
                    name: "Par défaut du système",
                    isSelected: appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = "default" }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.uid,
                        action: { appState.selectedMicrophoneID = device.uid }
                    )
                }
            }
        }
    }

    // MARK: Sound Volume Section

    private var soundVolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Émettre les sons de confirmation (bip, cloche)", isOn: $appState.alertSoundsEnabled)

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\(Int(appState.soundVolume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!appState.alertSoundsEnabled)
            .opacity(appState.alertSoundsEnabled ? 1 : 0.5)

            HStack(spacing: 8) {
                Button("Tester le son") {
                    let muted = SystemAudioStatus.isDefaultOutputMuted()
                    let volume = SystemAudioStatus.defaultOutputVolume()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMutedHint = muted || (volume ?? 1) < 0.10
                    }
                    appState.playAlertSound(named: "Tink")
                }
                .font(.caption)
                .disabled(!appState.alertSoundsEnabled)

                if showMutedHint {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
                        Text("Le volume système est bas ou coupé.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Haptic Feedback Section

    private var hapticFeedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Activer les retours haptiques sur le trackpad", isOn: $hapticFeedbackEnabled)

            Text("Produit un clic tactile feutré au début de la parole, à l'arrêt de l'enregistrement et lors du collage du texte.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Tester le clic Force Touch") {
                HapticFeedbackService.shared.trigger(.success)
            }
            .font(.caption)
            .disabled(!hapticFeedbackEnabled)
        }
    }

    // MARK: Anti-Silence Filter Section

    private var antiSilenceFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Filtre Anti-Bruit & Anti-Silence Actif")
                    .font(.caption.weight(.semibold))
            }

            Text("Wisper analyse en temps réel l'énergie vocale. Si vous effleurez la touche par inadvertance ou relâchez la touche sans avoir parlé, la dictée est annulée silencieusement sans bruit parasite ni collage indésirable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Output Language Section

    private var outputLanguageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Langue de transcription :", selection: $appState.outputLanguage) {
                Text("Identique à la langue parlée").tag("")
                ForEach(Self.outputLanguageOptions.dropFirst(), id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .pickerStyle(.menu)

            Text("Laissez sur « Identique » pour transcrire automatiquement le français ou l'anglais tel que prononcé.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Vocabulary Section

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Termes techniques, noms propres, acronymes ou abréviations à préserver.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customVocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 120)
                .focused($customVocabularyFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customVocabularyFocused) { focused in
                    if !focused { commitCustomVocabulary() }
                }

            Text("Séparez les mots par des virgules ou des retours à la ligne.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitCustomVocabulary() {
        let trimmed = customVocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.customVocabulary != trimmed {
            appState.customVocabulary = trimmed
        }
    }

    // MARK: Whisper Local Status Section

    private var whisperLocalStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Statut du moteur STT :")
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("whisper-server Actif (Port 8085, GPU Metal M4)")
                        .foregroundStyle(.green)
                        .font(.caption.weight(.medium))
                }
            }

            Text("Modèle : ggml-large-v3-turbo.bin (800M paramètres, ~1.2s de latence, 100% sur l'accélérateur Metal Apple Silicon). Vos enregistrements audio restent sur votre machine et ne sont jamais transmis sur internet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Redémarrer le moteur Whisper") {
                    Task {
                        _ = await LocalInferenceService.shared.restartServer()
                    }
                }
                .font(.caption)

                Spacer()

                Button("Ouvrir le dossier des modèles ↗") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: LocalInferenceService.modelsDirectory.path)
                }
                .font(.caption)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Prompts Settings

struct PromptsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var customSystemPromptInput: String = ""
    @State private var customContextPromptInput: String = ""
    @FocusState private var customSystemPromptFocused: Bool
    @FocusState private var customContextPromptFocused: Bool
    @State private var showDefaultSystemPrompt = false
    @State private var showDefaultContextPrompt = false

    // System prompt test state
    @State private var systemTestInput: String = "Um, so I was like, thinking we should uh, refactor the authentication module, you know?"
    @State private var systemTestRunning = false
    @State private var systemTestOutput: String? = nil
    @State private var systemTestError: String? = nil
    @State private var systemTestPrompt: String? = nil

    // Context prompt test state
    @State private var contextTestRunning = false
    @State private var contextTestOutput: String? = nil
    @State private var contextTestError: String? = nil
    @State private var contextTestPrompt: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("System Prompt", icon: "text.bubble.fill") {
                    systemPromptSection
                }
                SettingsCard("Instruction Guard", icon: "shield.lefthalf.filled") {
                    instructionGuardSection
                }
                SettingsCard("Context Prompt", icon: "eye.fill") {
                    contextPromptSection
                }
            }
            .padding(24)
        }
        .onAppear {
            if appState.customSystemPrompt.isEmpty {
                customSystemPromptInput = (appState.transcriptionModel == "whisper-local")
                    ? PostProcessingService.localFastSystemPrompt
                    : PostProcessingService.defaultSystemPrompt
            } else {
                customSystemPromptInput = appState.customSystemPrompt
            }
            customContextPromptInput = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
        .onDisappear {
            commitCustomSystemPrompt()
            commitCustomContextPrompt()
        }
    }

    private func commitCustomSystemPrompt() {
        let trimmed = customSystemPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = PostProcessingService.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let localTrimmed = PostProcessingService.localFastSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == defaultTrimmed || trimmed == localTrimmed || trimmed.isEmpty {
            if !appState.customSystemPrompt.isEmpty {
                appState.customSystemPrompt = ""
                appState.customSystemPromptLastModified = ""
            }
        } else if appState.customSystemPrompt != trimmed {
            appState.customSystemPrompt = trimmed
            appState.customSystemPromptLastModified = iso8601DayFormatter.string(from: Date())
        }
    }

    private func commitCustomContextPrompt() {
        let trimmed = customContextPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = AppContextService.defaultContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == defaultTrimmed || trimmed.isEmpty {
            if !appState.customContextPrompt.isEmpty {
                appState.customContextPrompt = ""
                appState.customContextPromptLastModified = ""
            }
        } else if appState.customContextPrompt != trimmed {
            appState.customContextPrompt = trimmed
            appState.customContextPromptLastModified = iso8601DayFormatter.string(from: Date())
        }
    }

    // MARK: System Prompt

    private var systemPromptSection: some View {
        let isCustom = !appState.customSystemPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customSystemPromptLastModified.isEmpty
            && appState.customSystemPromptLastModified < PostProcessingService.defaultSystemPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how raw transcriptions are cleaned up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") {
                        showDefaultSystemPrompt.toggle()
                    }
                    .font(.caption)
                    Button("Switch to Default") {
                        customSystemPromptInput = PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultSystemPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default System Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") {
                            showDefaultSystemPrompt = false
                        }
                        .font(.caption)
                    }
                    Text(PostProcessingService.defaultSystemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customSystemPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .focused($customSystemPromptFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customSystemPromptFocused) { focused in
                    if !focused { commitCustomSystemPrompt() }
                }

            HStack {
                if isCustom {
                    Label("Prompt personnalisé actif", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label(appState.transcriptionModel == "whisper-local" ? "Prompt français M4 actif" : "Prompt par défaut actif", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Passer au prompt français M4") {
                    customSystemPromptInput = PostProcessingService.localFastSystemPrompt
                    appState.customSystemPrompt = PostProcessingService.localFastSystemPrompt
                    appState.customSystemPromptLastModified = iso8601DayFormatter.string(from: Date())
                }
                .font(.caption)

                if isCustom {
                    Button("Réinitialiser") {
                        customSystemPromptInput = (appState.transcriptionModel == "whisper-local") ? PostProcessingService.localFastSystemPrompt : PostProcessingService.defaultSystemPrompt
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                    }
                    .font(.caption)
                }
            }

            Divider()

            // Test section
            VStack(alignment: .leading, spacing: 8) {
                Text("Test System Prompt")
                    .font(.caption.weight(.semibold))
                Text("Enter sample text to see how the current prompt cleans it up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $systemTestInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                Button {
                    runSystemPromptTest()
                } label: {
                    HStack(spacing: 6) {
                        if systemTestRunning {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test System Prompt")
                        }
                    }
                }
                .disabled(systemTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || systemTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = systemTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let output = systemTestOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(output.isEmpty ? "(empty — no output)" : output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                    }
                }

                if let prompt = systemTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var instructionGuardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Prevent dictated prompts from being executed",
                isOn: $appState.instructionExecutionGuardEnabled
            )
            .toggleStyle(.switch)

            Text("When enabled, Wisper retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runSystemPromptTest() {
        commitCustomSystemPrompt()
        systemTestRunning = true
        systemTestOutput = nil
        systemTestError = nil
        systemTestPrompt = nil

        let service = PostProcessingService(
            apiKey: appState.apiKey,
            baseURL: appState.apiBaseURL,
            preferredModel: appState.postProcessingModel,
            preferredFallbackModel: appState.postProcessingFallbackModel,
            instructionExecutionGuardEnabled: appState.instructionExecutionGuardEnabled
        )
        let input = systemTestInput
        let customPrompt = appState.customSystemPrompt
        let vocabulary = appState.customVocabulary

        let context = AppContext(
            appName: "\(AppName.displayName) Settings",
            bundleIdentifier: "com.williamh07.wisper",
            windowTitle: "System Prompt Test",
            selectedText: nil,
            currentActivity: "User is testing the system prompt in \(AppName.displayName) settings.",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil
        )

        Task {
            do {
                let result = try await service.postProcess(
                    transcript: input,
                    context: context,
                    customVocabulary: vocabulary,
                    customSystemPrompt: customPrompt
                )
                await MainActor.run {
                    systemTestOutput = result.transcript
                    systemTestPrompt = result.prompt
                    systemTestRunning = false
                }
            } catch {
                await MainActor.run {
                    systemTestError = error.localizedDescription
                    systemTestRunning = false
                }
            }
        }
    }

    // MARK: Context Prompt

    private var contextPromptSection: some View {
        let isCustom = !appState.customContextPrompt.isEmpty
        let hasNewerDefault = isCustom
            && !appState.customContextPromptLastModified.isEmpty
            && appState.customContextPromptLastModified < AppContextService.defaultContextPromptDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("Controls how \(AppName.displayName) infers your current activity from app metadata and screenshots.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasNewerDefault {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("A newer default prompt is available.")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("View Default") {
                        showDefaultContextPrompt.toggle()
                    }
                    .font(.caption)
                    Button("Switch to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            if showDefaultContextPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Context Prompt")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Hide") {
                            showDefaultContextPrompt = false
                        }
                        .font(.caption)
                    }
                    Text(AppContextService.defaultContextPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            TextEditor(text: $customContextPromptInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .focused($customContextPromptFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customContextPromptFocused) { focused in
                    if !focused { commitCustomContextPrompt() }
                }

            HStack {
                if isCustom {
                    Label("Using custom prompt", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("Using default", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCustom {
                    Button("Reset to Default") {
                        customContextPromptInput = AppContextService.defaultContextPrompt
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                    }
                    .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Screenshot Resolution")
                    .font(.caption.weight(.semibold))

                Text("Controls the maximum image dimension sent for context inference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $appState.contextScreenshotMaxDimension) {
                    ForEach(AppState.contextScreenshotDimensionOptions, id: \.self) { dimension in
                        Text("\(dimension) px").tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Screenshot Resolution")

                HStack {
                    if appState.contextScreenshotMaxDimension == AppState.defaultContextScreenshotMaxDimension {
                        Label("Using default", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Using custom value", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    if appState.contextScreenshotMaxDimension != AppState.defaultContextScreenshotMaxDimension {
                        Button("Reset to Default") {
                            appState.contextScreenshotMaxDimension = AppState.defaultContextScreenshotMaxDimension
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            // Test section
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Context Prompt")
                    .font(.caption.weight(.semibold))
                Text("Captures a screenshot and metadata from the frontmost app, then runs the context prompt to infer activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    runContextPromptTest()
                } label: {
                    HStack(spacing: 6) {
                        if contextTestRunning {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test Context Prompt")
                        }
                    }
                }
                .disabled(contextTestRunning || appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = contextTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let output = contextTestOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(output.isEmpty ? "(empty — no output)" : output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                    }
                }

                if let prompt = contextTestPrompt {
                    DisclosureGroup("Full prompt sent") {
                        Text(prompt)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runContextPromptTest() {
        commitCustomContextPrompt()
        contextTestRunning = true
        contextTestOutput = nil
        contextTestError = nil
        contextTestPrompt = nil

        let service = appState.makeAppContextService()

        Task {
            let context = await service.collectContext()
            await MainActor.run {
                if let prompt = context.contextPrompt {
                    contextTestOutput = context.contextSummary
                    contextTestPrompt = prompt
                } else {
                    contextTestError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                    contextTestOutput = context.contextSummary
                }
                contextTestRunning = false
            }
        }
    }

}

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(.headline)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Clear History") {
                    appState.clearPipelineHistory()
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if appState.pipelineHistory.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs yet. Use dictation to populate history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

// MARK: - Run Log Entry

struct RunLogEntryView: View {
    private let actionIconSize: CGFloat = 28
    let item: PipelineHistoryItem
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false
    @State private var isRetrying = false
    @State private var showContextPrompt = false
    @State private var showPostProcessingPrompt = false
    @State private var copiedTranscript = false
    @State private var copiedTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedRawTranscript = false
    @State private var copiedRawTranscriptResetWorkItem: DispatchWorkItem?
    @State private var copiedCleanedTranscript = false
    @State private var copiedCleanedTranscriptResetWorkItem: DispatchWorkItem?

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var copyableTranscript: String {
        if !item.postProcessedTranscript.isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    @ViewBuilder
    private func actionIconButton(
        systemName: String,
        color: Color = .secondary,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: actionIconSize, height: actionIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            HStack(spacing: 0) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: actionIconSize, height: actionIconSize)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        if isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.timestamp.formatted(date: .numeric, time: .standard))
                                .font(.subheadline.weight(.semibold))
                            Text(item.postProcessedTranscript.isEmpty ? "(no transcript)" : item.postProcessedTranscript)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    if isError && item.audioFileName != nil {
                        Button {
                            appState.retryTranscription(item: item)
                        } label: {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: actionIconSize, height: actionIconSize)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: actionIconSize, height: actionIconSize)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetrying)
                        .help("Retry transcription")
                    } else {
                        Color.clear
                            .frame(width: actionIconSize, height: actionIconSize)
                    }

                    actionIconButton(systemName: "square.and.arrow.up", help: "Export run log") {
                        TestCaseExporter.exportWithSavePanel(
                            item: item,
                            audioDirURL: AppState.audioStorageDirectory()
                        )
                    }

                    actionIconButton(
                        systemName: copiedTranscript ? "checkmark" : "doc.on.doc",
                        color: copiedTranscript ? .green : .secondary,
                        help: copiedTranscript ? "Copied transcript" : "Copy transcript",
                        disabled: copyableTranscript.isEmpty
                    ) {
                        copyTranscriptToPasteboard()
                    }

                    actionIconButton(systemName: "trash", help: "Delete this run") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.deleteHistoryEntry(id: item.id)
                        }
                    }
                }
            }
            .padding(12)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 16) {
                    // Audio player
                    if let audioFileName = item.audioFileName {
                        let audioURL = AppState.audioStorageDirectory().appendingPathComponent(audioFileName)
                        AudioPlayerView(audioURL: audioURL)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("No audio recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Custom vocabulary
                    if !item.customVocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom Vocabulary")
                                .font(.caption.weight(.semibold))
                            FlowLayout(spacing: 4) {
                                ForEach(parseVocabulary(item.customVocabulary), id: \.self) { word in
                                    Text(word)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }

                    // Pipeline steps
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pipeline")
                            .font(.caption.weight(.semibold))

                        // Step 1: Context Capture
                        PipelineStepView(
                            number: 1,
                            title: "Capture Context",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let dataURL = item.contextScreenshotDataURL,
                                       let image = imageFromDataURL(dataURL) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 120)
                                            .cornerRadius(4)
                                    }

                                    if let prompt = item.contextPrompt, !prompt.isEmpty {
                                        Button {
                                            showContextPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showContextPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showContextPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showContextPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.contextSummary.isEmpty {
                                        Text(item.contextSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    } else {
                                        Text("No context captured")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 2: Transcribe Audio
                        PipelineStepView(
                            number: 2,
                            title: "Transcribe Audio",
                            content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Sent audio to the configured transcription model")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if !item.rawTranscript.isEmpty {
                                        Text(item.rawTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .padding(.trailing, 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    copyRawTranscriptToPasteboard()
                                                } label: {
                                                    Image(systemName: copiedRawTranscript ? "checkmark" : "doc.on.doc")
                                                        .font(.caption)
                                                        .foregroundStyle(copiedRawTranscript ? .green : .secondary)
                                                        .padding(6)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help(copiedRawTranscript ? "Copied literal transcript" : "Copy literal transcript")
                                            }
                                    } else {
                                        Text("(empty transcript)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        )

                        // Step 3: Post-Process
                        PipelineStepView(
                            number: 3,
                            title: "Post-Process",
                            content: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.postProcessingStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                    if let prompt = item.postProcessingPrompt, !prompt.isEmpty {
                                        Button {
                                            showPostProcessingPrompt.toggle()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(showPostProcessingPrompt ? "Hide Prompt" : "Show Prompt")
                                                    .font(.caption)
                                                Image(systemName: showPostProcessingPrompt ? "chevron.up" : "chevron.down")
                                                    .font(.caption2)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        if showPostProcessingPrompt {
                                            Text(prompt)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(nsColor: .controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if !item.postProcessedTranscript.isEmpty {
                                        Text(item.postProcessedTranscript)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .padding(.trailing, 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    copyCleanedTranscriptToPasteboard()
                                                } label: {
                                                    Image(systemName: copiedCleanedTranscript ? "checkmark" : "doc.on.doc")
                                                        .font(.caption)
                                                        .foregroundStyle(copiedCleanedTranscript ? .green : .secondary)
                                                        .padding(6)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help(copiedCleanedTranscript ? "Copied cleaned transcript" : "Copy cleaned transcript")
                                            }
                                    }
                                }
                            }
                        )
                    }

                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onReceive(appState.$retryingItemIDs) { ids in
            isRetrying = ids.contains(item.id)
        }
    }

    private func parseVocabulary(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func copyTranscriptToPasteboard() {
        guard !copyableTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableTranscript, forType: .string)
        copiedTranscript = true

        copiedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedTranscript = false
            copiedTranscriptResetWorkItem = nil
        }
        copiedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyRawTranscriptToPasteboard() {
        guard !item.rawTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.rawTranscript, forType: .string)
        copiedRawTranscript = true

        copiedRawTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedRawTranscript = false
            copiedRawTranscriptResetWorkItem = nil
        }
        copiedRawTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    private func copyCleanedTranscriptToPasteboard() {
        guard !item.postProcessedTranscript.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.postProcessedTranscript, forType: .string)
        copiedCleanedTranscript = true

        copiedCleanedTranscriptResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem {
            copiedCleanedTranscript = false
            copiedCleanedTranscriptResetWorkItem = nil
        }
        copiedCleanedTranscriptResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }
}

// MARK: - Pipeline Step View

struct PipelineStepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        if let p = try? AVAudioPlayer(contentsOf: audioURL) {
            duration = p.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Voice Macros Settings

struct VoiceMacrosSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddMacro = false
    @State private var editingMacro: VoiceMacro?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Voice Macros", icon: "music.mic") {
                    macrosSection
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAddMacro, onDismiss: { editingMacro = nil }) {
            VoiceMacroEditorView(isPresented: $showingAddMacro, macro: $editingMacro)
        }
    }

    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bypass post-processing and immediately paste your predefined text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showingAddMacro = true }) {
                    Text("Add Macro")
                }
            }

            if appState.voiceMacros.isEmpty {
                VStack {
                    Image(systemName: "music.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                    Text("No Voice Macros Yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Click 'Add Macro' to define your first voice macro.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(appState.voiceMacros.enumerated()), id: \.element.id) { index, macro in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(macro.command)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingMacro = macro
                                    showingAddMacro = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                
                                Button("Delete") {
                                    appState.voiceMacros.removeAll { $0.id == macro.id }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Text(macro.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    }
                }
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

struct VoiceMacroEditorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @Binding var macro: VoiceMacro?

    @State private var command: String = ""
    @State private var payload: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Command (What you say)")
                    .font(.caption.weight(.semibold))
                TextField("e.g. debugging prompt", text: $command)
                    .textFieldStyle(.roundedBorder)

                Text("Text (What gets pasted)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 8)
                TextEditor(text: $payload)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                    macro = nil
                }
                Spacer()
                Button("Save") {
                    let newMacro = VoiceMacro(
                        id: macro?.id ?? UUID(),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        payload: payload
                    )
                    
                    if let existingIndex = appState.voiceMacros.firstIndex(where: { $0.id == newMacro.id }) {
                        appState.voiceMacros[existingIndex] = newMacro
                    } else {
                        appState.voiceMacros.append(newMacro)
                    }
                    isPresented = false
                    macro = nil
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let m = macro {
                command = m.command
                payload = m.payload
            }
        }
    }
}
