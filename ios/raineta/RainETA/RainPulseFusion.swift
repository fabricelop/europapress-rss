import Foundation

/// A one-minute *display grid*, not one-minute physical model output.
/// The five models supply preceding-hour accumulation buckets.
struct RainPulseMinute: Identifiable {
    let minute: Int
    let date: Date
    let rateMMH: Double
    let automaticMMH: Double?
    let lowMMH: Double
    let highMMH: Double
    let availableModels: Int
    let rainyModels: Int
    let usesModelMedian: Bool
    var id: Int { minute }

    var disagreement: Bool {
        availableModels >= 2 && rainyModels > 0 && rainyModels < availableModels
    }
}

struct RainPulseModelMinute: Identifiable {
    let name: String
    let minute: Int
    let mmh: Double
    var id: String { "\(name)-\(minute)" }
}

enum RainPulseFusion {
    /// For an even model count use the midpoint of the two central rates.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count/2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid-1] + sorted[mid])/2 : sorted[mid]
    }

    /// 15-minute precipitation belongs to the PRECEDING 15 minutes.
    /// For a minute inside that window, use its rate unchanged. It is a
    /// faithful per-minute DISPLAY, not a physical one-minute prediction.
    static func fineRate(at date:Date,samples:[RainSample]) -> Double? {
        guard let item=samples.first(where:{
            $0.time.addingTimeInterval(-900) <= date && date < $0.time
        }) else{return nil}
        return RainInsight.rateFrom15(item.precipitation)
    }

    static func points(samples: [RainSample], models: [RainShortModel],
                       now: Date, horizon: Int, step: Int = 1) -> [RainPulseMinute] {
        guard horizon >= 0, step > 0 else { return [] }
        return stride(from:0,through:horizon,by:step).compactMap { minute in
            let date = now.addingTimeInterval(TimeInterval(minute*60))
            let observations = models.compactMap { $0.rateMMH(at:date) }
            let fine = fineRate(at:date,samples:samples)
            // Keep the finer 15-minute temporal shape as the primary pulse.
            // Hourly ensemble medians are only a fallback if that source lacks
            // data; averaging hourly values into minute bars would otherwise
            // erase dry gaps and manufacture rain all afternoon.
            guard let selected = fine ?? median(observations) else { return nil }
            return RainPulseMinute(
                minute:minute,date:date,rateMMH:selected,automaticMMH:fine,
                lowMMH:observations.min() ?? selected,
                highMMH:observations.max() ?? selected,
                availableModels:observations.count,
                rainyModels:observations.filter{$0 >= 0.1}.count,
                usesModelMedian:observations.count >= 2
            )
        }
    }

    static func individual(models:[RainShortModel],now:Date,horizon:Int,
                           step:Int = 1) -> [RainPulseModelMinute] {
        guard horizon >= 0,step > 0 else{return []}
        return models.flatMap { model in
            stride(from:0,through:horizon,by:step).compactMap { minute in
                let date=now.addingTimeInterval(TimeInterval(minute*60))
                guard let mmh=model.rateMMH(at:date) else {return nil}
                return RainPulseModelMinute(name:model.name,minute:minute,mmh:mmh)
            }
        }
    }

    static func summary(_ rows:[RainPulseMinute]) -> String? {
        guard rows.contains(where:{$0.availableModels >= 2}) else{return nil}
        let divergent=rows.contains{$0.disagreement}
        if divergent {return "Modelos discrepan en el inicio o intensidad"}
        let wet=rows.contains{$0.rainyModels >= max(2,($0.availableModels+1)/2)}
        return wet ? "Coinciden en lluvia dentro del plazo" : "Coinciden en tiempo mayormente seco"
    }
}
