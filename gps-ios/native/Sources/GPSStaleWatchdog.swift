import Foundation
import SwiftUI
import UserNotifications

/// No ejecuta un temporizador en segundo plano: iOS conserva una notificación
/// local programada. Cada posición GPS nueva renueva su vencimiento.
enum GPSStaleWatchdogPolicy {
    static let identifier = "mimapa-gps-no-updates-v1"
    static let minimumRearmSeconds:TimeInterval = 45
    static let maximumFreshFixAge:TimeInterval = 120
    static let requiredRecoverySeconds:TimeInterval = 180
    static let maximumRecoveryFixSpacing:TimeInterval = 120

    static func isFresh(_ fix:Date,at now:Date)->Bool {
        let age=now.timeIntervalSince(fix)
        return age>=0 && age<=maximumFreshFixAge
    }
    static func deadlinePassed(armedAt:Date?,now:Date,minutes:Int)->Bool {
        guard let armedAt else { return false }
        return now.timeIntervalSince(armedAt)>=TimeInterval(minutes*60)
    }
    static func recoveryConfirmed(first:Date?,previous:Date?,
                                  latest:Date)->Bool {
        guard let first,let previous,
              latest.timeIntervalSince(previous)>=0,
              latest.timeIntervalSince(previous)<=maximumRecoveryFixSpacing
        else { return false }
        return latest.timeIntervalSince(first)>=requiredRecoverySeconds
    }

    static func shouldRenew(enabled:Bool,tracking:Bool,resting:Bool,
                            fix:Date,now:Date,lastArmed:Date?,
                            intervalMinutes:Int)->Bool {
        guard enabled && tracking && !resting && intervalMinutes>0 else { return false }
        guard isFresh(fix,at:now) else { return false }
        return lastArmed.map { now.timeIntervalSince($0)>=minimumRearmSeconds } ?? true
    }
}

@MainActor final class GPSStaleWatchdog {
    static let shared=GPSStaleWatchdog()
    private let center=UNUserNotificationCenter.current()
    private var lastArmed:Date?
    private var active=false
    // No volver a alertar tras una sola lectura aislada cada 15-30 min.
    // Exigir 3 minutos de actualizaciones válidas y continuadas.
    private var awaitingSustainedRecovery=false
    private var recoveryFirstAt:Date?
    private var recoveryLastAt:Date?
    private let savedArmKey="gpsWatchdogLastArmedAt"
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
        GPSPersonalAlerts.shared.configure()
        requestPermissionIfNeeded()
        // Al volver del segundo plano o reiniciar la app, recordar si ya
        // venció un aviso anterior y NO dispararlo repetidamente de noche.
        if lastArmed==nil {
            lastArmed=UserDefaults.standard.object(forKey:savedArmKey) as? Date
        }
        if GPSStaleWatchdogPolicy.deadlinePassed(
            armedAt:lastArmed,now:now,minutes:minutes) {
            startRecoveryWait()
        } else if lastArmed==nil && !awaitingSustainedRecovery {
            arm(now:now,force:true)
        }
    }

    func received(_ fixDate:Date,now:Date = .now) {
        guard enabled && active && GPSStaleWatchdogPolicy.isFresh(fixDate,at:now)
            else { return }
        if GPSStaleWatchdogPolicy.deadlinePassed(
            armedAt:lastArmed,now:now,minutes:minutes) {
            startRecoveryWait()
        }
        if awaitingSustainedRecovery {
            if let previous=recoveryLastAt,
               now.timeIntervalSince(previous)>
                GPSStaleWatchdogPolicy.maximumRecoveryFixSpacing {
                recoveryFirstAt=now
            }
            if recoveryFirstAt==nil { recoveryFirstAt=now }
            let confirmed=GPSStaleWatchdogPolicy.recoveryConfirmed(
                first:recoveryFirstAt,previous:recoveryLastAt,latest:now)
            recoveryLastAt=now
            if confirmed {
                awaitingSustainedRecovery=false
                recoveryFirstAt=nil
                recoveryLastAt=nil
                arm(now:now,force:true)
            }
            return
        }
        guard GPSStaleWatchdogPolicy.shouldRenew(
            enabled:enabled,tracking:active,resting:false,
            fix:fixDate,now:now,lastArmed:lastArmed,
            intervalMinutes:minutes) else { return }
        arm(now:now,force:true)
    }

    func refresh(recording:Bool,resting:Bool,latestFix:Date?,now:Date = .now) {
        guard recording && !resting && enabled else { cancel(); return }
        active=true
        requestPermissionIfNeeded()
        if lastArmed==nil {
            lastArmed=UserDefaults.standard.object(forKey:savedArmKey) as? Date
        }
        if GPSStaleWatchdogPolicy.deadlinePassed(
            armedAt:lastArmed,now:now,minutes:minutes) {
            startRecoveryWait()
        }
        guard !awaitingSustainedRecovery else { return }
        if let latestFix, GPSStaleWatchdogPolicy.shouldRenew(
            enabled:enabled,tracking:true,resting:false,fix:latestFix,
            now:now,lastArmed:lastArmed,intervalMinutes:minutes) {
            arm(now:now,force:true)
        } else if lastArmed==nil {
            // El plazo inicial permite al GPS obtener una nueva lectura.
            arm(now:now,force:true)
        }
    }

    private func startRecoveryWait() {
        awaitingSustainedRecovery=true
        recoveryFirstAt=nil
        recoveryLastAt=nil
        lastArmed=nil
        UserDefaults.standard.removeObject(forKey:savedArmKey)
        center.removePendingNotificationRequests(
            withIdentifiers:[GPSStaleWatchdogPolicy.identifier])
        // No borrar el aviso entregado hasta que el GPS se recupere.
    }

    func cancel() {
        active=false
        lastArmed=nil
        awaitingSustainedRecovery=false
        recoveryFirstAt=nil
        recoveryLastAt=nil
        UserDefaults.standard.removeObject(forKey:savedArmKey)
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
        UserDefaults.standard.set(now,forKey:savedArmKey)
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
