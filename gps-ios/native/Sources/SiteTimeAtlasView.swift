import SwiftUI

private enum SiteAtlasPeriod: String, CaseIterable, Identifiable {
    case day = "Día"
    case week = "7 días"
    case month = "30 días"
    case custom = "Rango"
    var id: String { rawValue }
}

/// A colorful, zero-network daily footprint. The expensive GPS aggregation
/// runs once on a utility queue. Filters only query compact date-indexed rows.
struct SiteTimeAtlasView: View {
    let model: TimeModel
    let visits: [UUID:[SiteVisitRecord]]
    let sites: [IdentifiedSite]

    @State private var snapshot: SiteAtlasSnapshot?
    @State private var computing = false
    @State private var generation = UUID()
    @State private var period: SiteAtlasPeriod = .week
    @State private var chosenDate = Date()
    @State private var lowerDate = Calendar.current.date(
        byAdding:.day,value:-6,to:Date()) ?? Date()
    @State private var upperDate = Date()
    @State private var expandedDay: Date?

    private let colors: [Color] = [
        Color(red:0.04,green:0.78,blue:0.88),
        Color(red:1.00,green:0.76,blue:0.15),
        Color(red:0.76,green:0.38,blue:0.94),
        Color(red:1.00,green:0.32,blue:0.44),
        Color(red:0.30,green:0.86,blue:0.53),
        Color(red:1.00,green:0.58,blue:0.21),
        Color(red:0.30,green:0.54,blue:0.99),
        Color(red:0.95,green:0.42,blue:0.77),
        Color(red:0.48,green:0.85,blue:0.77),
        Color(red:0.93,green:0.74,blue:0.55),
        Color(red:0.64,green:0.63,blue:0.98),
        Color(red:0.64,green:0.84,blue:0.30)
    ]

    private var selectedWindow: DateInterval {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for:.now)
        let start:Date
        let finish:Date
        switch period {
        case .day:
            start = calendar.startOfDay(for:chosenDate)
            finish = start
        case .week:
            start = calendar.date(byAdding:.day,value:-6,to:today) ?? today
            finish = today
        case .month:
            start = calendar.date(byAdding:.day,value:-29,to:today) ?? today
            finish = today
        case .custom:
            let a=calendar.startOfDay(for:lowerDate)
            let b=calendar.startOfDay(for:upperDate)
            start=min(a,b)
            finish=max(a,b)
        }
        return DateInterval(start:start,end:calendar.date(
            byAdding:.day,value:1,to:finish) ?? finish.addingTimeInterval(86400))
    }

    private var selectedDays:[SiteAtlasDay] {
        guard let snapshot else { return [] }
        let window = selectedWindow
        return snapshot.days.filter { $0.date >= window.start && $0.date < window.end }
    }

    private var ranking:[SiteAtlasEntry] {
        SiteAtlasEngine.rank(selectedDays)
    }

    private var totalSeconds:TimeInterval { ranking.reduce(0) {$0+$1.seconds} }

    private func color(_ siteID:UUID)->Color {
        let index=snapshot?.globalColorIndexes[siteID] ?? 0
        return colors[index % colors.count]
    }

    private func prepareIndex() {
        guard snapshot == nil,!computing else { return }
        computing=true
        let request=UUID()
        generation=request
        let visitSnapshot=visits
        let knownSites=sites
        let calendar=Calendar.current
        DispatchQueue.global(qos:.utility).async {
            let result=SiteAtlasEngine.build(visits:visitSnapshot,
                                              sites:knownSites,calendar:calendar)
            DispatchQueue.main.async {
                guard generation == request else { return }
                snapshot=result
                computing=false
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:16) {
                filters
                if computing && snapshot == nil {
                    ProgressView("Construyendo Atlas de estancias…")
                        .frame(maxWidth:.infinity,minHeight:110)
                } else if selectedDays.isEmpty {
                    ContentUnavailableView("Sin sitios en estas fechas",
                        systemImage:"calendar.badge.exclamationmark",
                        description:Text("El Atlas solo muestra tiempo GPS registrado y asignado a sitios."))
                } else {
                    hero
                    rankingPanel
                    dailyPanel
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Atlas de estancias")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prepareIndex() }
    }

    private var filters:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("MI HUELLA EN LOS SITIOS",systemImage:"circle.hexagongrid.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.teal)
            Text("Dónde he pasado mi tiempo")
                .font(.title2.weight(.bold))
            Picker("Período",selection:$period) {
                ForEach(SiteAtlasPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            if period == .day {
                DatePicker("Día",selection:$chosenDate,displayedComponents:.date)
                    .datePickerStyle(.compact)
            } else if period == .custom {
                DatePicker("Desde",selection:$lowerDate,displayedComponents:.date)
                DatePicker("Hasta",selection:$upperDate,displayedComponents:.date)
                Text("Se incluyen ambos días, aunque las fechas estén invertidas.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(selectedWindow.start.formatted(.dateTime.day().month().year())
                 + " – " +
                 selectedWindow.end.addingTimeInterval(-1).formatted(
                    .dateTime.day().month().year()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:20))
    }

    private var hero:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Label("Constelación de lugares",systemImage:"sparkles")
                    .font(.headline)
                Spacer()
                Text("\(selectedDays.count) días con GPS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.12),lineWidth:22)
                ForEach(Array(ranking.prefix(12).enumerated()),
                        id:\.element.siteID) { item in
                    let before=ranking.prefix(item.offset).reduce(0){$0+$1.seconds}
                    let from=before/max(1,totalSeconds)
                    let to=(before+item.element.seconds)/max(1,totalSeconds)
                    Circle()
                        .trim(from:from,to:to)
                        .stroke(color(item.element.siteID),
                                style:StrokeStyle(lineWidth:22,lineCap:.butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing:5) {
                    Text("TIEMPO EN SITIOS")
                        .font(.system(size:10,weight:.bold))
                        .foregroundStyle(.secondary)
                    Text(DurationFormat.full(totalSeconds))
                        .font(.system(size:24,weight:.bold,design:.rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("\(ranking.count) lugares")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .frame(width:204,height:204)
            .frame(maxWidth:.infinity)
            .padding(.vertical,7)
            Text("Cada color representa un sitio. El tamaño del arco refleja su tiempo GPS real.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:20))
    }

    private var rankingPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Clasificación del período",systemImage:"chart.bar.xaxis")
                .font(.headline)
            ForEach(Array(ranking.prefix(20).enumerated()),
                    id:\.element.siteID) { index,entry in
                NavigationLink {
                    siteHistory(entry.siteID)
                } label: {
                    HStack(spacing:10) {
                        Text("\(index+1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width:22)
                        Circle().fill(color(entry.siteID))
                            .frame(width:11,height:11)
                        VStack(alignment:.leading,spacing:5) {
                            Text(entry.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary).lineLimit(1)
                            GeometryReader { geometry in
                                Capsule().fill(Color.secondary.opacity(0.12))
                                    .overlay(alignment:.leading) {
                                        Capsule().fill(color(entry.siteID))
                                            .frame(width:geometry.size.width *
                                                entry.seconds/max(1,ranking.first?.seconds ?? 1))
                                    }
                            }
                            .frame(height:7)
                        }
                        Spacer(minLength:3)
                        Text(DurationFormat.short(entry.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:20))
    }

    private var dailyPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("ADN DE CADA DÍA",systemImage:"calendar")
                .font(.headline)
            Text("Una huella de colores por día. Despliega un día para ver su clasificación y entrar en cada sitio.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(selectedDays) { day in
                dayCard(day)
            }
        }
    }

    private func dayCard(_ day:SiteAtlasDay)->some View {
        DisclosureGroup(isExpanded:Binding(
            get:{expandedDay == day.date},
            set:{expandedDay=$0 ? day.date : nil}
        )) {
            VStack(alignment:.leading,spacing:11) {
                ForEach(Array(day.places.enumerated()),
                        id:\.element.siteID) { index,entry in
                    NavigationLink { siteHistory(entry.siteID,day:day.date) } label: {
                        HStack(spacing:9) {
                            Text("\(index+1).")
                                .foregroundStyle(.secondary)
                                .frame(width:18,alignment:.leading)
                            Circle().fill(color(entry.siteID))
                                .frame(width:10,height:10)
                            Text(entry.name).lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength:4)
                            Text(DurationFormat.short(entry.seconds))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName:"chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }.font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.top,9)
        } label: {
            VStack(alignment:.leading,spacing:9) {
                HStack {
                    Text(day.date,format:.dateTime.weekday(.wide).day().month())
                        .font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    Text(DurationFormat.short(day.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                dayBar(day)
                HStack {
                    Text(day.places.first?.name ?? "Sin sitio")
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(day.places.count) sitios")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.teal)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:17))
    }

    private func dayBar(_ day:SiteAtlasDay)->some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                ForEach(Array(day.places.enumerated()),id:\.element.siteID) { index,entry in
                    let prior=day.places.prefix(index).reduce(0){$0+$1.seconds}
                    Rectangle()
                        .fill(color(entry.siteID))
                        .frame(width:geo.size.width * entry.seconds/max(1,day.seconds))
                        .offset(x:geo.size.width * prior/max(1,day.seconds))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height:16)
        .accessibilityLabel("Distribución del tiempo GPS entre \(day.places.count) sitios")
    }

    @ViewBuilder private func siteHistory(_ id:UUID,day:Date?=nil)->some View {
        if let site=sites.first(where:{$0.id == id}) {
            let base=visits[id] ?? []
            let records: [SiteVisitRecord]
            if let day {
                let span=SiteCalendarDay.interval(for:day)
                records=base.filter{$0.from < span.end && $0.to > span.start}
            } else {
                let span=selectedWindow
                records=base.filter{$0.from < span.end && $0.to > span.start}
            }
            TimeSiteVisitHistoryView(model:model,site:site,visits:records)
        } else {
            ContentUnavailableView("Sitio no disponible",systemImage:"mappin.slash")
        }
    }
}
