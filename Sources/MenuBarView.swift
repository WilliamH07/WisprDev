import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        if !item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        let text = transcriptText(for: item)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "(no transcript)" }
        return text.count > 48 ? String(text.prefix(48)) + "..." : text
    }

    private func copyTranscriptToPasteboard(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func openRunLog() {
        appState.selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func memoryIcon(for category: SemanticMemoryCategory) -> String {
        switch category {
        case .clipboard: return "📋"
        case .dictation: return "🎙️"
        case .rewrite: return "✨"
        case .terminal: return "💻"
        case .manualNote: return "📝"
        }
    }

    private func addManualMemoryNote() {
        let alert = NSAlert()
        alert.messageText = "Ajouter une note à la mémoire"
        alert.informativeText = "Cette note sera conservée localement et retrouvable par recherche vocale et par l'Assistant IA."
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        input.placeholderString = "Ex. : commande de déploiement du projet X…"
        alert.accessoryView = input

        alert.addButton(withTitle: "Ajouter")
        alert.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SemanticMemoryService.shared.addManualNote(input.stringValue)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(AppName.displayName) v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            if !appState.hasScreenRecordingPermission {
                Button {
                    appState.requestScreenCapturePermission()
                } label: {
                    Label("Screen Recording Permission Needed", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)

                Divider()
            }

            // Accessibility warning
            if !appState.hasAccessibility {
                Button {
                    appState.showAccessibilityAlert()
                } label: {
                    Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red)

                Divider()
            }

            // Status
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text(appState.shortcutStatusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            // Manual toggle
            Button(appState.isRecording ? "Stop Recording" : "Start Dictating") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                Divider()
                Text(hotkeyError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if let error = appState.errorMessage {
                Divider()
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            Divider()

            Button("Mode Assistant IA  (Double-appui \(appState.rewriteSelectionShortcut.isDisabled ? "Option" : appState.rewriteSelectionShortcut.displayName))") {
                AIAssistantWindowManager.shared.toggle(appState: appState)
            }

            if !appState.isRecording && !appState.isTranscribing && !appState.isRewritingText {
                Button(appState.rewriteSelectionShortcut.isDisabled
                    ? "Rewrite Selected Text"
                    : "Rewrite Selected Text  (\(appState.rewriteSelectionShortcut.displayName))") {
                    appState.triggerRewriteSelectedText()
                }
            }

            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Button(appState.copyAgainShortcut.isDisabled
                    ? "Paste Again"
                    : "Paste Again  (\(appState.copyAgainShortcut.displayName))") {
                    appState.copyLastTranscriptToPasteboard()
                }

                let truncatedTranscript = appState.lastTranscript.count > 35
                    ? String(appState.lastTranscript.prefix(35)) + "…"
                    : appState.lastTranscript
                Text("\u{201C}\(truncatedTranscript)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            Menu("History") {
                if recentHistoryItems.isEmpty {
                    Text("No transcripts yet")
                } else {
                    ForEach(recentHistoryItems) { item in
                        let transcript = transcriptText(for: item)
                        Button {
                            copyTranscriptToPasteboard(transcriptFull(for: item))
                        } label: {
                            Text(transcriptSnippet(for: item))
                        }
                        .disabled(transcript.isEmpty)
                    }

                    Divider()
                }

                Button("Open Run Log") {
                    openRunLog()
                }
            }

            Menu("🧠 Mémoire (« Deuxième Cerveau »)") {
                let memories = SemanticMemoryStore.shared.fetchRecent(limit: 6)
                if memories.isEmpty {
                    Text("Aucun souvenir mémorisé")
                } else {
                    ForEach(memories) { item in
                        Button {
                            copyTranscriptToPasteboard(item.text)
                        } label: {
                            let icon = memoryIcon(for: item.category)
                            let app = item.sourceAppName.isEmpty ? "" : "[\(item.sourceAppName)] "
                            Text("\(icon) \(app)\(item.snippet)")
                        }
                    }
                    Divider()
                }

                Button("Ajouter une Note à la Mémoire...") {
                    addManualMemoryNote()
                }

                Button("Ouvrir l'Assistant IA avec Mémoire") {
                    AIAssistantWindowManager.shared.toggle(appState: appState)
                }

                Button("Gérer la Mémoire...") {
                    appState.selectedSettingsTab = .ai
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Divider()

            Button("Paste Custom Word to Vocabulary") {
                if appState.pasteWordToVocabulary() != nil {
                    VocabularyNotificationManager.shared.flashCheckmark()
                }
            }

            Divider()

            Menu("Hold Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .hold)
                } label: {
                    if appState.holdShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .hold)
                    } label: {
                        if appState.holdShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.toggleShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .hold) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .hold)
                    } label: {
                        if appState.holdShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Toggle Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .toggle)
                } label: {
                    if appState.toggleShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.holdShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .toggle) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .toggle)
                    } label: {
                        if appState.toggleShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Paste Again Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .copyAgain)
                } label: {
                    if appState.copyAgainShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                ForEach(ShortcutPreset.allCases) { preset in
                    Button {
                        _ = appState.setShortcut(preset.binding, for: .copyAgain)
                    } label: {
                        if appState.copyAgainShortcut == preset.binding {
                            Text("✓ \(preset.title)")
                        } else {
                            Text("  \(preset.title)")
                        }
                    }
                    .disabled(preset.binding == appState.holdShortcut || preset.binding == appState.toggleShortcut)
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .copyAgain) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .copyAgain)
                    } label: {
                        if appState.copyAgainShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Rewrite Shortcut") {
                Button {
                    _ = appState.setShortcut(.disabled, for: .rewriteSelection)
                } label: {
                    if appState.rewriteSelectionShortcut.isDisabled {
                        Text("✓ Disabled")
                    } else {
                        Text("  Disabled")
                    }
                }

                if let savedCustomShortcut = appState.savedCustomShortcut(for: .rewriteSelection) {
                    Divider()
                    Button {
                        _ = appState.setShortcut(savedCustomShortcut, for: .rewriteSelection)
                    } label: {
                        if appState.rewriteSelectionShortcut == savedCustomShortcut {
                            Text("✓ Custom: \(savedCustomShortcut.displayName)")
                        } else {
                            Text("  Custom: \(savedCustomShortcut.displayName)")
                        }
                    }
                } else if !appState.rewriteSelectionShortcut.isDisabled {
                    Divider()
                    Button {
                        _ = appState.setShortcut(appState.rewriteSelectionShortcut, for: .rewriteSelection)
                    } label: {
                        Text("✓ \(appState.rewriteSelectionShortcut.displayName)")
                    }
                }

                Divider()
                Button("Customize…") {
                    appState.selectedSettingsTab = .shortcuts
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
            }

            Menu("Microphone") {
                Button {
                    appState.selectedMicrophoneID = "default"
                } label: {
                    if appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty {
                        Text("✓ System Default")
                    } else {
                        Text("  System Default")
                    }
                }
                ForEach(appState.availableMicrophones) { device in
                    Button {
                        appState.selectedMicrophoneID = device.uid
                    } label: {
                        if appState.selectedMicrophoneID == device.uid {
                            Text("✓ \(device.name)")
                        } else {
                            Text("  \(device.name)")
                        }
                    }
                }
            }

            Button("Re-run Setup...") {
                NotificationCenter.default.post(name: .showSetup, object: nil)
            }

            Button("Settings") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }

            Button {
                Task {
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            } label: {
                HStack(spacing: 6) {
                    if updateManager.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(updateManager.isChecking ? "Checking for Updates..." : "Check for Updates")
                }
            }
            .disabled(updateManager.isChecking)

            if updateManager.updateAvailable {
                Divider()

                switch updateManager.updateStatus {
                case .downloading:
                    VStack(spacing: 4) {
                        Text("Downloading update... \(Int((updateManager.downloadProgress ?? 0) * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        ProgressView(value: updateManager.downloadProgress ?? 0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                case .installing, .readyToRelaunch:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing update...")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)

                default:
                    Button {
                        updateManager.showUpdateAlert()
                    } label: {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                }
            }

            Divider()

            Button("Quit \(AppName.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
