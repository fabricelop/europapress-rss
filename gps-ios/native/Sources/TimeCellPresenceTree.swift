import SwiftUI

/// Immutable, day-indexed presentation of one grid square's actual GPS visits.
/// Produced once off the main thread. The original intervals and manual splits
/// remain the authoritative data; expanding rows never queries that history.
struct CellPresencePortion: Identifiable {
    let visit: TimeVisit
    let start: Date
    let end: Date
    let seconds: TimeInterval
    let day: Date
    var id: String { visit.id + "|" + String(day.timeIntervalSince1970) }
}

struct CellPresenceDay: Identifiable {
    let date: Date
    let seconds: TimeInterval
    let portions: [CellPresencePortion]
    var id: Date { date }
    var visits: Int { portions.count }
}

struct CellPresenceMonth: Identifiable {
    let year: Int
    let number: Int
    let title: String
    let days: [CellPresenceDay]
    var id: String { String(year) + "-" + String(number) }
}

struct CellPresenceYear: Identifiable {
    let number: Int
    let months: [CellPresenceMonth]
    var id: Int { number }
}

struct CellPresenceSnapshot {
    let years: [CellPresenceYear]
    let visitCount: Int
    let dayCount: Int
    let confirmedSeconds: TimeInterval
    let averageSeconds: TimeInterval
    let calendar: Calendar
}

enum CellPresenceIndex {
    static func build(_ allVisits: [TimeVisit], total: TimeInterval,
                      calendar: Calendar = .current) -> CellPresenceSnapshot {
        let visible = TimeVisitIndex.visible(allVisits)
        // Include sub-second recorded fragments in a day's total, but show a
        // date only if it has at least one visible (>=1s) real visit.
        var secondsByDay: [Date: TimeInterval] = [:]
        for visit in allVisits {
            for fragment in visit.fragments where fragment.end > fragment.start {
                var cursor = fragment.start
                while cursor < fragment.end {
                    let day = calendar.startOfDay(for: cursor)
                    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
                          tomorrow > cursor else { break }
                    let end = min(fragment.end, tomorrow)
                    secondsByDay[day, default: 0] += end.timeIntervalSince(cursor)
                    cursor = end
                }
            }
        }

        var byDay: [Date: [CellPresencePortion]] = [:]
        for visit in visible {
            var day = calendar.startOfDay(for: visit.start)
            while day < visit.end {
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
                      tomorrow > day else { break }
                let from = max(day, visit.start)
                let until = min(tomorrow, visit.end)
                if until > from {
                    let recorded = visit.fragments.reduce(0.0) { sum, fragment in
                        sum + max(0, min(until, fragment.end)
                                  .timeIntervalSince(max(from, fragment.start)))
                    }
                    if recorded > 0 {
                        byDay[day, default: []].append(
                            CellPresencePortion(visit: visit, start: from, end: until,
                                                seconds: recorded, day: day))
                    }
                }
                day = tomorrow
            }
        }

        var grouped: [Int: [Int: [CellPresenceDay]]] = [:]
        for (date, parts) in byDay {
            guard !parts.isEmpty else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { continue }
            let sorted = parts.sorted { $0.start < $1.start }
            grouped[year, default: [:]][month, default: []].append(
                CellPresenceDay(date: date,
                                seconds: secondsByDay[date] ?? sorted.reduce(0) { $0 + $1.seconds },
                                portions: sorted))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL"
        let years = grouped.keys.sorted(by: >).map { year in
            let months = (grouped[year] ?? [:]).keys.sorted(by: >).map { month in
                let days = (grouped[year]?[month] ?? []).sorted { $0.date < $1.date }
                let title = days.first.map { formatter.string(from: $0.date).capitalized } ?? ""
                return CellPresenceMonth(year: year, number: month, title: title, days: days)
            }
            return CellPresenceYear(number: year, months: months)
        }
        return CellPresenceSnapshot(
            years: years, visitCount: visible.count, dayCount: byDay.count,
            confirmedSeconds: total,
            averageSeconds: visible.isEmpty ? 0 : visible.reduce(0) {
                $0 + $1.confirmedSeconds
            } / Double(visible.count), calendar: calendar)
    }
}

/// Deliberately lightweight: only open years/months/days create child views.
struct TimeCellPresenceTree: View {
    let model: TimeModel
    let snapshot: CellPresenceSnapshot
    let onEdited: () -> Void

    @State private var expandedYears: Set<Int> = []
    @State private var expandedMonths: Set<String> = []
    @State private var expandedDays: Set<Date> = []

    var body: some View {
        if snapshot.years.isEmpty {
            Text("Todavía no hay visitas registradas en esta cuadrícula.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.years) { year in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedYears.contains(year.number) },
                    set: { if $0 { expandedYears.insert(year.number) }
                           else { expandedYears.remove(year.number) } }
                )) {
                    ForEach(year.months) { month in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedMonths.contains(month.id) },
                            set: { if $0 { expandedMonths.insert(month.id) }
                                   else { expandedMonths.remove(month.id) } }
                        )) {
                            ForEach(month.days) { day in
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expandedDays.contains(day.date) },
                                    set: { if $0 { expandedDays.insert(day.date) }
                                           else { expandedDays.remove(day.date) } }
                                )) {
                                    ForEach(day.portions) { item in
                                        TimeCalendarVisitRow(
                                            model: model, visit: item.visit,
                                            start: item.start, end: item.end,
                                            seconds: item.seconds,
                                            timeZone: snapshot.calendar.timeZone,
                                            onEdited: onEdited)
                                    }
                                } label: {
                                    HStack {
                                        Text(day.date.formatted(
                                            .dateTime.day().weekday(.wide)
                                                .locale(Locale(identifier: "es_ES"))))
                                        Spacer(minLength: 5)
                                        Text(DurationFormat.full(day.seconds))
                                            .foregroundStyle(.teal)
                                            .font(.caption.monospacedDigit())
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(month.title)
                                Spacer(minLength: 5)
                                Text("\(month.days.count) días")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                } label: {
                    Text(String(year.number)).font(.headline)
                }
            }
        }
    }
}
