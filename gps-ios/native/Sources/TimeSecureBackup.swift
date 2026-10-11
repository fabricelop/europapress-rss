import Foundation
import CryptoKit
import CommonCrypto

enum TimeBackupError: LocalizedError {
    case passwordTooShort, incorrectPassword, invalidBackup, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .passwordTooShort: return "Usa una contraseña de al menos 10 caracteres; será necesaria para recuperar el mapa."
        case .incorrectPassword: return "Contraseña incorrecta o archivo alterado."
        case .invalidBackup: return "Esta copia no tiene el formato esperado."
        case .unsupportedVersion: return "La copia utiliza una versión aún no compatible."
        }
    }
}

struct TimeBackupContainer: Codable {
    var format: String
    var iterations: Int
    var salt: Data
    var sealed: Data
}

/// AES-256-GCM con PBKDF2-HMAC-SHA256; únicamente el archivo cifrado sale
/// del contenedor privado de la aplicación. Nunca se sube por red desde aquí.
enum TimeSecureBackup {
    static let format = "MiMapaDelTiempo-backup-v1"
    static let iterations = 220_000

    private static func key(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard password.count >= 10 else { throw TimeBackupError.passwordTooShort }
        guard salt.count == 24,iterations >= 150_000 && iterations <= 2_000_000 else {
            throw TimeBackupError.invalidBackup
        }
        var result=[UInt8](repeating:0,count:32)
        let status: Int32 = password.withCString { pwd in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                         pwd, password.utf8.count,
                         saltBytes.bindMemory(to:UInt8.self).baseAddress, salt.count,
                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                         UInt32(iterations),
                         output.bindMemory(to:UInt8.self).baseAddress, result.count)
                }
            }
        }
        guard status == kCCSuccess else { throw TimeBackupError.invalidBackup }
        return SymmetricKey(data:Data(result))
    }

    static func encrypt(_ state: SavedState, password:String) throws -> Data {
        var rng=SystemRandomNumberGenerator()
        let salt=Data((0..<24).map { _ in UInt8.random(in:0...255,using:&rng) })
        let symmetric=try key(password,salt:salt,iterations:iterations)
        let bytes=try JSONEncoder().encode(state)
        let sealed=try AES.GCM.seal(bytes,using:symmetric)
        guard let combined=sealed.combined else { throw TimeBackupError.invalidBackup }
        return try JSONEncoder().encode(TimeBackupContainer(format:format,
                    iterations:iterations,salt:salt,sealed:combined))
    }

    static func decrypt(_ bytes:Data,password:String) throws -> SavedState {
        guard let wrapper=try? JSONDecoder().decode(TimeBackupContainer.self,from:bytes) else {
            throw TimeBackupError.invalidBackup
        }
        guard wrapper.format == format else { throw TimeBackupError.unsupportedVersion }
        let key=try key(password,salt:wrapper.salt,iterations:wrapper.iterations)
        do {
            let box=try AES.GCM.SealedBox(combined:wrapper.sealed)
            let plain=try AES.GCM.open(box,using:key)
            let restored=try JSONDecoder().decode(SavedState.self,from:plain)
            guard restored.fixes.count < 2_000_000,
                  restored.intervals.count < 3_000_000,
                  restored.customZones.count < 10_000,
                  restored.fixes.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite &&
                        (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }),
                  restored.intervals.allSatisfy({ $0.start <= $0.end }) else {
                throw TimeBackupError.invalidBackup
            }
            return restored
        } catch {
            throw TimeBackupError.incorrectPassword
        }
    }
}
