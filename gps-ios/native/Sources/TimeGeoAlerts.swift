import SwiftUI
import UserNotifications
import Foundation

/// iOS suele silenciar las notificaciones en primer plano si falta este delegado.
final class GPSNotificationPresentationDelegate:NSObject,UNUserNotificationCenterDelegate {
    static let shared=GPSNotificationPresentationDelegate()
    func userNotificationCenter(_ center:UNUserNotificationCenter,
        willPresent notification:UNNotification,
        withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) {
        completionHandler([.banner,.list,.sound])
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,
        didReceive response:UNNotificationResponse,
        withCompletionHandler completionHandler:@escaping ()->Void) {
        if response.notification.request.identifier==GPSStaleWatchdogPolicy.identifier {
            UserDefaults.standard.set(true,forKey:"gpsWatchdogOpenHistory")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name:Notification.Name("gpsWatchdogOpenHistory"),
                    object:nil)
            }
        }
        completionHandler()
    }
}

/// Se limita a reaccionar a ubicaciones recibidas por el motor existente.
/// No crea un segundo CLLocationManager ni modifica la política de batería.
enum GeoAlertRules {
    static func zoneEntered(previous:String?,current:String?)->Bool {
        guard let previous,let current else { return false }
        return previous != current
    }
    static func stayReached(_ seconds:TimeInterval,minutes:Int)->Bool {
        minutes>0 && seconds>=Double(minutes)*60
    }
}

@MainActor final class GPSPersonalAlerts {
    static let shared=GPSPersonalAlerts()
    private let center=UNUserNotificationCenter.current()
    private init() { configure() }
    func configure() {
        center.delegate=GPSNotificationPresentationDelegate.shared
    }

    func evaluate(model:TimeModel,now:Date = .now) {
        let settings=UserDefaults.standard
        guard settings.bool(forKey:"gpsAlertsEnabled") else { return }
        let currentZone=model.activeCell.flatMap { model.primaryZone(for:$0) }
        let zoneID=currentZone?.id.uuidString
        let previous=settings.string(forKey:"gpsAlertsObservedZone")
        let observedID=zoneID ?? "none"
        // No repetir avisos ni modificar estado cuando seguimos sin zona.
        if previous != observedID {
            settings.set(observedID,forKey:"gpsAlertsObservedZone")
            settings.removeObject(forKey:"gpsAlertsStaySent")
            if let currentZone,let zoneID,
               GeoAlertRules.zoneEntered(previous:previous,current:zoneID),
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

    /// Programar con retraso, registrar el error de entrega y consultar iOS después.
    func testNotification(_ report:@escaping (String)->Void) {
        configure()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional ||
                  settings.authorizationStatus == .ephemeral else {
                Task { @MainActor in
                    report("iOS no ha autorizado las notificaciones: \(settings.authorizationStatus.rawValue).")
                }
                return
            }
            let identifier="miMapaTest-"+UUID().uuidString
            let message=UNMutableNotificationContent()
            message.title="Mi Mapa del Tiempo · prueba"
            message.body="Prueba local: iOS ha recibido esta notificación."
            message.sound = .default
            let request=UNNotificationRequest(identifier:identifier,content:message,
                trigger:UNTimeIntervalNotificationTrigger(timeInterval:5,repeats:false))
            self.center.add(request) { error in
                if let error {
                    Task { @MainActor in
                        report("iOS rechazó programar la notificación: \(error.localizedDescription)")
                    }
                } else {
                    Task { @MainActor in
                        report("Programada correctamente para dentro de 5 segundos. Bloquea el iPhone o revisa el Centro de notificaciones.")
                    }
                    Task {
                        try? await Task.sleep(for:.seconds(8))
                        self.center.getDeliveredNotifications { delivered in
                            let matched=delivered.contains { $0.request.identifier == identifier }
                            Task { @MainActor in
                                report(matched ?
                                  "iOS confirmó la notificación como entregada. Comprueba si ves la tira o el Centro de notificaciones." :
                                  "iOS aceptó la programación pero NO consta aún como entregada. Revisar Resumen programado, Modos de concentración y Ajustes de notificaciones.")
                            }
                        }
                    }
                }
            }
        }
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
    @State private var notificationTestStatus="Sin realizar prueba"
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
                Button("Enviar notificación de prueba (5 segundos)") {
                    notificationTestStatus="Solicitando programación a iOS…"
                    GPSPersonalAlerts.shared.testNotification { status in
                        notificationTestStatus=status
                    }
                }
                Text(notificationTestStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("La prueba informa de la aceptación por iOS y comprueba si consta como entregada. No demuestra que iOS vaya a detectar todas las entradas en segundo plano.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Avisos geográficos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            GPSPersonalAlerts.shared.configure()
            checkPermission()
        }
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
