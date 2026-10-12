import SwiftUI
import UserNotifications
import Foundation

/// Se limita a reaccionar a ubicaciones recibidas por el motor existente.
/// No crea un segundo CLLocationManager ni modifica la política de batería.
enum GeoAlertRules {
    static func zoneEntered(previous:String?,current:String?)->Bool {
        guard let previous,previous != "none",let current else { return false }
        return previous != current
    }
    static func stayReached(_ seconds:TimeInterval,minutes:Int)->Bool {
        minutes>0 && seconds>=Double(minutes)*60
    }
}

@MainActor final class GPSPersonalAlerts {
    static let shared=GPSPersonalAlerts()
    private let center=UNUserNotificationCenter.current()
    private init() {}

    func evaluate(model:TimeModel,now:Date = .now) {
        let settings=UserDefaults.standard
        guard settings.bool(forKey:"gpsAlertsEnabled") else { return }
        let currentZone=model.activeCell.flatMap { model.primaryZone(for:$0) }
        let zoneID=currentZone?.id.uuidString
        let previous=settings.string(forKey:"gpsAlertsObservedZone")
        // Guardar transición aun sin permiso para evitar repetir avisos antiguos.
        if previous != zoneID {
            settings.set(zoneID ?? "none",forKey:"gpsAlertsObservedZone")
            settings.removeObject(forKey:"gpsAlertsStaySent")
            if let currentZone, GeoAlertRules.zoneEntered(previous:previous,current:zoneID),
               eligible(zoneID,settings:settings),
               settings.bool(forKey:"gpsAlertsOnEnter") {
                notify(title:"Has entrado en \(currentZone.name)",
                       body:"Se ha detectado una nueva entrada en tu zona.")
            }
        }
        guard let currentZone,let zoneID,eligible(zoneID,settings:settings) else { return }
        let minutes=settings.integer(forKey:"gpsAlertsStayMinutes")
        let visitKey=zoneID+"|"+String(model.currentZoneVisitStart?.timeIntervalSince1970 ?? 0)+"|"+String(minutes)
        if minutes>0,settings.string(forKey:"gpsAlertsStaySent") != visitKey,
           GeoAlertRules.stayReached(model.zoneStaySeconds(for:currentZone,now:now),minutes:minutes) {
            settings.set(visitKey,forKey:"gpsAlertsStaySent")
            notify(title:"Estancia en \(currentZone.name)",
                   body:"Llevas al menos \(minutes) minutos en esta zona.")
        }
    }

    func discoveredCity(_ territory:TerritoryRecord,seenBefore:Bool) {
        guard !seenBefore,UserDefaults.standard.bool(forKey:"gpsAlertsEnabled"),
              UserDefaults.standard.bool(forKey:"gpsAlertsNewCity"),
              let city=territory.city?.trimmingCharacters(in:.whitespacesAndNewlines),
              !city.isEmpty else { return }
        notify(title:"Nueva ciudad descubierta",body:"Tu pasaporte geográfico incorpora \(city).")
    }

    private func eligible(_ id:String,settings:UserDefaults)->Bool {
        let selected=settings.string(forKey:"gpsAlertsZoneID") ?? "any"
        return selected == "any" || selected == id
    }

    func testNotification() {
        notify(title:"Prueba de Mi Mapa del Tiempo",
               body:"Los avisos locales están configurados en esta instalación.")
    }

    private func notify(title:String,body:String) {
        let content=UNMutableNotificationContent()
        content.title=title
        content.body=body
        content.sound = .default
        center.add(UNNotificationRequest(identifier:UUID().uuidString,
                                          content:content,trigger:nil))
    }
}

struct TimeGeoAlertsSettings:View {
    @ObservedObject var model:TimeModel
    @AppStorage("gpsAlertsEnabled") private var enabled=false
    @AppStorage("gpsAlertsOnEnter") private var onEnter=true
    @AppStorage("gpsAlertsNewCity") private var onCity=true
    @AppStorage("gpsAlertsZoneID") private var zoneID="any"
    @AppStorage("gpsAlertsStayMinutes") private var stayMinutes=60
    @State private var permission="Pendiente de comprobar"
    private var sortedZones:[TimeCustomZone] {
        model.visibleZones.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body:some View {
        Form {
            Section {
                Toggle("Activar avisos personales",isOn:$enabled)
                    .onChange(of:enabled) { _,value in
                        if value { requestPermission() }
                    }
                LabeledContent("Permiso de notificaciones",value:permission)
                Button("Solicitar permiso de iOS") { requestPermission() }
            } footer: {
                Text("Los avisos se envían al recibir posiciones GPS. iOS puede retrasar o suspender el seguimiento en segundo plano.")
            }
            Section("Zona") {
                Picker("Vigilar",selection:$zoneID) {
                    Text("Cualquier zona").tag("any")
                    ForEach(sortedZones) { zone in
                        Text(zone.name).tag(zone.id.uuidString)
                    }
                }
                Toggle("Avisar al entrar en zona",isOn:$onEnter)
                Picker("Avisar tras permanecer",selection:$stayMinutes) {
                    Text("Desactivado").tag(0)
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Text("1 hora").tag(60)
                    Text("2 horas").tag(120)
                    Text("3 horas").tag(180)
                }
            }.disabled(!enabled)
            Section("Descubrimientos") {
                Toggle("Avisar al descubrir una ciudad nueva",isOn:$onCity)
            }.disabled(!enabled)
            Section("Diagnóstico") {
                Button("Enviar notificación de prueba") {
                    GPSPersonalAlerts.shared.testNotification()
                }
                Text("Una notificación de prueba confirma la entrega local, no garantiza que todos los cambios de ubicación se detecten cuando iOS suspenda la app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Avisos geográficos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { checkPermission() }
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in
            DispatchQueue.main.async { checkPermission() }
        }
    }
    private func checkPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let title:String
            switch settings.authorizationStatus {
            case .authorized,.provisional,.ephemeral: title="Autorizado"
            case .denied: title="Denegado · revisar Ajustes iOS"
            case .notDetermined: title="No solicitado"
            @unknown default: title="Desconocido"
            }
            DispatchQueue.main.async { permission=title }
        }
    }
}
