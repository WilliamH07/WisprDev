import SwiftUI
import AppKit

/// "Mémoire": browse and semantically search everything the memory has kept
/// (dictations, clipboard, terminal commands, notes). Search runs on-device with
/// the same embedding index used by the "Wisper, retrouve…" voice command.
struct MemoryBrowserView: View {
    @State private var query = ""
    @State private var items: [SemanticMemoryItem] = []
    @State private var searchScores: [UUID: Double] = [:]
    @State private var category: SemanticMemoryCategory?
    @State private var totalCount = 0
    @State private var isSearching = false
    @State private var copiedID: UUID?
    @State private var showClearConfirmation = false
    @State private var newNote = ""
    @State private var searchTask: Task<Void, Never>?

    private var service: SemanticMemoryService { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                searchField
                filters
                if !service.isEnabled {
                    CraieCard {
                        Text("La mémoire est désactivée : aucune nouvelle dictée ni copie n'est enregistrée. Activez-la dans les réglages pour la reprendre.")
                            .font(Craie.texte)
                            .foregroundStyle(Craie.textSecondary)
                    }
                }
                noteComposer
                resultsList
                footer
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Craie.fond)
        .onAppear(perform: reload)
        .confirmationDialog("Effacer toute la mémoire ?", isPresented: $showClearConfirmation) {
            Button("Tout effacer", role: .destructive) {
                SemanticMemoryStore.shared.clearAll()
                reload()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est définitive.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            CraieSectionLabel("Mémoire")
            Text("\(totalCount.formatted()) souvenirs")
                .font(Craie.mono(34, weight: .medium))
            Text("Tout ce que vous avez dicté, copié ou noté, retrouvable par le sens et pas seulement par les mots.")
                .font(Craie.texte)
                .foregroundStyle(Craie.textSecondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Craie.textTertiary)
            TextField("Rechercher par le sens (ex. « code wifi », « adresse du client »)", text: $query)
                .textFieldStyle(.plain)
                .font(Craie.texte)
                .onChange(of: query) { _ in scheduleSearch() }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Craie.textTertiary)
                    .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Craie.panneau)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Craie.border, lineWidth: 1))
    }

    private var filters: some View {
        CraieSegmented(
            options: [("Tout", Optional<SemanticMemoryCategory>.none)]
                + SemanticMemoryCategory.allCases.map { ($0.displayName, Optional($0)) },
            selection: $category
        )
    }

    private var noteComposer: some View {
        HStack(spacing: 10) {
            TextField("Ajouter une note à la mémoire", text: $newNote)
                .textFieldStyle(.plain)
                .font(Craie.texte)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Craie.panneau)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Craie.border, lineWidth: 1))
                .onSubmit(addNote)
            Button("Ajouter", action: addNote)
                .buttonStyle(CraiePillButtonStyle(kind: .action))
                .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var visibleItems: [SemanticMemoryItem] {
        category.map { selected in items.filter { $0.category == selected } } ?? items
    }

    @ViewBuilder
    private var resultsList: some View {
        if visibleItems.isEmpty {
            CraieCard {
                Text(query.isEmpty ? "Rien en mémoire pour le moment." : "Aucun souvenir ne correspond à cette recherche.")
                    .font(Craie.texte)
                    .foregroundStyle(Craie.textSecondary)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(visibleItems) { item in
                    MemoryRow(
                        item: item,
                        score: searchScores[item.id],
                        isCopied: copiedID == item.id,
                        onCopy: { copy(item) }
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Stocké uniquement sur ce Mac. La recherche est calculée localement.")
                .font(.system(size: 12))
                .foregroundStyle(Craie.textTertiary)
            Spacer()
            Button("Tout effacer") { showClearConfirmation = true }
                .buttonStyle(CraiePillButtonStyle(kind: .secondary))
        }
    }

    // MARK: Actions

    private func reload() {
        let currentQuery = query
        Task.detached(priority: .userInitiated) {
            let recent = SemanticMemoryStore.shared.fetchRecent(limit: 100)
            let count = SemanticMemoryStore.shared.count()
            await MainActor.run {
                totalCount = count
                if currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items = recent
                    searchScores = [:]
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            reload()
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce so the on-device index is not rebuilt on every keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                SemanticMemoryService.shared.search(query: trimmed, limit: 30)
            }.value
            guard !Task.isCancelled else { return }
            items = results.map(\.item)
            searchScores = Dictionary(uniqueKeysWithValues: results.map { ($0.item.id, $0.score) })
            isSearching = false
        }
    }

    private func addNote() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if service.addManualNote(text) {
            newNote = ""
            reload()
        }
    }

    private func copy(_ item: SemanticMemoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedID == item.id { copiedID = nil }
        }
    }
}

private struct MemoryRow: View {
    let item: SemanticMemoryItem
    let score: Double?
    let isCopied: Bool
    let onCopy: () -> Void
    @State private var expanded = false

    var body: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: item.category.iconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Craie.textSecondary)
                    Text(item.category.displayName)
                        .font(Craie.libelle)
                        .foregroundStyle(Craie.textSecondary)
                    if !item.sourceAppName.isEmpty {
                        Text("· \(item.sourceAppName)")
                            .font(Craie.libelle)
                            .foregroundStyle(Craie.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let score {
                        Text("\(Int((min(max(score, 0), 1) * 100).rounded())) %")
                            .font(Craie.mono(11))
                            .foregroundStyle(Craie.signalText)
                    }
                    Text(item.timestamp.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(Craie.mono(11))
                        .foregroundStyle(Craie.textTertiary)
                }

                Text(expanded ? item.text : item.snippet)
                    .font(Craie.texte)
                    .foregroundStyle(Craie.textPrimary)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button(isCopied ? "Copié" : "Copier", action: onCopy)
                        .buttonStyle(CraiePillButtonStyle(kind: .action))
                    if item.text.count > item.snippet.count {
                        Button(expanded ? "Réduire" : "Tout afficher") { expanded.toggle() }
                            .buttonStyle(CraiePillButtonStyle(kind: .secondary))
                    }
                }
            }
        }
    }
}
