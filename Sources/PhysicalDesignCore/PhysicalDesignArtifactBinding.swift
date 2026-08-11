import CircuiteFoundation
import Foundation

public enum PhysicalDesignArtifactBindingError: Error, Sendable, Equatable {
    case emptyLogicalID
    case availabilityIdentityMismatch
    case missingBinding(ArtifactID)
    case localAvailabilityRequired(String)
}

public struct PhysicalDesignArtifactBinding: Sendable, Hashable, Codable {
    public let logicalID: String
    public let reference: ArtifactReference
    public let availability: ArtifactAvailability

    public init(
        logicalID: String,
        reference: ArtifactReference,
        availability: ArtifactAvailability
    ) throws {
        guard !logicalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhysicalDesignArtifactBindingError.emptyLogicalID
        }
        guard availability.artifactID == reference.id else {
            throw PhysicalDesignArtifactBindingError.availabilityIdentityMismatch
        }
        self.logicalID = logicalID
        self.reference = reference
        self.availability = availability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalID: container.decode(String.self, forKey: .logicalID),
            reference: container.decode(ArtifactReference.self, forKey: .reference),
            availability: container.decode(ArtifactAvailability.self, forKey: .availability)
        )
    }

    public var descriptor: ArtifactDescriptor { reference.descriptor }
    public var path: String {
        switch availability {
        case .local(_, _, let relativePath):
            relativePath.stringValue
        case .service(_, let resource):
            String(describing: resource)
        }
    }

    public func requireLocalRelativePath() throws -> ArtifactRelativePath {
        guard case .local(_, _, let relativePath) = availability else {
            throw PhysicalDesignArtifactBindingError.localAvailabilityRequired(logicalID)
        }
        return relativePath
    }

    public static func require(
        _ reference: ArtifactReference,
        in bindings: [PhysicalDesignArtifactBinding]
    ) throws -> PhysicalDesignArtifactBinding {
        guard let binding = bindings.first(where: { $0.reference == reference }) else {
            throw PhysicalDesignArtifactBindingError.missingBinding(reference.id)
        }
        return binding
    }
}
