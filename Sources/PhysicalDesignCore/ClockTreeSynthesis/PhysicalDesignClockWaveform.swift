import Foundation

struct PhysicalDesignClockWaveform {
    typealias Point = PhysicalDesignClockTimingModel.Point
    static func validate(_ points: [Point], rising: Bool, horizon: Double) throws {
        guard points.count >= 2, points.first?.time == 0, let first = points.first, let last = points.last,
              last.time <= horizon, points.allSatisfy({ $0.time.isFinite && $0.voltage.isFinite && $0.time >= 0 }),
              rising ? first.voltage < last.voltage : first.voltage > last.voltage else { throw failure("PWL endpoints/units") }
        for (a, b) in zip(points, points.dropFirst()) {
            guard b.time > a.time, rising ? b.voltage >= a.voltage : b.voltage <= a.voltage else { throw failure("PWL monotonicity") }
        }
    }
    static func crossing(_ points: [Point], level: Double, rising: Bool) throws -> Double {
        var found: Double?
        for (a, b) in zip(points, points.dropFirst()) {
            if rising ? a.voltage < level && b.voltage >= level : a.voltage > level && b.voltage <= level {
                guard found == nil, b.voltage != a.voltage else { throw failure("ambiguous threshold crossing") }
                found = a.time + (b.time - a.time) * (level - a.voltage) / (b.voltage - a.voltage)
            }
        }
        guard let found, found.isFinite else { throw failure("threshold not reached within horizon") }
        return found
    }
    static func scaled(_ shape: [Point], rising: Bool, arrival: Double, slew: Double,
                       delayThreshold: Double, lower: Double, upper: Double, supply: Double, horizon: Double) throws -> [Point] {
        guard shape.first?.time == 0, shape.last?.time == 1,
              shape.first?.voltage == (rising ? 0 : 1), shape.last?.voltage == (rising ? 1 : 0) else { throw failure("normalized explicit driver shape") }
        let low = try crossing(shape, level: lower / 100, rising: rising)
        let high = try crossing(shape, level: upper / 100, rising: rising)
        let span = abs(high - low)
        guard span > 0, slew.isFinite, slew > 0 else { throw failure("driver shape transition") }
        let scale = slew / span
        let offset = arrival - (try crossing(shape, level: delayThreshold / 100, rising: rising)) * scale
        guard offset >= 0, offset.isFinite, offset + scale <= horizon else { throw failure("driver shape alignment/horizon") }
        var result = [Point(time: 0, voltage: rising ? 0 : supply)]
        for p in shape {
            let time = offset + p.time * scale
            if time == 0 { result[0].voltage = p.voltage * supply }
            else { result.append(Point(time: time, voltage: p.voltage * supply)) }
        }
        return result
    }
    static func failure(_ reason: String) -> PhysicalDesignClockTimingModelError { .invalidModel(reason) }
}
