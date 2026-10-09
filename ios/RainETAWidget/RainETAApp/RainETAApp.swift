import SwiftUI
import CoreLocation

@main
struct RainETAApp: App {
    @StateObject private var location = RainLocationPermission()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 18) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 62)).foregroundStyle(.blue)
                Text("RainETA").font(.largeTitle.bold())
                Text("Cuenta atrás para saber cuándo empieza o termina la lluvia.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Autorizar ubicación actual") { location.request() }
                    .buttonStyle(.borderedProminent)
                Text(location.message).font(.footnote).multilineTextAlignment(.center)
                Text("Después, añade el widget RainETA a la pantalla de inicio o de bloqueo. También puedes editar el widget para utilizar coordenadas fijas.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link("Abrir RainETA web", destination: URL(string: "https://europapress-rss.vercel.app/rain/")!)
            }
            .padding(24)
        }
    }
}

final class RainLocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var message = "Ubicación sin solicitar"
    override init() { super.init(); manager.delegate = self }
    func request() {
        manager.requestWhenInUseAuthorization()
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            message = "Ubicación autorizada. Activa también el acceso del widget cuando iOS lo solicite."
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied {
            message = "Sin permiso. Puedes usar coordenadas fijas al editar el widget."
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        message = "Ubicación disponible. El widget actualizará la posición cuando iOS permita una consulta."
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Ubicación temporalmente no disponible. Puedes usar coordenadas fijas."
    }
}
