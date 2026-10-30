import SwiftUI

/// One-tap expandable audit of local editorial requests and their GitHub
/// receipts. Never labels optimistic changes as persisted.
struct PendingOperationsPanel: View {
    @EnvironmentObject private var store: EditorialStore
    @State private var expanded: Bool

    init(initiallyExpanded: Bool = false) {
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var background: Color {
        Color(red: 0.115, green: 0.178, blue: 0.275)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(TTTheme.muted)
                    Text("Aquí se cuentan solo órdenes pendientes de confirmar en GitHub. Los trabajos ya aceptados se consultan en En elaboración; el historial no aumenta este contador.")
                        .font(.system(size: 11))
                        .foregroundStyle(TTTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.outstandingOperations.isEmpty {
                    Label("No hay órdenes pendientes de confirmar.",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(TTTheme.teal)
                } else {
                    ForEach(store.outstandingOperations.prefix(15)) { operation in
                        operationRow(operation)
                        if operation.id != store.outstandingOperations.prefix(15).last?.id {
                            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
                        }
                    }
                }

                if !store.recentOperations.isEmpty {
                    Text("HISTORIAL · ÓRDENES REGISTRADAS")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.3).foregroundStyle(TTTheme.muted)
                    ForEach(store.recentOperations) { operation in
                        operationRow(operation)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await store.refresh(manual: true) }
                    } label: {
                        Label("Comprobar GitHub ahora", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .tint(TTTheme.teal)
                    .disabled(store.isLoading)

                    Spacer(minLength: 3)
                    if store.isLoading { ProgressView().tint(TTTheme.teal) }
                }
                .padding(.top, 4)
            }
            .padding(.top, 13)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.pendingOperationsCount > 0 ? .orange : TTTheme.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Órdenes por confirmar")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(store.outstandingOperations.isEmpty ?
                         "Ninguna orden sin confirmar · Ver historial" :
                         "Solicitudes aún sin comprobante de GitHub")
                        .font(.system(size: 10))
                        .foregroundStyle(TTTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 1)
                let count = store.outstandingOperations.count
                Text(String(count))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? Color.orange : TTTheme.teal)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .tint(TTTheme.muted)
        .padding(13)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(TTTheme.cardBorder, lineWidth: 1.5))
    }

    private func operationRow(_ operation: EditorialOperation) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol(for: operation.status))
                .font(.system(size: 15))
                .foregroundStyle(tint(for: operation.status))
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(operation.displayProject)
                    Text("·")
                    Text(operation.displayKind)
                }
                .font(.system(size: 10))
                .foregroundStyle(TTTheme.muted)
                if let detail = operation.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(TTTheme.muted)
                }
                HStack(spacing: 6) {
                    Text(operation.status)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint(for: operation.status))
                    Text("·")
                    Text(operation.createdAt, format: .dateTime.day().month().hour().minute())
                        .font(.system(size: 10).monospacedDigit())
                    if let requestID = operation.requestID {
                        Text("· " + String(requestID.suffix(8)))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
                .foregroundStyle(TTTheme.muted)
                if operation.status == "Sin confirmar" {
                    Text("No consta aún una confirmación. Comprueba GitHub antes de repetir la orden.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func symbol(for status: String) -> String {
        switch status {
        case "Confirmada", "En Listas", "Verificada", "Retirada": return "checkmark.circle.fill"
        case "Rechazada": return "xmark.octagon.fill"
        case "En elaboración": return "square.and.pencil"
        case "Sin confirmar": return "exclamationmark.triangle.fill"
        default: return "clock.fill"
        }
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "Confirmada", "En Listas", "Verificada", "Retirada": return TTTheme.teal
        case "Rechazada": return Color.red
        case "En elaboración": return TTTheme.blue
        default: return Color.orange
        }
    }
}
