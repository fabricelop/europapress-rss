import Foundation

/// Open-Meteo modelled precipitation PHASE (not determined by radar echoes).
/// Radar can indicate hydrometeors, but cannot identify snow from echo colour.
enum RainPrecipitationPhase: String {
    case rain
    case snow
    case mixed

    static func classify(weatherCode: Int?, snowfallCM: Double) -> Self {
        if let code = weatherCode {
            switch code {
            case 71...77, 85, 86:
                return .snow
            case 56, 57, 66, 67:
                return .mixed  // freezing precipitation; flag uncertainty
            default: break
            }
        }
        if snowfallCM >= 0.1 { return .snow }
        return .rain
    }

    var label: String {
        switch self {
        case .rain: "lluvia"
        case .snow: "nieve"
        case .mixed: "precipitación invernal"
        }
    }

    var glyph: String {
        switch self {
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .mixed: "cloud.sleet.fill"
        }
    }
}

enum RainLiveDisplay {
    static func pulseLevels(_ rates: [Double]) -> [Int] {
        Array(rates.prefix(12)).map {
            guard $0.isFinite else { return 0 }
            switch max(0,$0) {
            case ..<0.15: return 0
            case ..<0.6: return 1
            case ..<2.5: return 2
            case ..<7.5: return 3
            default: return 4
            }
        }
    }

    static func title(wet: Bool, kind: RainPrecipitationPhase,
                      hasReliableTime: Bool) -> String {
        if wet { return kind == .snow ? "Nieve detectada/prevista" :
                         kind == .mixed ? "Precipitación invernal" : "Precipitación actual" }
        return hasReliableTime ? (kind == .snow ? "Se prevé nieve" : "Se prevé lluvia") :
                                 "Sin precipitación próxima confirmada"
    }
}
