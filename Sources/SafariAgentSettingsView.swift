import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SafariAgentSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var agent = SafariAgentService.shared
    @ObservedObject private var libraries = SafariAgentService.shared.libraries

    @State private var portInput = ""
    @State private var isCodeRevealed = false
    @State private var copiedCode = false
    @State private var newLibraryName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Agent Safari", icon: "safari") {
                    connectionSection
                }

                SettingsCard("Bibliothèques de PDF", icon: "books.vertical") {
                    librariesSection
                }

                SettingsCard("Contexte envoyé au modèle", icon: "text.magnifyingglass") {
                    budgetSection
                }

                SettingsCard("Installation de l'extension", icon: "puzzlepiece.extension") {
                    setupSection
                }
            }
            .padding(24)
        }
        .onAppear {
            portInput = String(agent.port)
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Activer l'agent dans Safari (double appui sur Ctrl)", isOn: $agent.isEnabled)

            Text("Wisper ouvre un petit serveur local, accessible uniquement depuis ce Mac (127.0.0.1) et protégé par un code d'appairage. La page consultée, votre sélection et les extraits de vos PDF sont envoyés au modèle choisi via OpenRouter, uniquement quand vous posez une question. Rien n'est enregistré sur le disque.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                statusIndicator
                Spacer()
                Text("Port")
                    .font(.caption)
                TextField("47821", text: $portInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(applyPort)
                Button("Appliquer", action: applyPort)
                    .disabled(UInt16(portInput) == agent.port)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Code d'appairage")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text(isCodeRevealed ? agent.pairingCode : String(repeating: "•", count: 32))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(isCodeRevealed ? "Masquer" : "Afficher") {
                        isCodeRevealed.toggle()
                    }
                    Button(copiedCode ? "Copié" : "Copier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(agent.pairingCode, forType: .string)
                        copiedCode = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedCode = false }
                    }
                    Button("Régénérer") {
                        agent.regenerateToken()
                    }
                    .help("Invalide l'ancien code : l'extension devra être appairée à nouveau.")
                }
                Text("Collez ce code une seule fois dans l'extension (icône Wisper Agent de la barre d'outils de Safari).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch agent.serverState {
        case .stopped:
            Label("Arrêté", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .starting:
            Label("Démarrage…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running(let port):
            Label("En écoute sur 127.0.0.1:\(port)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label("Erreur : \(message)", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func applyPort() {
        guard let port = UInt16(portInput), port >= 1024 else {
            portInput = String(agent.port)
            return
        }
        agent.port = port
    }

    // MARK: Libraries

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Une bibliothèque est un dossier de PDF. Dans le panneau de l'agent, choisissez la bibliothèque à utiliser : l'agent y puise les passages utiles pour répondre. Les PDF sont lus sur ce Mac (texte, ou reconnaissance de texte pour les scans) dès leur ajout ; seuls les passages pertinents sont envoyés au modèle.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(libraries.libraries) { library in
                libraryRow(library)
                Divider()
            }

            HStack {
                TextField("Nom de la nouvelle bibliothèque (ex. Cours de droit)", text: $newLibraryName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createLibrary)
                Button("Créer", action: createLibrary)
                    .disabled(newLibraryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func libraryRow(_ library: ReferenceLibrary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(library.name)
                    .font(.headline)
                Text(indexDescription(for: library))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ajouter des PDF…") {
                    choosePDFs(for: library.id)
                }
                Button(role: .destructive) {
                    libraries.deleteLibrary(library.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Supprimer la bibliothèque (les fichiers PDF ne sont pas supprimés)")
            }

            if library.files.isEmpty {
                Text("Aucun PDF pour l'instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(library.files) { file in
                HStack {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.secondary)
                    Text(file.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        libraries.removeFile(file.id, from: library.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Retirer de la bibliothèque")
                }
                .padding(.leading, 22)
            }

            if case .ready(_, _, let warnings) = libraries.indexStates[library.id], !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func indexDescription(for library: ReferenceLibrary) -> String {
        switch libraries.indexStates[library.id] ?? .idle {
        case .idle:
            return "\(library.files.count) PDF"
        case .indexing(let done, let total):
            return "lecture \(done)/\(total)…"
        case .ready(let passages, let tokens, _):
            return "\(library.files.count) PDF · \(passages) passages · ~\(tokens / 1000)k tokens"
        }
    }

    private func createLibrary() {
        if libraries.createLibrary(named: newLibraryName) != nil {
            newLibraryName = ""
        }
    }

    private func choosePDFs(for libraryID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Ajouter"
        guard panel.runModal() == .OK else { return }
        libraries.addFiles(panel.urls, to: libraryID)
    }

    // MARK: Budget

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $agent.pageBudgetTokens, in: SafariAgentService.pageBudgetRange, step: 1000) {
                Text("Page web : jusqu'à ~\(agent.pageBudgetTokens) tokens")
            }
            Stepper(value: $agent.libraryBudgetTokens, in: SafariAgentService.libraryBudgetRange, step: 1000) {
                Text("Extraits de PDF : jusqu'à ~\(agent.libraryBudgetTokens) tokens par question")
            }
            Text("Seul le texte lisible de la page est extrait (sans menus, publicités ni éléments cachés). Si la page dépasse le budget, l'agent garde le plan, la partie visible, votre sélection et les passages les plus proches de la question. Plus le budget est petit, plus la réponse est rapide et économique. Le modèle se choisit dans le panneau ; par défaut : \(AIAssistantModel(rawValue: appState.aiAssistantModel)?.shortName ?? appState.aiAssistantModel).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Compilez Wisper avec l'extension : make SAFARI_AGENT=1 puis lancez l'app une fois.")
            Text("2. Safari → Réglages → Avancés : cochez « Afficher les fonctionnalités pour les développeurs web ».")
            Text("3. Menu Développement → « Autoriser les extensions non signées » (à refaire après chaque redémarrage de Safari).")
            Text("4. Safari → Réglages → Extensions : activez « Wisper Agent » et autorisez-la sur tous les sites web.")
            Text("5. Cliquez sur l'icône Wisper Agent dans la barre d'outils et collez le code d'appairage.")
            Text("6. Sur une page, appuyez deux fois sur Ctrl pour ouvrir ou fermer l'agent.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
