import Foundation
import CircuiteFoundation

public struct PhysicalDesignReference: Sendable, Hashable, Codable {
    public var layoutArtifact: ArtifactReference
    public var topCell: String
    public var layoutDigest: String

    public init(
        layoutArtifact: ArtifactReference,
        topCell: String,
        layoutDigest: String
    ) {
        self.layoutArtifact = layoutArtifact
        self.topCell = topCell
        self.layoutDigest = layoutDigest
    }

    public func validationDiagnostics() -> [String] {
        var diagnostics: [String] = []
        if topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("physical design top cell is empty")
        }
        if layoutDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append("physical design layout digest is empty")
        }
        if layoutArtifact.kind != .layout {
            diagnostics.append("physical design artifact kind must be layout")
        }
        if layoutArtifact.format != .json && layoutArtifact.format != .def {
            diagnostics.append("physical design reference format is unsupported by the native backend")
        }
        if layoutArtifact.digest.algorithm != .sha256
            || layoutArtifact.digest.hexadecimalValue.isEmpty {
            diagnostics.append("physical design artifact SHA-256 digest is missing")
        }
        if layoutArtifact.byteCount == 0 {
            diagnostics.append("physical design artifact byte count is missing or invalid")
        }
        if layoutArtifact.path.hasPrefix("/") {
            diagnostics.append("physical design artifact path must be project-relative")
        }
        return diagnostics
    }
}
