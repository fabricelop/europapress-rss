import XCTest
@testable import MiMapaDelTiempo

@MainActor final class MapConnectivityTests: XCTestCase {
    func testBriefNetworkInterruptionDoesNotReplaceMap() async throws {
        let state = MapConnectivity(startMonitoring: false,
                                    outageDelay: 180_000_000,
                                    restoreDelay: 180_000_000)
        XCTAssertTrue(state.connected)
        state.networkChanged(false)
        try await Task.sleep(nanoseconds: 35_000_000)
        state.networkChanged(true)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(state.connected, "Un corte breve no debe ocultar MapKit")
    }

    func testSustainedOutageFallsBackAndRecoveryIsStable() async throws {
        let state = MapConnectivity(startMonitoring: false,
                                    outageDelay: 100_000_000,
                                    restoreDelay: 100_000_000)
        state.networkChanged(false)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(state.connected, "Un corte prolongado activa el mapa básico")
        state.networkChanged(true)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(state.connected, "La conexión estable restaura MapKit")
    }
}
