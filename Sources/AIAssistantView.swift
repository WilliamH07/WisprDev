import AppKit
import SwiftUI

struct AIAssistantView: View {
    @ObservedObject var appState: AppState
    @State private var promptText: String = ""
    @State private var attachedImage: NSImage?
    @State private var isCapturingScreenshot = false
    @State private var isLoading = false
    @State private var responseText: String = ""
    @State private var lastSubmittedPrompt: String = ""
    @State private var errorMessage: String?
    @State private var selectedModel: String = AIAssistantModel.gpt4oMini.rawValue
    @State private var isRecordingVoice = false
    @State private var copiedConfirmation = false
    @State private var eventMonitor: Any?
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool
    @State private var retrievedMemories: [SemanticSearchResult] = []
    @State private var isMemoryContextExpanded = false
    @State private var isShowingMemoryDrawer = false
    @State private var memoryDrawerSearchText = ""
    @State private var drawerMemories: [SemanticMemoryItem] = []

    var onClose: () -> Void
    var onInsertAtCursor: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)

            Divider()

            // Main Content Area
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Attached Image Preview
                        if let image = attachedImage {
                            imageAttachmentPreview(image)
                        }

                        // User Submitted Prompt Bubble
                        if !lastSubmittedPrompt.isEmpty {
                            userPromptBubble(lastSubmittedPrompt)
                        }

                        // Retrieved Semantic Memories badge (if any)
                        if !retrievedMemories.isEmpty {
                            retrievedMemoriesBanner
                        }

                        // Response Section (if any)
                        if isLoading && responseText.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Réflexion avec \(currentModelDisplayName)...")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        } else if !responseText.isEmpty {
                            responseSection
                        } else if let error = errorMessage {
                            errorBanner(error)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                    }
                    .padding(16)
                }
                .frame(maxHeight: (responseText.isEmpty && lastSubmittedPrompt.isEmpty) ? 160 : 380)
                .onChange(of: responseText) { _ in
                    withAnimation(WisperMotion.contentChange) {
                        scrollProxy.scrollTo("bottomAnchor", anchor: .bottom)
                    }
                }
            }

            Divider()
                .opacity(0.2)

            if isShowingMemoryDrawer {
                memoryDrawerView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider()
                    .opacity(0.2)
            }

            // Input Bar & Action Controls
            inputToolbar
                .padding(12)
                .background(Color.white.opacity(0.03))
        }
        .frame(width: 580)
        .background(
            LiquidGlassWindowBackground(cornerRadius: 18, isThinking: isLoading)
        )
        .onAppear {
            selectedModel = appState.aiAssistantModel
            isInputFocused = true

            // Intercept Shift + Enter (and Cmd + Enter) to send the message
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                    if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
                        DispatchQueue.main.async {
                            if self.canSubmit {
                                self.submitQuery()
                            }
                        }
                        return nil // Swallow event so TextEditor doesn't insert newline
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            streamTask?.cancel()
        }
        .onChange(of: selectedModel) { newModel in
            appState.aiAssistantModel = newModel
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(WisperPalette.memoryGradient)

            Text("Wisper IA")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            // Model Selector Menu
            Menu {
                Picker("Modèle IA", selection: $selectedModel) {
                    ForEach(AIAssistantModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                    Text(AIAssistantModel(rawValue: selectedModel)?.shortName ?? selectedModel)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .menuStyle(.borderlessButton)

            // Clear Conversation
            if !responseText.isEmpty || attachedImage != nil || !promptText.isEmpty {
                Button {
                    clearAll()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Nouvelle conversation")
            }

            // Close Button
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Image Preview

    private func imageAttachmentPreview(_ image: NSImage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Capture d'écran attachée")
                    .font(.caption.weight(.semibold))
                Text("Prête à être analysée par l'IA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    attachedImage = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Supprimer")
                    }
                    .font(.caption2)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - User Prompt Bubble

    private func userPromptBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(WisperPalette.actionGradient)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                        )
                )
        }
    }

    // MARK: - Response Section

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Réponse de l'IA")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // Copy button
                Button {
                    copyResponse()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedConfirmation ? "checkmark" : "doc.on.doc")
                        Text(copiedConfirmation ? "Copié !" : "Copier")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(copiedConfirmation ? WisperPalette.success : .secondary)
                }
                .buttonStyle(.plain)

                // Insert into current app button
                Button {
                    onInsertAtCursor(responseText)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc")
                        Text("Insérer au curseur")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            Text(responseText)
                .font(.system(size: 13, weight: .regular))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.14).opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WisperPalette.error)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(WisperPalette.error)

                if message.contains("Clé API OpenRouter") {
                    Button("Ouvrir les Réglages…") {
                        NotificationCenter.default.post(name: .showSettings, object: nil)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WisperPalette.error.opacity(0.08))
        )
    }

    // MARK: - Input Toolbar

    private var inputToolbar: some View {
        VStack(spacing: 8) {
            // Text Editor Input
            ZStack(alignment: .topLeading) {
                if promptText.isEmpty && !isRecordingVoice {
                    Text("Posez une question ou demandez une analyse… (Shift + Entrée pour envoyer)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $promptText)
                    .font(.system(size: 13))
                    .frame(minHeight: 44, maxHeight: 110)
                    .focused($isInputFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.06, green: 0.07, blue: 0.11).opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.25), location: 0.0),
                                .init(color: Color.white.opacity(0.06), location: 0.5),
                                .init(color: Color.white.opacity(0.18), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )

            // Toolbar Controls
            HStack(spacing: 8) {
                // Screenshot Area Selection Button (Cmd+Shift+4)
                Button {
                    triggerScreenCapture()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "crop")
                        Text(attachedImage != nil ? "Changer l'image" : "Capturer une zone")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .help("Sélectionner une zone d'écran comme avec Cmd+Shift+4")

                // Voice Dictation Button
                Button {
                    toggleVoiceInput()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isRecordingVoice ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(isRecordingVoice ? .red : Color(red: 0.45, green: 0.8, blue: 1.0))
                        Text(isRecordingVoice ? "Arrêter" : "Parler")
                            .foregroundStyle(.white)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isRecordingVoice ? WisperPalette.recording.opacity(0.25) : Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(isRecordingVoice ? WisperPalette.recording.opacity(0.5) : Color.white.opacity(0.16), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .help(isRecordingVoice ? "Arrêter l'enregistrement" : "Dicter la question à la voix")

                // Semantic Memory Browser Button
                Button {
                    withAnimation(WisperMotion.momentum) {
                        isShowingMemoryDrawer.toggle()
                        if isShowingMemoryDrawer {
                            refreshDrawerMemories()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(isShowingMemoryDrawer ? Color(red: 0.4, green: 0.85, blue: 1.0) : Color.white.opacity(0.85))
                        Text("Mémoire")
                            .foregroundStyle(.white)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isShowingMemoryDrawer ? Color(red: 0.3, green: 0.6, blue: 1.0).opacity(0.35) : Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(isShowingMemoryDrawer ? Color(red: 0.5, green: 0.8, blue: 1.0).opacity(0.6) : Color.white.opacity(0.16), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
                .help("Parcourir et insérer des souvenirs mémorisés (presse-papier, dictées, réécritures)")

                Spacer()

                // Send Button
                Button {
                    submitQuery()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Envoyer")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(
                                canSubmit
                                    ? AnyShapeStyle(WisperPalette.actionGradient)
                                    : AnyShapeStyle(Color.gray.opacity(0.3))
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(canSubmit ? 0.4 : 0.1), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isLoading)
                .keyboardShortcut(.return, modifiers: [.shift])
            }
        }
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        (!promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil) && !isLoading
    }

    private var currentModelDisplayName: String {
        AIAssistantModel(rawValue: selectedModel)?.displayName ?? selectedModel
    }

    private func triggerScreenCapture() {
        AIAssistantWindowManager.shared.hideTemporarilyForCapture {
            Task {
                if let image = await AIAssistantService.captureInteractiveScreenArea() {
                    await MainActor.run {
                        self.attachedImage = image
                    }
                }
                await MainActor.run {
                    AIAssistantWindowManager.shared.restoreAfterCapture()
                    self.isInputFocused = true
                }
            }
        }
    }

    private func toggleVoiceInput() {
        if isRecordingVoice {
            // Stop recording and transcribe
            isRecordingVoice = false
            Task { @MainActor in
                let transcribed = await appState.recordAndTranscribeSingleUtterance()
                if let text = transcribed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !promptText.isEmpty {
                        promptText += " " + text
                    } else {
                        promptText = text
                    }
                }
                isInputFocused = true
            }
        } else {
            // Start voice capture
            isRecordingVoice = true
            appState.beginVoiceCaptureForAIAssistant()
        }
    }

    private func submitQuery() {
        let query = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || attachedImage != nil else { return }

        let effectivePrompt = query.isEmpty ? "Décris et analyse cette image." : query
        lastSubmittedPrompt = effectivePrompt
        promptText = ""

        if SemanticMemoryService.shared.isEnabled {
            retrievedMemories = SemanticMemoryService.shared.search(query: effectivePrompt, limit: 3)
        } else {
            retrievedMemories = []
        }
        isShowingMemoryDrawer = false

        isLoading = true
        errorMessage = nil
        responseText = ""

        let image = attachedImage
        let model = selectedModel
        let key = appState.openRouterAPIKey

        streamTask?.cancel()
        streamTask = Task {
            do {
                let stream = AIAssistantService.shared.streamQuery(
                    prompt: effectivePrompt,
                    image: image,
                    model: model,
                    apiKey: key,
                    memories: retrievedMemories
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if self.isLoading {
                            self.isLoading = false
                        }
                        self.responseText += chunk
                    }
                }
                await MainActor.run {
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func copyResponse() {
        guard !responseText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(responseText, forType: .string)

        copiedConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedConfirmation = false
        }
    }

    private func clearAll() {
        streamTask?.cancel()
        promptText = ""
        lastSubmittedPrompt = ""
        attachedImage = nil
        responseText = ""
        errorMessage = nil
        isLoading = false
        isInputFocused = true
        retrievedMemories = []
        isMemoryContextExpanded = false
        isShowingMemoryDrawer = false
    }

    // MARK: - Semantic Memory Views

    private var retrievedMemoriesBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(WisperMotion.contentChange) {
                    isMemoryContextExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 1.0))

                    Text("\(retrievedMemories.count) souvenir\(retrievedMemories.count > 1 ? "s" : "") rattaché\(retrievedMemories.count > 1 ? "s" : "") depuis votre mémoire")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.5, green: 0.85, blue: 1.0))

                    Image(systemName: isMemoryContextExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(WisperPalette.actionGradient)
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                )
            }
            .buttonStyle(.plain)

            if isMemoryContextExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(retrievedMemories, id: \.item.id) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.item.category == .clipboard ? "doc.on.doc" : (result.item.category == .dictation ? "mic" : "sparkles"))
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 1.0))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(result.item.sourceAppName.isEmpty ? "Source locale" : result.item.sourceAppName)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Text(result.matchReason)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 1.0))
                                }

                                Text(result.item.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(3)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private var memoryDrawerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(WisperPalette.memoryGradient)
                    Text("Mémoire Sémantique (« Deuxième Cerveau »)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Button {
                    withAnimation(WisperMotion.contentChange) {
                        isShowingMemoryDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }

            // Quick search in memories
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filtrer vos souvenirs (colis, mot de passe wifi, notes...)", text: $memoryDrawerSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onChange(of: memoryDrawerSearchText) { _ in
                        refreshDrawerMemories()
                    }

                if !memoryDrawerSearchText.isEmpty {
                    Button {
                        memoryDrawerSearchText = ""
                        refreshDrawerMemories()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))

            // Memories list
            ScrollView {
                VStack(spacing: 6) {
                    if drawerMemories.isEmpty {
                        Text(memoryDrawerSearchText.isEmpty ? "Aucun souvenir mémorisé pour l'instant" : "Aucun résultat trouvé pour « \(memoryDrawerSearchText) »")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(drawerMemories) { mem in
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: mem.category == .clipboard ? "doc.on.doc" : (mem.category == .dictation ? "mic" : "sparkles"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 1.0))
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(mem.sourceAppName.isEmpty ? "Note" : mem.sourceAppName)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.85))
                                        Spacer()
                                        Text(mem.category.rawValue)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(mem.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(2)
                                }

                                Spacer()

                                Button {
                                    if promptText.isEmpty {
                                        promptText = "À propos de ce souvenir : \"\(mem.text)\", "
                                    } else {
                                        promptText += " (Référence : \"\(mem.text)\")"
                                    }
                                    withAnimation(WisperMotion.contentChange) {
                                        isShowingMemoryDrawer = false
                                    }
                                    isInputFocused = true
                                } label: {
                                    Text("Insérer")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                                .help("Insérer dans le champ de question")
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                        }
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        .padding(12)
        .background(Color.black.opacity(0.35))
        .onAppear {
            refreshDrawerMemories()
        }
    }

    private func refreshDrawerMemories() {
        let trimmed = memoryDrawerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            drawerMemories = SemanticMemoryStore.shared.fetchRecent(limit: 8)
        } else {
            drawerMemories = SemanticMemoryService.shared.search(query: trimmed, limit: 8).map(\.item)
        }
    }
}

// Background blur effect for floating panel
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
