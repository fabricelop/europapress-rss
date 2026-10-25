import SwiftUI

/// An immediately readable location clock for a selected calendar day.
/// Four six-hour strips retain the familiar 24-hour scale without reducing
/// short visits to barely visible slivers on a circular dial.
private struct SiteClockTotal: Identifiable {
    let id: UUID
    let seconds: TimeInterval
}

struct TimeSiteDailyClockView: View {
    @ObservedObject var model: TimeModel
    let day: Date
    let stays: [SiteGridStay]
    @State private var focused: SiteClockSegment?

    private var slices: [SiteClockSegment] {
        let parts=Dictionary(uniqueKeysWithValues:stays.map {
            ($0.id,model.siteParts(for:$0))
        })
        return SiteDailyClock.segments(stays:stays,partsByStay:parts,on:day)
    }
    private var siteTotals: [SiteClockTotal] {
        SiteDailyClock.totalsBySite(slices)
            .map{SiteClockTotal(id:$0.key,seconds:$0.value)}
            .sorted{$0.seconds>$1.seconds}
    }
    private var measuredSeconds:TimeInterval {
        slices.reduce(0){$0+$1.seconds}
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Reloj de lugares",systemImage:"clock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("24 h")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Cada color es un lugar. Toca cualquier tramo para ver su hora y abrir el detalle.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(SiteDailyClock.bands(slices,day:day).enumerated()),
                    id:\.offset) { item in
                let band=item.element
                HStack(spacing:6) {
                    Text(band.label)
                        .font(.system(size:10,weight:.medium,design:.monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width:36)
                    GeometryReader { geometry in
                        let width=geometry.size.width
                        let duration=band.to.timeIntervalSince(band.from)
                        ZStack(alignment:.leading) {
                            RoundedRectangle(cornerRadius:3)
                                .fill(Color.secondary.opacity(0.13))
                            ForEach(band.segments) { part in
                                let begins=max(part.from,band.from)
                                let ends=min(part.to,band.to)
                                let start=begins.timeIntervalSince(band.from)/duration
                                let length=ends.timeIntervalSince(begins)/duration
                                if length>0 {
                                    Rectangle()
                                        .fill(shade(for:part))
                                        .frame(width:max(1,width*length),height:25)
                                        .offset(x:width*start)
                                        .onTapGesture { focused=part }
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius:3))
                    }
                    .frame(height:25)
                    Text(band.endLabel)
                        .font(.system(size:10,weight:.medium,design:.monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width:36)
                }
                .accessibilityElement(children:.contain)
                .accessibilityLabel("Desde \(band.label) hasta \(band.endLabel)")
            }

            HStack(spacing:12) {
                legendDot("De paso",color:.gray)
                legendDot("Sin identificar",color:.orange)
            }
            Text("Espacio sin color: no hay mediciones GPS. No se asignan lugares durante esos huecos.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !siteTotals.isEmpty {
                VStack(alignment:.leading,spacing:7) {
                    Text("Lugares de este día")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(siteTotals.prefix(9))) { entry in
                        HStack(spacing:8) {
                            Circle()
                                .fill(siteColor(entry.id))
                                .frame(width:10,height:10)
                            Text(model.siteNamed(entry.id)?.name ?? "Sitio")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength:4)
                            Text(DurationFormat.full(entry.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if siteTotals.count>9 {
                        Text("Y \(siteTotals.count-9) lugares más; puedes tocarlos en el reloj.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let focused {
                Divider()
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text(name(for:focused))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            self.focused=nil
                        } label: {
                            Image(systemName:"xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    Text("\(focused.from.formatted(date:.omitted,time:.shortened)) – \(focused.to.formatted(date:.omitted,time:.shortened)) · \(DurationFormat.full(focused.seconds))")
                        .font(.caption.monospacedDigit())
                    Text(focused.kind == .place ?
                         (focused.manuallyConfirmed ? "Confirmado por ti" : "Propuesta automática") :
                         focused.kind == .passing ? "De paso" : "Sin identificar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        TimeSiteStayEditor(model:model,stay:focused.stay)
                    } label: {
                        Label("Ver estancia, mapa o corregir sitio",
                              systemImage:"map")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.075),
                            in:RoundedRectangle(cornerRadius:10))
            }
            HStack {
                Text("Tiempo GPS representado")
                Spacer()
                Text(DurationFormat.full(measuredSeconds))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical,5)
        .onChange(of:day) { _,_ in focused=nil }
    }

    @ViewBuilder private func legendDot(_ label:String,color:Color) -> some View {
        HStack(spacing:4) {
            Circle().fill(color).frame(width:7,height:7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func name(for segment:SiteClockSegment) -> String {
        switch segment.kind {
        case .passing: return "De paso"
        case .unassigned: return "Sin identificar"
        case .place:
            return segment.siteID.flatMap { model.siteNamed($0)?.name } ?? "Sin identificar"
        }
    }

    private func shade(for segment:SiteClockSegment) -> Color {
        if segment.kind == .passing { return .gray }
        if segment.kind == .unassigned { return .orange }
        return segment.siteID.map(siteColor) ?? .orange
    }

    /// Stable across launches, unlike Swift's randomized hashValue.
    private func siteColor(_ id:UUID) -> Color {
        let bytes=Array(id.uuidString.utf8)
        let code=bytes.enumerated().reduce(0) { value,part in
            (value*31+Int(part.element)+part.offset) % 65521
        }
        return Color(hue:Double(code%360)/360,
                     saturation:0.62,brightness:0.78)
    }
}
