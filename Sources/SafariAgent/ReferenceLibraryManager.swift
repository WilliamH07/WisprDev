import AppKit
import Foundation
import PDFKit
import Vision
import os.log

private let libraryLog = OSLog(subsystem: "com.williamh07.wisper", category: "ReferenceLibrary")

/// Extracts the text of a PDF page by page with PDFKit. Pages without a text
/// layer (scans) are read with on-device Vision OCR; nothing leaves the Mac.
enum ReferencePDFExtractor {
    enum ExtractionError: LocalizedError {
        case unreadable
        case locked

        var errorDescription: String? {
            switch self {
            case .unreadable: return "PDF illisible"
            case .locked: return "PDF protégé par un mot de passe"
            }
        }
    }

    static let maxOCRPages = 300

    static func pages(of url: URL) throws -> [ReferencePageText] {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadable
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw ExtractionError.locked
        }
        var pages: [ReferencePageText] = []
        var ocrCount = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, ocrCount < maxOCRPages {
                ocrCount += 1
                text = recognizeText(on: page) ?? text
            }
            pages.append(ReferencePageText(number: index + 1, text: text))
        }
        return pages
    }

    private static func recognizeText(on page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.0, 2400 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Owns the user's PDF libraries: persistence of the file lists, background
/// indexing and the in-memory snapshots the Safari agent queries.
@MainActor
final class ReferenceLibraryManager: ObservableObject {
    enum IndexState: Equatable {
        case idle
        case indexing(done: Int, total: Int)
        case ready(passages: Int, tokens: Int, warnings: [String])

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published private(set) var libraries: [ReferenceLibrary] = []
    @Published private(set) var indexStates: [UUID: IndexState] = [:]

    private let catalogURL: URL
    private var snapshots: [UUID: ReferenceLibrarySnapshot] = [:]
    private var indexTasks: [UUID: Task<ReferenceLibrarySnapshot, Never>] = [:]
    /// Extracted passages per file, keyed by path and invalidated when the
    /// file's size or modification date changes. Memory only.
    private var fileCache: [String: (signature: String, passages: [ReferencePassage])] = [:]

    init(catalogURL: URL) {
        self.catalogURL = catalogURL
        self.libraries = ReferenceLibraryCatalog.load(from: catalogURL)
    }

    // MARK: Editing

    @discardableResult
    func createLibrary(named name: String) -> ReferenceLibrary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let library = ReferenceLibrary(id: UUID(), name: trimmed, files: [])
        libraries.append(library)
        persist()
        return library
    }

    func renameLibrary(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].name = trimmed
        persist()
        invalidate(id)
    }

    func deleteLibrary(_ id: UUID) {
        libraries.removeAll { $0.id == id }
        persist()
        invalidate(id)
        indexStates[id] = nil
    }

    func addFiles(_ urls: [URL], to id: UUID) {
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(libraries[index].files.map(\.path))
        for url in urls where url.pathExtension.lowercased() == "pdf" && !existing.contains(url.path) {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            libraries[index].files.append(ReferenceLibraryFile(id: UUID(), displayName: url.lastPathComponent, path: url.path, bookmark: bookmark))
        }
        persist()
        invalidate(id)
        warm(id)
    }

    func removeFile(_ fileID: UUID, from id: UUID) {
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].files.removeAll { $0.id == fileID }
        persist()
        invalidate(id)
        warm(id)
    }

    // MARK: Indexing

    /// Starts indexing in the background if the library is not ready yet.
    func warm(_ id: UUID) {
        guard snapshots[id] == nil, indexTasks[id] == nil,
              let library = libraries.first(where: { $0.id == id }) else { return }
        indexTasks[id] = startIndexing(library)
    }

    func warmAll() {
        libraries.forEach { warm($0.id) }
    }

    /// Ready snapshot for a library, waiting for indexing when needed.
    func snapshot(for id: UUID) async -> ReferenceLibrarySnapshot? {
        if let snapshot = snapshots[id] {
            return snapshot
        }
        warm(id)
        guard let task = indexTasks[id] else { return nil }
        return await task.value
    }

    func statusPayload() -> [[String: Any]] {
        libraries.map { library in
            var payload: [String: Any] = [
                "id": library.id.uuidString,
                "name": library.name,
                "files": library.files.count
            ]
            switch indexStates[library.id] ?? .idle {
            case .idle:
                payload["state"] = "idle"
            case .indexing(let done, let total):
                payload["state"] = "indexing"
                payload["progress"] = total == 0 ? 0 : Double(done) / Double(total)
            case .ready(let passages, let tokens, _):
                payload["state"] = "ready"
                payload["passages"] = passages
                payload["tokens"] = tokens
            }
            return payload
        }
    }

    private func invalidate(_ id: UUID) {
        indexTasks[id]?.cancel()
        indexTasks[id] = nil
        snapshots[id] = nil
        indexStates[id] = .idle
    }

    private func startIndexing(_ library: ReferenceLibrary) -> Task<ReferenceLibrarySnapshot, Never> {
        let files = library.files
        let cache = fileCache
        indexStates[library.id] = .indexing(done: 0, total: files.count)

        return Task { [weak self] in
            var passages: [ReferencePassage] = []
            var warnings: [String] = []
            var updatedCache: [String: (signature: String, passages: [ReferencePassage])] = [:]

            for (offset, file) in files.enumerated() {
                if Task.isCancelled { break }
                let url = Self.resolve(file)
                let signature = Self.signature(of: url)
                if let signature, let cached = cache[url.path], cached.signature == signature {
                    passages += cached.passages
                } else {
                    let result = await Task.detached(priority: .utility) { () -> Result<[ReferencePassage], Error> in
                        Result {
                            let pages = try ReferencePDFExtractor.pages(of: url)
                            return ReferencePassageChunker.passages(documentName: file.displayName, pages: pages)
                        }
                    }.value
                    switch result {
                    case .success(let extracted):
                        passages += extracted
                        if let signature {
                            updatedCache[url.path] = (signature, extracted)
                        }
                        if extracted.isEmpty {
                            warnings.append("\(file.displayName) : aucun texte trouvé")
                        }
                    case .failure(let error):
                        warnings.append("\(file.displayName) : \(error.localizedDescription)")
                        os_log(.error, log: libraryLog, "Reference PDF could not be indexed")
                    }
                }
                self?.indexStates[library.id] = .indexing(done: offset + 1, total: files.count)
            }

            let collected = passages
            let libraryName = library.name
            let snapshot = await Task.detached(priority: .utility) {
                ReferenceLibrarySnapshot(libraryName: libraryName, passages: collected)
            }.value

            if let self, !Task.isCancelled {
                for (path, entry) in updatedCache {
                    self.fileCache[path] = entry
                }
                self.snapshots[library.id] = snapshot
                self.indexTasks[library.id] = nil
                self.indexStates[library.id] = .ready(passages: snapshot.passages.count, tokens: snapshot.totalTokens, warnings: warnings)
            }
            return snapshot
        }
    }

    private nonisolated static func resolve(_ file: ReferenceLibraryFile) -> URL {
        if let bookmark = file.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return URL(fileURLWithPath: file.path)
    }

    private nonisolated static func signature(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let date = values.contentModificationDate else { return nil }
        return "\(size)-\(date.timeIntervalSince1970)"
    }

    private func persist() {
        do {
            try ReferenceLibraryCatalog.save(libraries, to: catalogURL)
        } catch {
            os_log(.error, log: libraryLog, "Could not save reference libraries: %{public}@", error.localizedDescription)
        }
    }
}
