import SwiftUI

/// Lifetime usage dashboard (words, speed, streaks, top apps). All figures come
/// from content-free counters stored locally by `UsageStatsStore`.
struct StatsDashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var snapshot = UsageStatsStore.shared.snapshot()
    @State private var showResetConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if snapshot.totalDictations == 0 {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        StatTile(title: "Mots dictés", value: format(snapshot.totalWords), icon: "text.word.spacing")
                        StatTile(title: "Dictées", value: format(snapshot.totalDictations), icon: "mic.fill")
                        StatTile(title: "Vitesse moyenne", value: "\(snapshot.averageWordsPerMinute) mots/min", icon: "speedometer")
                        StatTile(title: "Temps gagné", value: formatMinutes(snapshot.minutesSaved()), icon: "clock.badge.checkmark")
                        StatTile(title: "Série en cours", value: "\(snapshot.currentStreakDays) j", icon: "flame.fill")
                        StatTile(title: "Meilleure série", value: "\(snapshot.bestStreakDays) j", icon: "trophy.fill")
                    }

                    SettingsCard("14 derniers jours", icon: "chart.bar.fill") {
                        activityChart
                    }

                    SettingsCard("Applications les plus utilisées", icon: "app.badge") {
                        topApps
                    }
                }

                SettingsCard("Confidentialité", icon: "lock.shield") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ces statistiques sont de simples compteurs stockés sur ce Mac. Aucun texte dicté n'y est conservé et rien n'est envoyé.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Réinitialiser les statistiques", role: .destructive) {
                            showResetConfirmation = true
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { refresh() }
        .onReceive(appState.$statusText) { _ in refresh() }
        .confirmationDialog("Réinitialiser toutes les statistiques ?", isPresented: $showResetConfirmation) {
            Button("Réinitialiser", role: .destructive) {
                UsageStatsStore.shared.reset()
                refresh()
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Votre voix en chiffres")
                .font(.title2.weight(.semibold))
            Text(snapshot.totalWords > 0
                 ? "Vous avez dicté \(format(snapshot.totalWords)) mots, soit environ \(formatMinutes(snapshot.minutesSaved())) gagnées par rapport à la frappe."
                 : "Vos statistiques apparaîtront ici dès votre première dictée.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        SettingsCard("Pas encore de données", icon: "waveform") {
            Text("Maintenez votre raccourci de dictée et parlez : mots, vitesse et séries s'afficheront ici.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var activityChart: some View {
        let maxWords = max(snapshot.recentDays.map(\.words).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(snapshot.recentDays, id: \.date) { point in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(point.words > 0 ? Color.accentColor : Color.primary.opacity(0.1))
                        .frame(height: max(4, CGFloat(point.words) / CGFloat(maxWords) * 90))
                        .help("\(point.words) mots")
                    Text(point.date, format: .dateTime.day())
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 115, alignment: .bottom)
    }

    @ViewBuilder
    private var topApps: some View {
        if snapshot.topApps.isEmpty {
            Text("Aucune application enregistrée pour l'instant.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let maxCount = max(snapshot.topApps.map(\.dictations).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.topApps, id: \.name) { app in
                    HStack(spacing: 10) {
                        Text(app.name)
                            .font(.callout)
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: max(6, proxy.size.width * CGFloat(app.dictations) / CGFloat(maxCount)))
                        }
                        .frame(height: 8)
                        Text("\(app.dictations)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func refresh() {
        snapshot = UsageStatsStore.shared.snapshot()
    }

    private func format(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
