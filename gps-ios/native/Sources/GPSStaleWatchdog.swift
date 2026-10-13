import Foundation
import SwiftUI
import UserNotifications

/// No ejecuta un temporizador en segundo plano: iOS conserva una notificación
/// local programada. Cada posición GPS nueva renueva su vencimiento.
enum GPSStaleWatchdogPolicy {
    static let identifier = "mimapa-gps-no-updates-v1"
    static let minimumRearmSeconds:TimeInterval = 45
    static let maximumFreshFixAge:TimeInterval = 120

    static func shouldRenew(enabled:Bool,tracking:Bool,resting:Bool,
                            fix:Date,now:Date,lastArmed:Date?,
                            intervalMinutes:Int)->Bool {
        guard enabled && tracking && !resting && intervalMinutes>0 else { return false }
        let age=now.timeIntervalSince(fix)
        guard age>=0 && age<=maximumFreshFixAge else { return false }
        return lastArmed.map { now.timeIntervalSince($0)>=minimumRearmSeconds } ?? true
    }
}

@MainActor final class GPSStaleWatchdog {
    static let shared=GPSStaleWatchdog()
    private let center=UNUserNotificationCenter.current()
    private var lastArmed:Date?
    private var active=false
    private init() {}

    private var enabled:Bool {
        UserDefaults.standard.object(forKey:"gpsWatchdogEnabled") as? Bool ?? true
    }
    private var minutes:Int {
        let value=UserDefaults.standard.integer(forKey:"gpsWatchdogMinutes")
        return [10,15,30].contains(value) ? value : 15
    }

    func requestPermissionIfNeeded() {
        guard enabled else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in }
        }
    }

    func begin(now:Date = .now) {
        active=true
        requestPermissionIfNeeded()
        arm(now:now,force:true)
    }

    func received(_ fixDate:Date,now:Date = .now) {
        guard GPSStaleWatchdogPolicy.shouldRenew(enabled:enabled,tracking:active,
            resting:false,fix:fixDate,now:now,lastArmed:lastArmed,
            intervalMinutes:minutes) else { return }
        arm(now:now,force:true)
    }

    func refresh(recording:Bool,resting:Bool,latestFix:Date?,now:Date = .now) {
        guard recording && !resting && enabled else {
            cancel()
            return
        }
        active=true
        requestPermissionIfNeeded()
        if let latestFix, GPSStaleWatchdogPolicy.shouldRenew(enabled:enabled,
            tracking:true,resting:false,fix:latestFix,now:now,lastArmed:lastArmed,
            intervalMinutes:minutes) {
            arm(now:now,force:true)
        } else if lastArmed == nil {
            // Si la app se reabrió y la última posición es vieja, no marcar
            // una posición antigua como nueva. Dar tiempo al GPS a recuperarse.
            arm(now:now,force:true)
        }
    }

    func cancel() {
        active=false
        lastArmed=nil
        center.removePendingNotificationRequests(withIdentifiers:[GPSStaleWatchdogPolicy.identifier])
        center.removeDeliveredNotifications(withIdentifiers:[GPSStaleWatchdogPolicy.identifier])
    }

    func settingsChanged(recording:Bool,resting:Bool,lastFix:Date?) {
        cancel()
        refresh(recording:recording,resting:resting,latestFix:lastFix)
    }

    private func arm(now:Date,force:Bool) {
        guard active && enabled else { cancel(); return }
        if !force,let lastArmed,
           now.timeIntervalSince(lastArmed)<GPSStaleWatchdogPolicy.minimumRearmSeconds {
            return
        }
        lastArmed=now
        center.removePendingNotificationRequests(withIdentifiers:[GPSStaleWatchdogPolicy.identifier])
        center.removeDeliveredNotifications(withIdentifiers:[GPSStaleWatchdogPolicy.identifier])
        let message=UNMutableNotificationContent()
        message.title="Mi Mapa del Tiempo · GPS sin actualizar"
        message.body="Llevamos unos \(minutes) minutos sin recibir nuevas posiciones. Abre la aplicación para comprobar el seguimiento."
        message.sound = .default
        message.userInfo=["gpsIssue":"staleUpdates"]
        let request=UNNotificationRequest(identifier:GPSStaleWatchdogPolicy.identifier,
            content:message,
            trigger:UNTimeIntervalNotificationTrigger(
                timeInterval:TimeInterval(minutes*60),repeats:false))
        center.add(request) { error in
            if let error {
                print("GPS watchdog: aviso no programado: \(error.localizedDescription)")
            }
        }
    }
}

struct GPSStaleWatchdogSettings:View {
    @ObservedObject var model:TimeModel
    @AppStorage("gpsWatchdogEnabled") private var enabled=true
    @AppStorage("gpsWatchdogMinutes") private var minutes=15
    @State private var permission="Comprobando…"
    var body:some View {
        Section("Aviso si el GPS deja de actualizarse") {
            Toggle("Avisarme cuando no lleguen posiciones",isOn:$enabled)
                .onChange(of:enabled) { _,_ in refresh() }
            Picker("Avisar después de",selection:$minutes) {
                Text("10 minutos").tag(10)
                Text("15 minutos").tag(15)
                Text("30 minutos").tag(30)
            }.disabled(!enabled)
             .onChange(of:minutes) { _,_ in refresh() }
            LabeledContent("Notificaciones",value:permission)
            Button("Solicitar permiso para los avisos") {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in
                        checkPermission()
                    }
            }
            Text("iOS mostrará una notificación local si deja de recibir posiciones GPS durante el plazo elegido, incluso si la app está suspendida. No garantiza que el GPS se haya detenido: también puede ocurrir estando inmóvil. Nunca avisará durante una pausa voluntaria.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { checkPermission() }
    }
    private func refresh() {
        GPSStaleWatchdog.shared.settingsChanged(
            recording:model.recording,resting:model.isResting,
            lastFix:model.current?.date)
        checkPermission()
    }
    private func checkPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let value:String
            switch s.authorizationStatus {
            case .authorized,.provisional,.ephemeral:value="Autorizadas"
            case .denied:value="Denegadas en Ajustes del iPhone"
            case .notDetermined:value="Pendientes de autorizar"
            @unknown default:value="Estado desconocido"
            }
            DispatchQueue.main.async { permission=value }
        }
    }
}
