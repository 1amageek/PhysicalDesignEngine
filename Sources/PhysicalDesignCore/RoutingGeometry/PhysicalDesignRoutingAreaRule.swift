struct PhysicalDesignRoutingAreaRule: Sendable {
    let minimumDBU2: UInt64

    init(areaMicronsSquared: Double, unitsPerMicron: Int) throws {
        guard areaMicronsSquared.isFinite, areaMicronsSquared >= 0,
              unitsPerMicron > 0, unitsPerMicron < 9_007_199_254_740_992 else {
            throw PhysicalDesignTechnologyError.invalid("AREA requires finite nonnegative square microns and positive exact database units.")
        }
        let units = Double(unitsPerMicron)
        let scaled = areaMicronsSquared * units * units
        let rounded = scaled.rounded()
        guard scaled.isFinite, areaMicronsSquared == 0 || rounded > 0, scaled < 9_007_199_254_740_992,
              abs(rounded - scaled) <= scaled.ulp, let exact = UInt64(exactly: rounded) else {
            throw PhysicalDesignTechnologyError.invalid("AREA cannot be represented as an exact integer DBU-squared threshold.")
        }
        minimumDBU2 = exact
    }

    func accepts(_ areaDBU2: UInt64) -> Bool { areaDBU2 >= minimumDBU2 }
}
