import Foundation

/// Resúmenes pequeños (<4 KB serializados) calculados en la aplicación para
/// ActivityKit. No requieren compartir archivos con el proceso de la extensión.
enum TimeLiveVisualization {
    /// Matriz norte-arriba, oeste a la izquierda. Valor 0=sin tiempo, 1...4
    /// representa la intensidad relativa, sin inventar el tiempo de la casilla.
    static func neighborhood(center:Cell,totals:[String:TimeInterval])->[Int] {
        let cells=(0..<9).map { index in
            let row=center.row+1-index/3
            let col=center.column-1+index%3
            return Cell(row:row,column:col)
        }
        let values=cells.map { max(0,totals[$0.id] ?? 0) }
        let maximum=values.max() ?? 0
        guard maximum>0 else { return Array(repeating:0,count:9) }
        return values.map { $0<=0 ? 0 :
            min(4,max(1,Int(ceil(sqrt($0/maximum)*4))))
        }
    }

    /// Últimas seis ventanas de 60 minutos, ordenadas de antigua a reciente.
    /// Solo intervalos confirmados del historial; cada minuto se recorta a su
    /// propia ventana y ningún fragmento se cuenta en dos barras.
    static func hourlyPresence(intervals:[AssignedInterval],
                               cellIDs:Set<String>,
                               endingAt end:Date)->[Int] {
        guard !cellIDs.isEmpty else { return Array(repeating:0,count:6) }
        let start=end.addingTimeInterval(-6*3600)
        let pieces=TimeAttribution.canonical(intervals.filter {
            $0.end>start && $0.start<end
        })
        var result=[TimeInterval](repeating:0,count:6)
        for piece in pieces where cellIDs.contains(piece.cell.id) {
            for i in 0..<6 {
                let lower=start.addingTimeInterval(TimeInterval(i*3600))
                let upper=lower.addingTimeInterval(3600)
                let overlap=max(0,min(piece.end,upper).timeIntervalSince(max(piece.start,lower)))
                result[i] += overlap
            }
        }
        return result.map { min(100,max(0,Int((min(3600,$0)/36).rounded()))) }
    }
}
