import SwiftUI
import Charts

/// "Accueil": lifetime usage at a glance. Every figure comes from content-free
/// counters stored locally by `UsageStatsStore`.
struct StatsDashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var rangeDays = 30
    @State private var snapshot = UsageStatsStore.shared.snapshot(recentDayCount: 30)
    @State private var hoveredDay: DictationStatsSnapshot.DayPoint?
    @State private var showResetConfirmation = false
    @StateObject private var benchmark = TranscriptionBenchmarkRunner()
    @StateObject private var cleanupBenchmark = CleanupBenchmarkRunner()

    private let tileColumns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if snapshot.totalDictations == 0 {
                    CraieCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pas encore de données").font(Craie.titrePublication)
                            Text("Maintenez votre raccourci de dictée et parlez : vos mots, votre vitesse et vos séries apparaîtront ici.")
                                .font(Craie.texte)
                                .foregroundStyle(Craie.textSecondary)
                        }
                    }
                } else {
                    LazyVGrid(columns: tileColumns, spacing: 12) {
                        CraieStat(label: "Dictées", value: format(snapshot.totalDictations))
                        CraieStat(label: "Vitesse", value: "\(snapshot.averageWordsPerMinute) mots/min")
                        CraieStat(label: "Temps gagné", value: formatMinutes(snapshot.minutesSaved()))
                        CraieStat(label: "Série en cours", value: "\(snapshot.currentStreakDays) j",
                                  signal: snapshot.currentStreakDays > 0)
                    }

                    activityCard
                    topAppsCard
                }

                latencyCard
                engineBenchmarkCard
                cleanupBenchmarkCard
                privacyFooter
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Craie.fond)
        .onAppear(perform: refresh)
        .onChange(of: rangeDays) { _ in refresh() }
        .onReceive(appState.$statusText) { _ in refresh() }
        .confirmationDialog("Réinitialiser toutes les statistiques ?", isPresented: $showResetConfirmation) {
            Button("Réinitialiser", role: .destructive) {
                UsageStatsStore.shared.reset()
                refresh()
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CraieSignalDot(live: appState.isRecording)
                    .opacity(appState.isRecording || appState.isTranscribing ? 1 : 0)
                Text(appState.isRecording ? "Écoute en cours" : (appState.isTranscribing ? "Transcription…" : "Accueil"))
                    .font(Craie.libelle)
                    .foregroundStyle(appState.isRecording ? Craie.signalText : Craie.textTertiary)
            }
            Text(format(snapshot.totalWords))
                .font(Craie.mono(52, weight: .medium))
                .foregroundStyle(Craie.textPrimary)
            Text(snapshot.totalWords > 0
                 ? "mots dictés, soit environ \(formatMinutes(snapshot.minutesSaved())) gagnées par rapport à la frappe."
                 : "mots dictés pour l'instant.")
                .font(Craie.texte)
                .foregroundStyle(Craie.textSecondary)
        }
    }

    private var activityCard: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        CraieSectionLabel("Mots par jour")
                        if let hoveredDay {
                            Text("\(hoveredDay.date.formatted(.dateTime.day().month(.wide))) · \(hoveredDay.words) mots")
                                .font(Craie.mono(15, weight: .medium))
                        } else {
                            Text("\(format(periodWords)) mots sur \(rangeDays) jours")
                                .font(Craie.mono(15, weight: .medium))
                        }
                    }
                    Spacer()
                    CraieSegmented(
                        options: [("14 j", 14), ("30 j", 30), ("90 j", 90)],
                        selection: $rangeDays
                    )
                }

                activityChart
                    .frame(height: 170)

                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11))
                    Text("Source : compteurs locaux de ce Mac")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Craie.textTertiary)
            }
        }
    }

    private var activityChart: some View {
        Chart {
            ForEach(snapshot.recentDays, id: \.date) { point in
                AreaMark(
                    x: .value("Jour", point.date, unit: .day),
                    y: .value("Mots", point.words)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Craie.action.opacity(0.16), Craie.action.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Jour", point.date, unit: .day),
                    y: .value("Mots", point.words)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(Craie.action)
            }
            if let hoveredDay {
                RuleMark(x: .value("Jour", hoveredDay.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Craie.textTertiary.opacity(0.6))
                PointMark(
                    x: .value("Jour", hoveredDay.date, unit: .day),
                    y: .value("Mots", hoveredDay.words)
                )
                .symbolSize(48)
                .foregroundStyle(Craie.signal)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Craie.border)
                AxisValueLabel().font(Craie.mono(10)).foregroundStyle(Craie.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: rangeDays > 30 ? 14 : 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(Craie.mono(10))
                    .foregroundStyle(Craie.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let originX = geometry[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: location.x - originX) {
                                hoveredDay = nearestDay(to: date)
                            }
                        case .ended:
                            hoveredDay = nil
                        }
                    }
            }
        }
    }

    private var topAppsCard: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 12) {
                CraieSectionLabel("Applications les plus utilisées")
                if snapshot.topApps.isEmpty {
                    Text("Aucune application enregistrée pour l'instant.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                } else {
                    let maxCount = max(snapshot.topApps.map(\.dictations).max() ?? 1, 1)
                    ForEach(snapshot.topApps, id: \.name) { app in
                        HStack(spacing: 12) {
                            Text(app.name)
                                .font(Craie.texte)
                                .frame(width: 140, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Craie.action)
                                    .frame(width: max(6, proxy.size.width * CGFloat(app.dictations) / CGFloat(maxCount)))
                            }
                            .frame(height: 6)
                            Text("\(app.dictations)")
                                .font(Craie.mono(12))
                                .foregroundStyle(Craie.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var latencyCard: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 10) {
                CraieSectionLabel("Dernière dictée — du relâchement au texte prêt")
                if let timings = appState.lastDictationTimings {
                    Text(DictationTimings.format(timings.total))
                        .font(Craie.mono(24, weight: .medium))
                    if !timings.engine.isEmpty {
                        Text(timings.engine)
                            .font(Craie.mono(11))
                            .foregroundStyle(Craie.textTertiary)
                    }
                    VStack(spacing: 6) {
                        timingRow("Finalisation audio", timings.audioFinalize)
                        timingRow("Transcription", timings.transcription)
                        timingRow("Contexte écran", timings.contextWait)
                        if timings.skippedPostProcessing {
                            HStack {
                                Text("Nettoyage IA").font(Craie.texte).foregroundStyle(Craie.textSecondary)
                                Spacer()
                                Text("ignoré (phrase courte)").font(Craie.mono(12)).foregroundStyle(Craie.textTertiary)
                            }
                        } else if timings.cleanupFellBackToRaw {
                            HStack {
                                Text("Nettoyage IA").font(Craie.texte).foregroundStyle(Craie.textSecondary)
                                Spacer()
                                Text("trop lent : texte brut (\(DictationTimings.format(timings.postProcessing)))")
                                    .font(Craie.mono(12))
                                    .foregroundStyle(Craie.signalText)
                            }
                        } else {
                            timingRow("Nettoyage IA", timings.postProcessing)
                        }
                    }
                } else {
                    Text("Faites une dictée pour voir où part le temps.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                }
            }
        }
    }

    private func timingRow(_ label: String, _ seconds: TimeInterval) -> some View {
        HStack {
            Text(label).font(Craie.texte).foregroundStyle(Craie.textSecondary)
            Spacer()
            Text(DictationTimings.format(seconds)).font(Craie.mono(12))
        }
    }

    // MARK: Engine benchmark

    private var benchmarkCandidates: [BenchmarkCandidate] {
        var candidates: [BenchmarkCandidate] = []
        let groqKey = appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let groqBase = appState.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !groqKey.isEmpty, !groqBase.isEmpty {
            let host = URL(string: groqBase)?.host ?? "fournisseur"
            for model in ["whisper-large-v3-turbo", "whisper-large-v3"] {
                candidates.append(BenchmarkCandidate(label: "\(host) · \(model)", model: model, baseURL: groqBase, apiKey: groqKey))
            }
        }
        let routerKey = appState.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !routerKey.isEmpty {
            candidates.append(BenchmarkCandidate(
                label: "openrouter.ai · \(TranscriptionRouting.fishAudioModel)",
                model: TranscriptionRouting.fishAudioModel,
                baseURL: TranscriptionRouting.openRouterBaseURL,
                apiKey: routerKey
            ))
        }
        return candidates
    }

    private var fastestResultID: String? {
        benchmark.results
            .filter { $0.errorMessage == nil && $0.warmSeconds != nil }
            .min { ($0.warmSeconds ?? .infinity) < ($1.warmSeconds ?? .infinity) }?.id
    }

    private var engineBenchmarkCard: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CraieSectionLabel("Vitesse des moteurs de transcription")
                    Spacer()
                    Button(benchmark.isRunning ? "Mesure en cours…" : "Tester") {
                        Task { await benchmark.run(candidates: benchmarkCandidates) }
                    }
                    .buttonStyle(CraiePillButtonStyle(kind: .action))
                    .disabled(benchmark.isRunning || benchmarkCandidates.isEmpty)
                }

                if benchmarkCandidates.isEmpty {
                    Text("Ajoutez une clé API (Groq ou OpenRouter) dans les réglages pour comparer les moteurs.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                } else if benchmark.results.isEmpty {
                    Text("Envoie un court clip synthétique (aucune de vos paroles) à chaque moteur configuré et mesure le temps de réponse. Cela consomme quelques secondes d'audio facturées.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(benchmark.results) { result in
                            benchmarkRow(result)
                        }
                    }
                }
            }
        }
    }

    private func benchmarkRow(_ result: BenchmarkResult) -> some View {
        let isFastest = result.id == fastestResultID
        let isCurrent = appState.transcriptionModel == result.candidate.model
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.candidate.label)
                    .font(Craie.texte)
                    .lineLimit(1)
                if let error = result.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Craie.signalText)
                        .lineLimit(2)
                } else if let cold = result.coldSeconds {
                    Text("1re requête \(DictationTimings.format(cold))")
                        .font(Craie.mono(11))
                        .foregroundStyle(Craie.textTertiary)
                }
            }
            Spacer()
            if let warm = result.warmSeconds, result.errorMessage == nil {
                Text(DictationTimings.format(warm))
                    .font(Craie.mono(15, weight: .medium))
                    .foregroundStyle(isFastest ? Craie.signalText : Craie.textPrimary)
                if isCurrent {
                    Text("actif").font(Craie.libelle).foregroundStyle(Craie.textTertiary)
                } else {
                    Button("Utiliser") { appState.transcriptionModel = result.candidate.model }
                        .buttonStyle(CraiePillButtonStyle(kind: isFastest ? .action : .secondary))
                }
            } else if benchmark.isRunning && result.errorMessage == nil && result.warmSeconds == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Cleanup benchmark

    private var cleanupCandidates: [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        let routerKey = appState.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !routerKey.isEmpty {
            for model in ["openai/gpt-oss-20b", "google/gemini-2.5-flash", "google/gemini-2.5-flash-lite"] {
                candidates.append(CleanupCandidate(
                    label: "OpenRouter · \(model)", model: model,
                    baseURL: TranscriptionRouting.openRouterBaseURL, apiKey: routerKey, provider: .openRouter
                ))
            }
        }
        let groqKey = appState.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let groqBase = appState.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !groqKey.isEmpty, !groqBase.isEmpty {
            candidates.append(CleanupCandidate(
                label: "\(URL(string: groqBase)?.host ?? "Groq") · openai/gpt-oss-20b", model: "openai/gpt-oss-20b",
                baseURL: groqBase, apiKey: groqKey, provider: .groqCloud
            ))
        }
        return candidates
    }

    private var mostRegularCleanupID: String? {
        cleanupBenchmark.results
            .filter { $0.errorMessage == nil && $0.median != nil && !$0.isErratic }
            .min { ($0.median ?? .infinity) < ($1.median ?? .infinity) }?.id
    }

    private var cleanupBenchmarkCard: some View {
        CraieCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CraieSectionLabel("Vitesse et régularité de la réécriture IA")
                    Spacer()
                    Button(cleanupBenchmark.isRunning ? "Mesure en cours…" : "Tester") {
                        Task { await cleanupBenchmark.run(candidates: cleanupCandidates) }
                    }
                    .buttonStyle(CraiePillButtonStyle(kind: .action))
                    .disabled(cleanupBenchmark.isRunning || cleanupCandidates.isEmpty)
                }
                if cleanupCandidates.isEmpty {
                    Text("Ajoutez une clé OpenRouter ou Groq dans les réglages pour comparer les modèles de réécriture.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                } else if cleanupBenchmark.results.isEmpty {
                    Text("Envoie 6 fois une phrase de test inventée à chaque modèle et affiche la médiane et le pire cas : un bon modèle est rapide ET régulier.")
                        .font(Craie.texte)
                        .foregroundStyle(Craie.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(cleanupBenchmark.results) { cleanupRow($0) }
                    }
                }
            }
        }
    }

    private func isActiveCleanup(_ candidate: CleanupCandidate) -> Bool {
        switch candidate.provider {
        case .openRouter:
            return appState.rewriteProvider == .openRouter && appState.openRouterModel == candidate.model
        case .groqCloud:
            return appState.rewriteProvider == .groqCloud && appState.postProcessingModel == candidate.model
        }
    }

    private func cleanupRow(_ result: CleanupBenchmarkResult) -> some View {
        let best = result.id == mostRegularCleanupID
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.candidate.label).font(Craie.texte).lineLimit(1)
                if let error = result.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(Craie.signalText).lineLimit(2)
                } else if let worst = result.worst {
                    Text("pire cas \(DictationTimings.format(worst))" + (result.isErratic ? " · irrégulier" : ""))
                        .font(Craie.mono(11))
                        .foregroundStyle(result.isErratic ? Craie.signalText : Craie.textTertiary)
                }
            }
            Spacer()
            if let median = result.median, result.errorMessage == nil {
                Text(DictationTimings.format(median))
                    .font(Craie.mono(15, weight: .medium))
                    .foregroundStyle(best ? Craie.signalText : Craie.textPrimary)
                if isActiveCleanup(result.candidate) {
                    Text("actif").font(Craie.libelle).foregroundStyle(Craie.textTertiary)
                } else {
                    Button("Utiliser") { useCleanup(result.candidate) }
                        .buttonStyle(CraiePillButtonStyle(kind: best ? .action : .secondary))
                }
            } else if cleanupBenchmark.isRunning && result.errorMessage == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func useCleanup(_ candidate: CleanupCandidate) {
        switch candidate.provider {
        case .openRouter:
            appState.rewriteProvider = .openRouter
            appState.openRouterModel = candidate.model
        case .groqCloud:
            appState.rewriteProvider = .groqCloud
            appState.postProcessingModel = candidate.model
        }
    }

    private var privacyFooter: some View {
        HStack(spacing: 12) {
            Text("Compteurs stockés sur ce Mac. Aucun texte dicté n'y est conservé et rien n'est envoyé.")
                .font(.system(size: 12))
                .foregroundStyle(Craie.textTertiary)
            Spacer()
            Button("Réinitialiser") { showResetConfirmation = true }
                .buttonStyle(CraiePillButtonStyle(kind: .secondary))
        }
    }

    // MARK: Helpers

    private var periodWords: Int { snapshot.recentDays.reduce(0) { $0 + $1.words } }

    private func nearestDay(to date: Date) -> DictationStatsSnapshot.DayPoint? {
        snapshot.recentDays.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func refresh() {
        snapshot = UsageStatsStore.shared.snapshot(recentDayCount: rangeDays)
    }

    private func format(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
