import Foundation
import Testing
import CircuiteFoundation
@testable import PhysicalDesignCore

@Suite("PhysicalDesignEngine mask-data adapter boundary")
struct MaskDataAdapterTests {
    private struct FixtureAdapter: PhysicalDesignMaskDataAdapter {
        let supportedFormat: ArtifactFormat = .gdsii
        let implementationID = "fixture-mask-adapter"
        let qualification: PhysicalDesignMaskDataAdapterQualification = .unqualified

        func export(_ snapshot: PhysicalDesignSnapshot) async throws -> Data {
            Data(snapshot.topCell.utf8)
        }
    }

    @Test("unqualified external mask adapter is rejected")
    func unqualifiedAdapterIsRejected() async throws {
        do {
            _ = try await PhysicalDesignMaskDataAdapterGate().export(
                PhysicalDesignSnapshot.empty(topCell: "top"),
                format: .gdsii,
                adapter: FixtureAdapter()
            )
            Issue.record("an unqualified mask adapter must be rejected")
        } catch let error as PhysicalDesignMaskDataAdapterError {
            #expect(error == .adapterUnqualified("fixture-mask-adapter"))
        } catch {
            Issue.record("unexpected adapter gate error: \(error)")
        }
    }
}
