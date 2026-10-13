import Foundation
import SwiftUI

enum RainVisual {
    /// Physical rate in mm/h. Values derived from 15-minute totals are
    /// time-averages, not measured independent one-minute forecasts.
    static func color(_ rate: Double) -> Color {
        switch rate {
        case ..<0.15: return .gray.opacity(0.32)
        case ..<0.6: return .cyan
        case ..<2.5: return .blue
        case ..<7.5: return .indigo
        case ..<15: return .orange
        default: return .pink
        }
    }
    static func intensity(_ rate: Double) -> String {
        switch rate {
        case ..<0.15: return "Sin lluvia"
        case ..<0.6: return "Llovizna"
        case ..<2.5: return "Débil"
        case ..<7.5: return "Moderada"
        case ..<15: return "Fuerte"
        default: return "Muy intensa"
        }
    }
}

struct RainMoment: Identifiable {
    let minute: Int
    let date: Date
    let rateMMH: Double
    let probability: Int?
    let source: String
    var id: Int { minute }
}

struct RainPeriod: Identifiable {
    let start: Date
    let end: Date
    let peakMMH: Double
    let accumulationMM: Double
    var id: Date { start }
    var label: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: start))–\(fmt.string(from: end))"
    }
}

struct RainTransition {
    let raining: Bool
    let change: Date?
    let nextIsRain: Bool
}

enum RainInsight {
    static let wetRate = 0.4 // mm/h, >=0.1 mm per 15-minute period
    static let dryRate = 0.32

    static func rateFrom15(_ amount: Double) -> Double {
        max(0, amount * 4)
    }

    /// Time interpolation for visual continuity only.
    /// The source is still the underlying 15-minute model series.
    static func interpolatedRate(at date: Date, samples: [RainSample]) -> Double? {
        let ordered = samples.sorted { $0.time < $1.time }
        guard let first = ordered.first, let last = ordered.last,
              date >= first.time.addingTimeInterval(-900),
              date <= last.time.addingTimeInterval(900) else { return nil }
        if date <= first.time { return rateFrom15(first.precipitation) }
        if date >= last.time { return rateFrom15(last.precipitation) }
        guard let hi = ordered.firstIndex(where: { $0.time >= date }), hi > 0 else { return nil }
        let lo = ordered[hi-1]
        let top = ordered[hi]
        let duration = top.time.timeIntervalSince(lo.time)
        let part = duration > 0 ? min(1,max(0,date.timeIntervalSince(lo.time)/duration)) : 0
        return max(0, rateFrom15(lo.precipitation)*(1-part)+rateFrom15(top.precipitation)*part)
    }

    static func moments(samples: [RainSample], from now: Date,
                        minutes horizon: Int, step: Int = 1) -> [RainMoment] {
        guard horizon > 0,step > 0 else { return [] }
        return stride(from: 0,through:horizon,by:step).compactMap { minute in
            let date = now.addingTimeInterval(TimeInterval(minute*60))
            guard let rate = interpolatedRate(at:date,samples:samples) else { return nil }
            let probability = samples.min(by: { abs($0.time.timeIntervalSince(date)) <
                                              abs($1.time.timeIntervalSince(date)) })?.probability
            return RainMoment(minute:minute,date:date,
                              rateMMH:rate,probability:probability,
                              source:"Modelo interpolado 15 min")
        }
    }

    /// Detect continuous periods from native (not one-minute interpolated)
    /// model time-steps. Two successive dry readings to end a wet period
    /// avoid false rapid onset/cessation countdowns.
    static func periods(samples: [RainSample], after now: Date,
                        until horizon: Date) -> [RainPeriod] {
        let sequence = samples.sorted { $0.time < $1.time }
            .filter { $0.time >= now.addingTimeInterval(-900) && $0.time <= horizon }
        guard !sequence.isEmpty else { return [] }
        var periods:[RainPeriod] = []
        var start:Date?
        var peak = 0.0
        var mm = 0.0
        var dryCount = 0
        var lastWet:Date?
        for sample in sequence {
            let value = max(0,sample.precipitation)
            let rate = rateFrom15(value)
            if rate >= wetRate {
                if start == nil { start = sample.time }
                peak = max(peak,rate)
                mm += value
                lastWet = sample.time
                dryCount = 0
            } else if start != nil {
                dryCount += 1
                if dryCount >= 2 {
                    let close = sample.time.addingTimeInterval(-900)
                    periods.append(RainPeriod(start:start!,end:max(start!,close),
                                              peakMMH:peak,accumulationMM:mm))
                    start = nil
                    peak = 0
                    mm = 0
                    dryCount = 0
                    lastWet = nil
                }
            }
        }
        if let start {
            periods.append(RainPeriod(start:start,
                                      end:min(horizon,(lastWet ?? start).addingTimeInterval(900)),
                                      peakMMH:peak,accumulationMM:mm))
        }
        return periods
    }

    static func transition(currentIsRaining: Bool, samples: [RainSample],
                           now:Date) -> RainTransition {
        let horizon = now.addingTimeInterval(24*3600)
        let events = periods(samples:samples,after:now,until:horizon)
        if currentIsRaining {
            let ongoing = events.first { $0.start <= now.addingTimeInterval(900) && $0.end > now }
            return RainTransition(raining:true,
                                  change:ongoing?.end,
                                  nextIsRain:false)
        }
        return RainTransition(raining:false,
                              change:events.first(where: { $0.start > now.addingTimeInterval(-900) })?.start,
                              nextIsRain:true)
    }

    static func countdown(to date:Date?,at now:Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0,Int(date.timeIntervalSince(now)))
        if seconds >= 3600 {
            return String(format:"%dh %02dm",seconds/3600,(seconds%3600)/60)
        }
        return String(format:"%02d:%02d",seconds/60,seconds%60)
    }

    /// Open-Meteo hourly precipitation represents the PRECEDING hour:
    /// a sample stamped 07:00 belongs to 06:00–07:00.
    static func hourlyStart(_ timestamp:Date) -> Date {
        timestamp.addingTimeInterval(-3600)
    }

    /// A probability is not an amount. Flag possible disagreements without
    /// hiding or manufacturing a precipitation reading.
    static func precipitationUncertainty(hours:[HourlyRain],day:Date,
                                         calendar:Calendar = .current) -> Bool {
        let start=calendar.startOfDay(for:day)
        guard let end=calendar.date(byAdding:.day,value:1,to:start) else{return false}
        let hours=hours.filter{$0.time>start && $0.time<=end}
        let significant=hours.filter{$0.millimeters>=0.1}
        guard !significant.isEmpty else{return false}
        let peakProbability=hours.map(\.probability).max() ?? 0
        let wetPeak=significant.map(\.probability).max() ?? 0
        return significant.allSatisfy{$0.probability<=20} &&
               peakProbability>=20 && peakProbability-wetPeak>=10
    }

    static func dailyPeriods(_ weather: RainSnapshot, day:Date,
                             calendar:Calendar = .current) -> [RainPeriod] {
        let start=calendar.startOfDay(for:day)
        guard let end=calendar.date(byAdding:.day,value:1,to:start) else{return []}
        // Include the next midnight as the *end* of the preceding day's last
        // hour. The 00:00 sample belongs to 23:00–00:00, not the new day.
        let buckets=weather.hours.filter{$0.time>start && $0.time<=end}
            .sorted{$0.time<$1.time}
        var runs:[RainPeriod]=[]
        var begins:Date?
        var peak=0.0
        var mm=0.0
        var lastEnd:Date?
        for item in buckets {
            let hourStart=max(start,hourlyStart(item.time))
            if item.millimeters>=0.1 {
                if begins==nil{begins=hourStart}
                peak=max(peak,item.millimeters)
                mm+=item.millimeters
                lastEnd=item.time
            } else if let began=begins {
                runs.append(RainPeriod(start:began,end:lastEnd ?? hourStart,
                                       peakMMH:peak,accumulationMM:mm))
                begins=nil;peak=0;mm=0;lastEnd=nil
            }
        }
        if let began=begins {
            runs.append(RainPeriod(start:began,end:min(end,lastEnd ?? end),
                                   peakMMH:peak,accumulationMM:mm))
        }
        return runs
    }
}
