import SwiftUI
import UIKit

// Designed natively for the iPhone. No web container.
struct TTDashboard: View {
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var github = GitHubEditor()
    @State private var search = ""
    @State private var showNewStory = false
    @State private var showSettings = false
    @State private var showCombinedListas = false
    @State private var showEditorialHub = false

    var body: some View {
        ZStack {
            TTTheme.base.ignoresSafeArea()
            LinearGradient(colors: [
                Color(red: 0.06, green: 0.23, blue: 0.32).opacity(0.72),
                TTTheme.base], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                topSections
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        heading
                        counters
                        if store.section == .news && !showCombinedListas { sourceCounters }
                        connectedLabel
                        PendingOperationsPanel().environmentObject(store)
                        if store.actionIsError && !store.actionMessage.isEmpty {
                            editorialActionBanner
                        }
                        subTabs
                        searchField
                        if showCombinedListas { combinedListasContent }
                        else if store.section == .trends { trendsContent }
                        else { newsContent }
                        Color.clear.frame(height: 18)
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 18)
                }
                .refreshable { await store.refresh() }
            }
        }
        .preferredColorScheme(.dark)
        .task { await github.renewOnForeground() }
        .onOpenURL { url in
            if url.scheme == "ttactualidad" {
                showCombinedListas = url.host == "listas"
            }
        }
        .onChange(of: scenePhase) { _, next in
            if next == .active {
                Task {
                    await github.renewOnForeground()
                    await store.refresh()
                }
            }
        }
        .sheet(isPresented: $showNewStory) {
            NewsSubmissionSheet(github: github, onQueued: {
                showCombinedListas = false
                store.section = .news
                store.newsFilter = .elaboracion
                search = ""
            })
            .environmentObject(store)
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showSettings) {
            GitHubConnectionSheet(github: github).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEditorialHub) {
            EditorialHub(
                openLists: { showCombinedListas = true },
                openRadar: { showCombinedListas = false; store.section = .trends; store.trendFilter = .top },
                openWorking: { showCombinedListas = false; store.section = .news; store.newsFilter = .elaboracion }
            ).environmentObject(store)
        }
        .onChange(of: store.section) { _, _ in
            search = ""
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(TTTheme.teal.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(TTTheme.teal.opacity(0.5)))
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(TTTheme.teal)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("TTActualidad")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .tracking(-1.0)
                Text("CONTROL EDITORIAL")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.2).foregroundStyle(TTTheme.teal)
            }
            Spacer(minLength: 0)
            Button { showEditorialHub = true } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(TTTheme.teal)
                    .font(.system(size: 19))
                    .frame(width: 36, height: 42)
            }
            .accessibilityLabel("Tablero y novedades")
            Button { showSettings = true } label: {
                Image(systemName: github.authenticated ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(github.authenticated ? TTTheme.teal : TTTheme.muted)
                    .font(.system(size: 20))
                    .frame(width: 42, height: 42)
                    .background(TTTheme.panel, in: Circle())
            }
            .accessibilityLabel("Conexión GitHub")
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isLoading { ProgressView().tint(TTTheme.teal) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 19, weight: .bold)) }
                }
                .frame(width: 42, height: 42)
                .background(TTTheme.panel, in: Circle())
            }
            .tint(TTTheme.teal)
            .disabled(store.isLoading)
            .accessibilityLabel("Actualizar")
        }
        .padding(.horizontal, 15)
        .padding(.top, 7)
        .padding(.bottom, 12)
    }

    private var topSections: some View {
        HStack(spacing: 4) {
            tab("TTiTTulares", active: !showCombinedListas && store.section == .news) {
                showCombinedListas = false; store.section = .news
            }
            tab("TTendencias", active: !showCombinedListas && store.section == .trends) {
                showCombinedListas = false; store.section = .trends
            }
            tab("Listas", active: showCombinedListas) { showCombinedListas = true }
        }
        .padding(5)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 15)
    }
    private func tab(_ name: String, active: Bool, change: @escaping () -> Void) -> some View {
        Button(action: change) {
            Text(name)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 41)
                .background(active ? Color(red: 0.15, green: 0.31, blue: 0.45) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? TTTheme.teal.opacity(0.55) : .clear))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(showCombinedListas ? "Listas editoriales" :
                     store.section == .trends ? "Top 30 España" : "Noticias listas")
                    .font(.system(size: showCombinedListas ? 23 : 25,
                                  weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .tracking(-0.6)
                Text(showCombinedListas ? "Publica o gestiona todo desde aquí" :
                     store.section == .trends ? trendRadarSubtitle : "Noticias preparadas para publicar")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    if showCombinedListas {
                        published24hChip("TTiT", project: "ttittulares",
                                         at: context.date, compact: true)
                        published24hChip("TTen", project: "ttendencias",
                                         at: context.date, compact: true)
                    } else {
                        published24hChip("24 h publicados",
                                         project: store.section == .news ?
                                                  "ttittulares" : "ttendencias",
                                         at: context.date, compact: false)
                    }
                }
            }
            if store.section == .news && !showCombinedListas {
                Button { showNewStory = true } label: {
                    Label("Noticia", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TTTheme.base)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(TTTheme.teal, in: Capsule())
                }
                .accessibilityLabel("Añadir noticia")
            }
        }
    }

    private func published24hChip(_ label: String, project: String, at now: Date,
                                   compact: Bool) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: compact ? 9 : 8, weight: .bold))
                .foregroundStyle(TTTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(store.publicationsLast24h(project: project, now: now)
                 .map { String($0) } ?? "—")
                .font(.system(size: compact ? 17 : 19,
                              weight: .heavy, design: .rounded))
                .foregroundStyle(project == "ttittulares" ? TTTheme.teal : TTTheme.blue)
                .monospacedDigit()
        }
        .frame(width: compact ? 51 : 72, height: 44)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke((project == "ttittulares" ? TTTheme.teal : TTTheme.blue)
                        .opacity(0.35)))
        .accessibilityLabel("\(label): " +
            (store.publicationsLast24h(project: project, now: now)
                .map { String($0) } ?? "sin datos") +
            " publicaciones marcadas y confirmadas en las últimas 24 horas")
    }

    private var trendRadarSubtitle: String {
        guard let last = store.snapshot.trendsRadarAt else {
            return "Radar · Aún sin fecha verificable"
        }
        let age = max(0, Date().timeIntervalSince(last))
        let duration = age < 3600 ? "\(Int(age / 60)) min" :
                       "\(Int(age / 3600)) h"
        let reliability = store.snapshot.trendsRadarReliability.lowercased()
        let flag = age > 1800 || ["fallback", "stale", "low"].contains(reliability) ?
                   " · Revisar fiabilidad" : ""
        return "Radar hace \(duration)" + flag
    }

    private var counters: some View {
        HStack(spacing: 9) {
            Button {
                showCombinedListas = false
                store.section = .news
                store.newsFilter = .listas
                search = ""
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                metric(label: "NOTICIAS EN LISTAS", number: store.snapshot.news.count,
                       icon: "newspaper.fill", tint: TTTheme.teal)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir noticias en Listas")
            Button {
                showCombinedListas = false
                store.section = .trends
                store.trendFilter = .listas
                search = ""
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                metric(label: "TENDENCIAS EN LISTAS", number: store.snapshot.trendListas.count,
                       icon: "chart.bar.fill", tint: TTTheme.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir tendencias en Listas")
        }
    }
    private func metric(label: String, number: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(TTTheme.muted).lineLimit(1).minimumScaleFactor(0.7)
            Text(String(number))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(tint.opacity(0.35)))
    }

    private func signedDelta(_ delta: Int?) -> String {
        guard let delta else { return "(—)" }
        return "(" + (delta > 0 ? "+" : "") + String(delta) + ")"
    }

    private var sourceCounters: some View {
        HStack(spacing: 12) {
            Label("1 fuente", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(TTTheme.muted)
            Text(store.snapshot.oneSourceCount.map(String.init) ?? "—")
                .fontWeight(.bold).monospacedDigit()
            Text(signedDelta(store.snapshot.oneSourceDelta))
                .foregroundStyle(TTTheme.teal)
            Spacer(minLength: 5)
            Text("2 fuentes").foregroundStyle(TTTheme.muted)
            Text(store.snapshot.twoSourceCount.map(String.init) ?? "—")
                .fontWeight(.bold).monospacedDigit()
            Text(signedDelta(store.snapshot.twoSourceDelta))
                .foregroundStyle(TTTheme.teal)
        }
        .font(.system(size: 11, weight: .medium))
        .minimumScaleFactor(0.7).lineLimit(1)
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel("Radar: noticias con una fuente y dos fuentes, variación respecto al radar anterior")
    }

    private var editorialActionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: store.actionIsError ?
                  "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(store.actionIsError ? Color.orange : TTTheme.teal)
            Text(store.actionMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(TTTheme.cardInterior, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(TTTheme.cardBorder, lineWidth: 1.5))
    }

    private var connectedLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: store.snapshot.partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(store.snapshot.partial ? .orange : TTTheme.teal)
            Text(store.snapshot.partial ? "Copia local disponible" : "GitHub directo · Sin Cloudflare")
            Spacer(minLength: 2)
            if let checked = store.snapshot.updatedAt {
                Text(checked, format: .dateTime.day().month().hour().minute())
            }
        }
        .font(.system(size: 10)).foregroundStyle(TTTheme.muted)
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    // Every filter remains visible: two rows, no horizontal swipe navigation.
    // Long labels can wrap; compact counts remain legible on small phones.
    private var subTabs: some View {
        Group {
            if !showCombinedListas {
                if store.section == .trends {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5),
                                             count: 4), spacing: 5) {
                        filterChip("Top 30", store.snapshot.top30.count,
                                   store.trendFilter == .top) { store.trendFilter = .top }
                        filterChip("Listas", store.snapshot.trendListas.count,
                                   store.trendFilter == .listas) { store.trendFilter = .listas }
                        filterChip("En elaboración", store.snapshot.trendsElaboracion.count,
                                   store.trendFilter == .elaboracion) { store.trendFilter = .elaboracion }
                        filterChip("Nuevas", filteredTrends(.nuevas).count,
                                   store.trendFilter == .nuevas) { store.trendFilter = .nuevas }
                        filterChip("Recientes", filteredTrends(.recientes).count,
                                   store.trendFilter == .recientes) { store.trendFilter = .recientes }
                        filterChip("Pendientes", filteredTrends(.pendientes).count,
                                   store.trendFilter == .pendientes) { store.trendFilter = .pendientes }
                        filterChip("Antiguas", filteredTrends(.antiguas).count,
                                   store.trendFilter == .antiguas) { store.trendFilter = .antiguas }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5),
                                             count: 3), spacing: 5) {
                        filterChip("Listas", store.snapshot.news.count,
                                   store.newsFilter == .listas) { store.newsFilter = .listas }
                        filterChip("En elaboración", store.snapshot.newsElaboracion.count,
                                   store.newsFilter == .elaboracion) { store.newsFilter = .elaboracion }
                        filterChip("Revisión", store.snapshot.newsRevision.count,
                                   store.newsFilter == .revision) { store.newsFilter = .revision }
                        filterChip("Creciendo", store.snapshot.newsCreciendo.count,
                                   store.newsFilter == .creciendo) { store.newsFilter = .creciendo }
                        filterChip("Tremending", store.snapshot.newsTremending.count,
                                   store.newsFilter == .tremending) { store.newsFilter = .tremending }
                    }
                }
            }
        }
    }

    private func filterChip(_ name: String, _ count: Int, _ active: Bool,
                            onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 2) {
                Text(name)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .frame(height: 24, alignment: .center)
                    .frame(maxWidth: .infinity)
                Text(String(count))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(active ? TTTheme.teal : TTTheme.muted)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 2).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(active ? TTTheme.teal.opacity(0.17) : TTTheme.panel,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(active ? TTTheme.teal.opacity(0.7) :
                                TTTheme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name): \(count)")
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(TTTheme.muted)
            TextField(showCombinedListas ? "Buscar en Listas..." :
                      store.section == .news ? "Buscar noticia..." : "Buscar tendencia...",
                      text: $search)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(TTTheme.muted)
            }
            Divider().frame(height: 18)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .foregroundStyle(TTTheme.teal)
            .accessibilityLabel("Actualizar datos desde GitHub")
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var combinedListasContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("TTiTTulares", systemImage: "newspaper.fill")
                    .font(.headline).foregroundStyle(TTTheme.teal)
                Spacer()
                Text(String(store.snapshot.news.count))
                    .font(.headline.monospacedDigit()).foregroundStyle(TTTheme.teal)
            }
            ForEach(store.snapshot.news.filter {
                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            }) { story in
                NewsTile(item: story, github: github, settings: $showSettings)
            }
            HStack {
                Label("TTendencias", systemImage: "chart.bar.fill")
                    .font(.headline).foregroundStyle(TTTheme.blue)
                Spacer()
                Text(String(store.snapshot.trendListas.count))
                    .font(.headline.monospacedDigit()).foregroundStyle(TTTheme.blue)
            }
            .padding(.top, 8)
            LazyVStack(spacing: 5) {
                ForEach(store.snapshot.trendListas.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                }) { item in
                    TrendTile(item: item, showRank: item.rank > 0,
                              github: github, settings: $showSettings)
                }
            }
            if store.snapshot.news.isEmpty && store.snapshot.trendListas.isEmpty {
                emptyNotice("No hay elementos en Listas")
            }
        }
    }

    @ViewBuilder private var newsContent: some View {
        let category: [NewsItem] = {
            switch store.newsFilter {
            case .listas: return store.snapshot.news
            case .elaboracion: return store.snapshot.newsElaboracion
            case .revision: return store.snapshot.newsRevision
            case .creciendo: return store.snapshot.newsCreciendo
            case .tremending: return store.snapshot.newsTremending
            }
        }()
        let visible = category.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.text.localizedCaseInsensitiveContains(search)
        }
        if visible.isEmpty { emptyNotice("No hay noticias en Listas") }
        ForEach(visible) { story in
            NewsTile(item: story, github: github, settings: $showSettings)
        }
    }

    private func filteredTrends(_ filter: TrendFilter) -> [TrendItem] {
        let items = store.snapshot.top30
        switch filter {
        case .top: return items
        case .listas: return store.snapshot.trendListas
        case .elaboracion: return store.snapshot.trendsElaboracion
        case .nuevas:
            // Compare observed radar snapshots on this device, not "new"
            // from a rank aggregator (which can classify 25 old labels as new).
            return items.filter { store.radarNewNames.contains($0.name) }
        case .recientes:
            return items.filter { $0.lastExplained.map {
                Date().timeIntervalSince($0) >= 0 && Date().timeIntervalSince($0) < 12 * 3600
            } ?? false }
        case .pendientes: return items.filter { $0.explanation.isEmpty }
        case .antiguas: return items.filter { $0.ageBand() == 3 }
        }
    }

    @ViewBuilder private var trendsContent: some View {
        let category = filteredTrends(store.trendFilter)
        let visible = category.filter {
                search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.explanation.localizedCaseInsensitiveContains(search)
            }
        if visible.isEmpty { emptyNotice("No hay tendencias para mostrar") }
        LazyVStack(spacing: 5) {
            ForEach(visible) { item in
                TrendTile(item: item, showRank: item.rank > 0,
                          github: github, settings: $showSettings)
            }
        }
    }
    private func emptyNotice(_ label: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(TTTheme.muted)
            Text(label).font(.headline)
            Text("Desliza para actualizar desde GitHub.").font(.caption).foregroundStyle(TTTheme.muted)
        }
        .frame(maxWidth: .infinity).padding(24)
        .background(TTTheme.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

// Compact by default. Expand only the chosen story: no long headlines
// force all other stories off screen, and no editorial buttons are removed.
private struct NewsTile: View {
    @EnvironmentObject private var store: EditorialStore
    let item: NewsItem
    @ObservedObject var github: GitHubEditor
    @Binding var settings: Bool
    @State private var expanded = false

    private var accent: Color {
        switch item.status {
        case "LISTA": return TTTheme.teal
        case "REVISIÓN": return .orange
        case "CRECIENDO": return TTTheme.blue
        default: return TTTheme.muted
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Label(item.status, systemImage: item.status == "LISTA" ?
                          "checkmark.seal.fill" : "clock.arrow.circlepath")
                        .foregroundStyle(accent)
                    if item.sources > 0 {
                        Label("\(item.sources) fuentes", systemImage: "link")
                            .foregroundStyle(TTTheme.muted)
                    }
                    Spacer(minLength: 0)
                    if let date = item.publishedAt {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .foregroundStyle(TTTheme.muted)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                if let image = item.imageURL {
                    AsyncImage(url: image) { picture in
                        picture.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 10).fill(TTTheme.cardInterior)
                            .overlay(ProgressView().tint(TTTheme.teal))
                    }
                    .frame(height: 145).frame(maxWidth: .infinity)
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("Sin fotografía de archivo", systemImage: "photo")
                        .font(.caption2).foregroundStyle(TTTheme.muted)
                }
                Text(item.factual.isEmpty ?
                     (item.text.isEmpty ? "Pendiente de explicación editorial." : item.text) :
                     item.factual)
                    .font(.system(size: 14)).lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                if !item.closer.isEmpty {
                    Text(item.closer)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.80, blue: 0.55))
                }
                Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
                EditorialActions(news: item, github: github, showSettings: $settings)
            }
            .padding(.top, 13)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3, height: 33)
                Text(item.title)
                    .font(.system(size: expanded ? 16 : 14,
                                  weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 36)
        }
        .tint(TTTheme.muted)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(
            LinearGradient(colors: [TTTheme.cardHighlight.opacity(0.7),
                                    TTTheme.cardInterior],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(TTTheme.cardBorder, lineWidth: 1.8))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onChange(of: expanded) { _, value in
            if value { store.markNewsReviewed(item.id) }
        }
    }
}

private struct TrendTile: View {
    @EnvironmentObject private var store: EditorialStore
    let item: TrendItem
    let showRank: Bool
    @ObservedObject var github: GitHubEditor
    @Binding var settings: Bool
    @State private var expanded = false

    // Saturated hues are exclusive to the rank plate. The rest of the card
    // retains its original dark surface to prioritize text legibility.
    private var rankColor: Color {
        switch item.ageBand() {
        case 1: return Color(red: 0.06, green: 0.80, blue: 0.52) // green
        case 2: return Color(red: 1.00, green: 0.77, blue: 0.14) // yellow
        case 3: return Color(red: 0.95, green: 0.22, blue: 0.34) // red
        default: return Color(red: 0.20, green: 0.52, blue: 0.98) // blue
        }
    }

    private var rankTextColor: Color {
        item.ageBand() == 2 ? TTTheme.base : .white
    }

    // The vivid left rank keeps its saturation; the card itself is a dark,
    // desaturated tint of the same hue (as in the original compact design).
    private var softCardColor: Color {
        switch item.ageBand() {
        case 1: return Color(red: 0.105, green: 0.235, blue: 0.285) // subtle green
        case 2: return Color(red: 0.240, green: 0.222, blue: 0.235) // subtle yellow
        case 3: return Color(red: 0.235, green: 0.158, blue: 0.247) // subtle red
        default: return Color(red: 0.150, green: 0.200, blue: 0.310) // subtle blue
        }
    }

    private var shortStatus: String {
        switch item.status {
        case "EN ELABORACIÓN": return "ELAB."
        case "PREPARACIÓN MANUAL": return "MANUAL"
        case "EXPLICADA": return "EXPL."
        case "PENDIENTE": return "PEND."
        default: return item.status
        }
    }

    private var movementLabel: String {
        if store.radarNewNames.contains(item.name) { return "NUEVA" }
        // The radar aggregator's own "new" status can mean uncorroborated
        // ranking history, not first occurrence. Do not mislabel it as new.
        if item.movement == "new" { return "—" }
        if item.rankDelta > 0 { return "↑\(item.rankDelta)" }
        if item.rankDelta < 0 { return "↓\(abs(item.rankDelta))" }
        return item.movement == "flat" ? "↔0" : "—"
    }

    private var movementColor: Color {
        if store.radarNewNames.contains(item.name) { return TTTheme.blue }
        if item.rankDelta > 0 { return TTTheme.teal }
        if item.rankDelta < 0 { return Color(red: 1, green: 0.65, blue: 0.45) }
        return TTTheme.muted
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(item.status)
                        .font(.caption2.weight(.semibold)).foregroundStyle(rankColor)
                    Spacer()
                    if let date = item.lastExplained {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(.caption2).foregroundStyle(TTTheme.muted)
                    }
                }
                if item.explanation.isEmpty {
                    Text("Aún no hay explicación editorial.")
                        .font(.subheadline).foregroundStyle(TTTheme.muted)
                } else {
                    Text(item.explanation)
                        .font(.system(size: 14)).lineSpacing(3)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .textSelection(.enabled)
                }
                if let image = item.imageURL {
                    AsyncImage(url: image) { picture in
                        picture.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().tint(TTTheme.teal)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("Sin fotografía de archivo", systemImage: "photo")
                        .font(.caption2).foregroundStyle(TTTheme.muted)
                }
                EditorialActions(trend: item, github: github, showSettings: $settings)
            }
            .padding(.top, 12)
            .padding(.horizontal, 9)
            .padding(.bottom, 5)
        } label: {
            HStack(spacing: 7) {
                if showRank {
                    Text("#\(item.rank)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(rankTextColor)
                        .monospacedDigit()
                        .frame(width: 38, height: 31)
                        .background(rankColor, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.leading, 5)
                        .accessibilityLabel("Posición \(item.rank)")
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(rankColor)
                        .frame(width: 4, height: 28)
                        .padding(.leading, 8)
                }
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showRank {
                    Text(movementLabel)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(movementColor)
                        .lineLimit(1)
                        .frame(minWidth: 25, alignment: .trailing)
                        .accessibilityLabel("Movimiento en el ranking: " + movementLabel)
                }

                Text(shortStatus)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TTTheme.teal)
                    .lineLimit(1)
                    .frame(width: 39, alignment: .trailing)

                if let date = item.lastExplained {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(TTTheme.muted)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .frame(minHeight: 32)
        }
        .tint(TTTheme.muted)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            LinearGradient(colors: [softCardColor, TTTheme.cardInterior],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(TTTheme.cardBorder, lineWidth: 1.8))
        .onChange(of: expanded) { _, value in
            if value { store.markTrendReviewed(item.name) }
        }
    }
}
