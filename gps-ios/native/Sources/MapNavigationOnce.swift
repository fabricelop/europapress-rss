import Foundation

/// Navegación de un solo uso: cambiar de pestaña no puede repetir el destino.
struct MapNavigationOnce {
    private(set) var pending: Cell?

    mutating func enqueue(_ cell: Cell) {
        pending = cell
    }

    mutating func consume() -> Cell? {
        let cell = pending
        pending = nil
        return cell
    }
}
