import Foundation
import LocalAuthentication

/// El acceso a la UI se bloquea de forma independiente del servicio Core Location.
/// Siempre permite el código del dispositivo como alternativa si iOS lo ofrece.
enum DeviceAccess {
    static func authenticate(_ completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Proteger el historial personal de Mi Mapa del Tiempo") { authorized, _ in
            DispatchQueue.main.async { completion(authorized) }
        }
    }
}
