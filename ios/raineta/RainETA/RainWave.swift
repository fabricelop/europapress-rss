import SwiftUI

/// Visual representation of an existing RainETA forecast. No new meteorological
/// inference is made here: the input rate, probability and timestamps are kept.
struct RainWavePoint: Identifiable {
    let minute: Int
    let rate: Double?
    var probability: Double? = nil       // 0...100%, only when the provider supplies it
    var snow: Bool = false
    var date: Date? = nil
    var id: Int { minute }
}

enum RainWaveSignal: String {
    case wet, possible, dry, unknown

    var title: String {
        switch self {
        case .wet: return "Precipitación prevista"
        case .possible: return "Posible precipitación"
        case .dry: return "Sin lluvia relevante"
        case .unknown: return "Sin datos suficientes"
        }
    }

    var color: Color {
        switch self {
        case .wet: return Color(red:0.18,green:0.65,blue:0.94)
        case .possible: return Color(red:0.69,green:0.52,blue:0.92)
        case .dry: return Color(red:0.20,green:0.48,blue:0.36)
        case .unknown: return Color.gray.opacity(0.25)
        }
    }
}

struct RainWaveSpan: Identifiable {
    let id: Int
    let signal: RainWaveSignal
    let first: Int
    let end: Int           // exclusive index
    let peak: Double
    var count: Int { end-first }
}

/// The same presentation threshold applies to all wave components.
/// A tiny nonzero model amount is not described as a confirmed rainy interval.
enum RainWaveForecast {
    static func signal(_ point:RainWavePoint)->RainWaveSignal {
        guard let value=point.rate, value.isFinite, value >= 0 else { return .unknown }
        let prob=point.probability.map { max(0,min(100,$0)) }
        if value>=0.15 && (prob.map {$0>=40} ?? true) {return .wet}
        if value>=0.03 || (prob ?? 0)>=30 {return .possible}
        return .dry
    }

    static func spans(_ points:[RainWavePoint])->[RainWaveSpan] {
        guard !points.isEmpty else {return []}
        var result:[RainWaveSpan]=[]
        let nominalStep=points.count>1 ? max(1,points[1].minute-points[0].minute) : 1
        for index in points.indices {
            let status=signal(points[index])
            let rate=max(0,points[index].rate ?? 0)
            if let previous=result.last,previous.signal==status,
               (index==0 || points[index].minute-points[index-1].minute==nominalStep) {
                result.removeLast()
                result.append(RainWaveSpan(id:previous.id,signal:status,first:previous.first,
                                           end:index+1,peak:max(previous.peak,rate)))
            } else {
                result.append(RainWaveSpan(id:index,signal:status,first:index,
                                           end:index+1,peak:rate))
            }
        }
        return result
    }

    static func peak(_ points:[RainWavePoint])->Double {
        points.filter {signal($0)==(.wet)}.compactMap(\.rate).max() ?? 0
    }

    static func firstRain(_ points:[RainWavePoint])->RainWaveSpan? {
        spans(points).first(where:{$0.signal == .wet})
    }

    static func fullyCovered(_ points:[RainWavePoint],expected:Int)->Bool {
        points.count==expected && points.allSatisfy {signal($0) != .unknown}
    }
}

// Display-only wave. The filled area is based on wet signal only; uncertain
// precipitation is marked purple near the baseline, never shown as a blue peak.
struct RainWavePlot: View {
    let points:[RainWavePoint]
    var height:CGFloat=142
    var selectedIndex:Int?=nil
    var onSelect:((Int)->Void)?=nil

    var body:some View {
        GeometryReader { geo in
            Canvas { context,size in
                let width=max(1,size.width),bottom=max(1,size.height-12)
                let maxRate=max(1.8,min(20,RainWaveForecast.peak(points)*1.12))
                let xStep=width/CGFloat(max(1,points.count-1))
                func x(_ i:Int)->CGFloat {CGFloat(i)*xStep}
                func y(_ rate:Double)->CGFloat {
                    let scale=sqrt(min(max(0,rate),maxRate)/maxRate)
                    return bottom-CGFloat(scale)*(bottom-12)
                }
                var grid=Path()
                grid.move(to:CGPoint(x:0,y:bottom))
                grid.addLine(to:CGPoint(x:width,y:bottom))
                context.stroke(grid,with:.color(.mint.opacity(0.38)),lineWidth:1)
                var halfway=Path()
                halfway.move(to:CGPoint(x:0,y:bottom/2))
                halfway.addLine(to:CGPoint(x:width,y:bottom/2))
                context.stroke(halfway,with:.color(.white.opacity(0.08)),
                               style:StrokeStyle(lineWidth:1,dash:[4,7]))

                // Never draw through unknown slots or turn possible rain into
                // the solid 'wet' silhouette.
                for span in RainWaveForecast.spans(points) {
                    if span.signal == .wet {
                        var line=Path()
                        var area=Path()
                        let first=span.first,last=span.end-1
                        let firstPoint=CGPoint(x:x(first),y:y(points[first].rate ?? 0))
                        line.move(to:firstPoint)
                        area.move(to:CGPoint(x:x(first),y:bottom))
                        area.addLine(to:firstPoint)
                        if last>first {
                            for i in (first+1)...last {
                                let next=CGPoint(x:x(i),y:y(points[i].rate ?? 0))
                                line.addLine(to:next)
                                area.addLine(to:next)
                            }
                        }
                        area.addLine(to:CGPoint(x:x(last),y:bottom))
                        area.closeSubpath()
                        context.fill(area,with:.linearGradient(
                            Gradient(colors:[Color.cyan.opacity(0.58),
                                             Color.blue.opacity(0.16),
                                             Color.cyan.opacity(0.035)]),
                            startPoint:CGPoint(x:0,y:8),
                            endPoint:CGPoint(x:0,y:bottom)))
                        context.stroke(line,with:.color(.cyan),
                                       style:StrokeStyle(lineWidth:3,lineCap:.round,
                                                         lineJoin:.round))
                    } else if span.signal == .possible {
                        let start=x(span.first)
                        let end=x(min(points.count-1,span.end))
                        let band=CGRect(x:start,y:bottom-8,width:max(3,end-start),height:7)
                        context.fill(Path(roundedRect:band,cornerRadius:2),
                                     with:.color(Color.purple.opacity(0.60)))
                    } else if span.signal == .unknown {
                        let rect=CGRect(x:x(span.first),y:bottom-5,
                            width:max(3,CGFloat(span.count)*xStep),height:5)
                        context.fill(Path(rect),with:.color(Color.gray.opacity(0.25)))
                    }
                }
                for (index,point) in points.enumerated() where point.snow &&
                    RainWaveForecast.signal(point)==(.wet) {
                    let center=CGPoint(x:x(index),y:y(point.rate ?? 0))
                    context.fill(Path(ellipseIn:CGRect(x:center.x-2,y:center.y-2,
                                                      width:4,height:4)),
                                 with:.color(.white))
                }
                if let selectedIndex,points.indices.contains(selectedIndex) {
                    let pos=x(selectedIndex)
                    var selected=Path()
                    selected.move(to:CGPoint(x:pos,y:5))
                    selected.addLine(to:CGPoint(x:pos,y:bottom))
                    context.stroke(selected,with:.color(.white.opacity(0.76)),
                                   style:StrokeStyle(lineWidth:1,dash:[3,4]))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onEnded { drag in
                guard !points.isEmpty,let onSelect else{return}
                let percent=max(0,min(1,drag.location.x/max(1,geo.size.width)))
                let index=min(points.count-1,max(0,Int((percent*CGFloat(max(0,points.count-1))).rounded())))
                onSelect(index)
            })
        }
        .frame(height:height)
        .background(
            LinearGradient(colors:[Color(red:0.045,green:0.15,blue:0.23),
                                   Color(red:0.025,green:0.07,blue:0.12)],
                           startPoint:.top,endPoint:.bottom),
            in:RoundedRectangle(cornerRadius:13))
        .overlay(RoundedRectangle(cornerRadius:13).stroke(.cyan.opacity(0.17)))
        .accessibilityLabel("Onda de intensidad de precipitación. Azul: prevista; violeta: posible; gris: sin datos.")
    }
}

struct RainWaveRibbon:View {
    let points:[RainWavePoint]
    var body:some View {
        GeometryReader { geo in
            HStack(spacing:0) {
                ForEach(RainWaveForecast.spans(points)) { span in
                    Rectangle().fill(span.signal.color)
                        .frame(width:geo.size.width*CGFloat(span.count)/CGFloat(max(1,points.count)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:5))
        }
        .frame(height:10)
        .accessibilityLabel("Franja de tramos de lluvia prevista, posible, seca o sin datos")
    }
}

struct RainWaveWindows:View {
    let points:[RainWavePoint]
    var stepMinutes:Int=5
    var limit:Int=4

    var body:some View {
        let spans=Array(RainWaveForecast.spans(points).prefix(limit))
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:7) {
                ForEach(spans) { span in
                    VStack(alignment:.leading,spacing:5) {
                        Text(span.signal.title)
                            .font(.system(size:11,weight:.semibold))
                            .foregroundStyle(span.signal == .unknown ? Color.secondary : Color.primary)
                        Text(timeText(span))
                            .font(.system(size:10,weight:.medium,design:.rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal,10).padding(.vertical,8)
                    .background(span.signal.color.opacity(0.14),
                                in:RoundedRectangle(cornerRadius:10))
                    .overlay(RoundedRectangle(cornerRadius:10)
                             .stroke(span.signal.color.opacity(0.32)))
                }
            }
        }
        .accessibilityLabel("Ventanas de lluvia y tiempo sin precipitación")
    }

    private func timeText(_ span:RainWaveSpan)->String {
        guard points.indices.contains(span.first),span.end>0,
              points.indices.contains(span.end-1) else{return "—"}
        let first=points[span.first]
        let last=points[span.end-1]
        if let start=first.date,let finish=last.date {
            let until=finish.addingTimeInterval(Double(stepMinutes*60))
            return start.formatted(date:.omitted,time:.shortened) + "–" +
                   until.formatted(date:.omitted,time:.shortened)
        }
        return "+\(first.minute)–+\(last.minute+stepMinutes) min"
    }
}

struct RainWaveLegend:View {
    var body:some View {
        HStack(spacing:11) {
            item("Lluvia",signal:.wet)
            item("Posible",signal:.possible)
            item("Seco",signal:.dry)
            item("Sin dato",signal:.unknown)
        }
        .font(.system(size:10))
        .foregroundStyle(.secondary)
    }
    private func item(_ title:String,signal:RainWaveSignal)->some View {
        HStack(spacing:4) {
            RoundedRectangle(cornerRadius:2)
                .fill(signal.color).frame(width:10,height:7)
            Text(title)
        }
    }
}
