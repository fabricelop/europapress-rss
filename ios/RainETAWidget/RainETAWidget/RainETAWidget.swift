import SwiftUI
import WidgetKit
import AppIntents
import CoreLocation

struct RainETAConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Cuenta atrás RainETA"
    static var description = IntentDescription("Previsión de lluvia para tu ubicación o coordenadas fijas.")

    @Parameter(title: "Usar mi ubicación", default: true)
    var currentLocation: Bool
    @Parameter(title: "Latitud alternativa", default: 40.4168)
    var latitude: Double
    @Parameter(title: "Longitud alternativa", default: -3.7038)
    var longitude: Double
}

struct RainETAResponse: Decodable {
    let ok: Bool
    let phase: String
    let action: String
    let targetAt: String?
    let precisionMinutes: Int?
    let confidence: String?
    let generatedAt: String?
    let summary: String
    let sources: [String]
    func targetDate() -> Date? {
        guard let targetAt else { return nil }
        let formatter=ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date=formatter.date(from: targetAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: targetAt)
    }
}

struct RainETAEntry: TimelineEntry {
    let date: Date
    let place: String
    let response: RainETAResponse?
    let shouldRefresh: Bool
}

struct RainETAProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RainETAEntry {
        RainETAEntry(date: .now,place: "Mi ubicación",response: nil,shouldRefresh: false)
    }
    func snapshot(for configuration: RainETAConfiguration, in context: Context) async -> RainETAEntry {
        await entry(for: configuration)
    }
    func timeline(for configuration: RainETAConfiguration, in context: Context) async -> Timeline<RainETAEntry> {
        let entry=await entry(for:configuration)
        var entries=[entry]
        if let target=entry.response?.targetDate(),target>entry.date,target<entry.date.addingTimeInterval(6*3600) {
            entries.append(RainETAEntry(date: target,place:entry.place,response:entry.response,shouldRefresh:true))
        }
        // WidgetKit, not the app, decides the actual refresh cadence.
        return Timeline(entries:entries,policy:.after(Date().addingTimeInterval(10*60)))
    }
    private func entry(for config: RainETAConfiguration) async -> RainETAEntry {
        var lat=config.latitude,lon=config.longitude
        var place="Lugar seleccionado"
        if config.currentLocation {
            let manager=CLLocationManager()
            if manager.isAuthorizedForWidgetUpdates,
               let location=manager.location,
               abs(location.timestamp.timeIntervalSinceNow)<30*60 {
                lat=location.coordinate.latitude
                lon=location.coordinate.longitude
                place="Mi ubicación"
            } else {
                place="Ubicación alternativa"
            }
        }
        guard lat.isFinite,lon.isFinite,abs(lat)<=90,abs(lon)<=180 else {
            return RainETAEntry(date:.now,place:place,response:nil,shouldRefresh:false)
        }
        // Configure RainETAAPIBaseURL on the extension target for the test preview.
        // Keep it disabled by default: do not silently query production before approval.
        let base=(Bundle.main.object(forInfoDictionaryKey:"RainETAAPIBaseURL") as? String) ?? ""
        guard base.hasPrefix("https://"),!base.contains("example.invalid"),
              var components=URLComponents(string:base+"/api/rain-widget") else {
            return RainETAEntry(date:.now,place:"Configura API de prueba",response:nil,shouldRefresh:false)
        }
        components.queryItems=[URLQueryItem(name:"lat",value:String(format:"%.3f",lat)),
                               URLQueryItem(name:"lon",value:String(format:"%.3f",lon))]
        guard let url=components.url else { return RainETAEntry(date:.now,place:place,response:nil,shouldRefresh:false) }
        do {
            var request=URLRequest(url:url)
            request.timeoutInterval=12
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200 else { throw URLError(.badServerResponse) }
            let value=try JSONDecoder().decode(RainETAResponse.self,from:data)
            return RainETAEntry(date:.now,place:place,response:value,shouldRefresh:false)
        }catch{
            return RainETAEntry(date:.now,place:place,response:nil,shouldRefresh:false)
        }
    }
}

struct RainETAWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RainETAEntry
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:5) {
                Image(systemName:"cloud.rain")
                Text("RainETA").fontWeight(.bold)
                Spacer(minLength:0)
            }.font(.caption)
            Text(entry.place).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            if entry.shouldRefresh {
                Text("Actualizando…").font(.headline)
            } else if let forecast=entry.response {
                let target=forecast.targetDate()
                if let target,target>entry.date,forecast.action != "none" {
                    Text(forecast.action == "starts" ? "Llueve en" : "Deja de llover en")
                        .font(.caption).lineLimit(1)
                    Text(target,style:.timer)
                        .font(family == .accessoryRectangular ? .headline : .system(size:36,weight:.bold,design:.rounded))
                        .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    Text("±\(forecast.precisionMinutes ?? 30) min · \(forecast.confidence == "media" ? "media" : "baja") confianza")
                        .font(.caption2).lineLimit(1)
                }else{
                    Text(forecast.phase == "raining" ? "Llueve ahora" : "Sin lluvia cercana")
                        .font(.headline).lineLimit(2)
                    Text(forecast.summary).font(.caption2).lineLimit(2)
                }
            }else{
                Text("Sin datos recientes").font(.headline)
                Text("Revisa ubicación o API").font(.caption2)
            }
            if family != .accessoryRectangular {
                Spacer(minLength:0)
                Text("Previsión, no aviso oficial").font(.system(size:9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .containerBackground(for:.widget){Color(red:0.05,green:0.13,blue:0.20)}
        .widgetURL(URL(string:"https://europapress-rss.vercel.app/rain/widget/"))
    }
}

struct RainETAWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind:"RainETAWidget",intent:RainETAConfiguration.self,provider:RainETAProvider()) { entry in
            RainETAWidgetView(entry:entry)
        }
        .configurationDisplayName("RainETA · Cuenta atrás")
        .description("Tiempo hasta que empiece o pare de llover.")
        .supportedFamilies([.systemSmall,.systemMedium,.accessoryRectangular])
    }
}

@main
struct RainETAWidgetBundle: WidgetBundle {
    var body: some Widget { RainETAWidget() }
}
