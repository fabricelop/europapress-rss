import Foundation

/// Visual eight-way compass only. The simulation still uses the original
/// four cardinal directions for migration and territorial mechanics.
enum BioGridNeighborhood {
    /// 0 N, 1 S, 2 E, 3 O, 4 NO, 5 NE, 6 SO, 7 SE.
    static func cell(near origin:Cell,direction:Int)->Cell {
        switch direction {
        case 0...3: return BioGridEngine.neighbor(origin,direction:direction)
        case 4,5:
            let north=BioGridEngine.neighbor(origin,direction:0)
            return Cell(row:north.row,column:north.column+(direction == 4 ? -1 : 1))
        case 6,7:
            let south=BioGridEngine.neighbor(origin,direction:1)
            return Cell(row:south.row,column:south.column+(direction == 6 ? -1 : 1))
        default: return origin
        }
    }
}
