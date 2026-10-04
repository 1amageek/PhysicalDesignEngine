import Foundation

struct PhysicalDesignRoutingSourceError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
