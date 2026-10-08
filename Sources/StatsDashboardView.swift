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
