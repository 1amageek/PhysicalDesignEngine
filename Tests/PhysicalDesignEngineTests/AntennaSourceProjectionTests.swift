import CircuiteFoundation
import Foundation
import LEF
import PDKCore
import Testing
@testable import PhysicalDesignCore

@Suite("Source-bound antenna projection", .timeLimit(.minutes(1)))
struct AntennaSourceProjectionTests {
    @Test func retainsRawAbsenceExplicitZeroAndSourceOrder() async throws {
        let (inputs, request) = try await fixture()
        let projection = try project(inputs, request)
        #expect(inputs.hasSourceAntennaLaws && inputs.requiresSourceGeometry)
        let technologyOnly = PhysicalDesignProcessInputs(manifest: inputs.manifest,
            technologyViews: inputs.technologyViews, cellViews: [:])
        #expect(technologyOnly.hasSourceAntennaLaws && technologyOnly.requiresSourceGeometry)
        #expect(projection.layers.map(\.sourceName) == ["metH", "cutHV", "metV"])
        #expect(projection.layers.map(\.fabricationRank) == [0, 1, 2])
        let gate = try #require(projection.terminals.first { $0.pinName == "A" })
        let output = try #require(projection.terminals.first { $0.pinName == "Y" })
        #expect(gate.rawGateAreaSquareMicrons == 0.126 && gate.gateCoverage == .reportedPositive)
        #expect(gate.rawDiffusionAreaSquareMicrons == nil && gate.reportedDiffusionAreaSquareMicrons == 0)
        #expect(gate.diffusionOrigin == .omittedUnqualifiedZero)
        #expect(output.rawDiffusionAreaSquareMicrons == 0 && output.reportedDiffusionAreaSquareMicrons == 0)
        #expect(output.diffusionOrigin == .explicit)
        #expect(gate.source == request.processAssets["cells"]?.reference)
        #expect(projection.manifestReference == request.pdk.manifest)
    }

    @Test func retainsLastLawAndPWLDomainWithoutEvaluatingIt() async throws {
        let (inputs, request) = try await fixture(law:
            "ANTENNAMODEL OXIDE1 ; ANTENNADIFFAREARATIO 2 ; ANTENNADIFFAREARATIO PWL ((0 3)(22.5 408)) ;")
        let projection = try project(inputs, request)
        let law = try #require(projection.laws.first)
        #expect(projection.laws.count == 1 && law.sourceStatementIndex == 2 && law.explicitOxide1)
        #expect(law.basis == .surface)
        guard case .piecewiseLinear(let points) = law.ratio else { Issue.record("Expected retained PWL law"); return }
        #expect(points.map(\.diffusionAreaSquareMicrons) == [0, 22.5])
        #expect(points.map(\.ratio) == [3, 408])
        #expect(law.source == request.processAssets["tech"]?.reference)
    }

    @Test func missingGateRemainsUnknownCoverageAndZeroThresholdIsRetained() async throws {
        let (inputs, request) = try await fixture(law: "ANTENNADIFFAREARATIO 0 ;", gate: false)
        let projection = try project(inputs, request)
        let gate = try #require(projection.terminals.first { $0.pinName == "A" })
        #expect(gate.rawGateAreaSquareMicrons == nil && gate.gateCoverage == .missingRequiredGate)
        guard case .scalar(let value) = try #require(projection.laws.first).ratio else { Issue.record("Expected scalar law"); return }
        #expect(value == 0)
    }

    @Test(arguments: ["side", "cut"])
    func sourceAreaBasisAndThicknessRemainExplicit(scenario: String) async throws {
        let (inputs, request) = try await fixture(scenario: scenario)
        let projection = try project(inputs, request)
        if scenario == "side" {
            let law = try #require(projection.laws.first)
            #expect(law.basis == .sidewall && law.thicknessMicrons == 0.1)
        } else {
            let law = try #require(projection.laws.first { $0.sourceName == "cutHV" })
            #expect(law.basis == .cutArea && law.thicknessMicrons == nil && law.fabricationRank == 1)
        }
    }

    @Test(arguments: ["oxide", "sidewall", "unmapped", "pin-model", "direction", "cell-law"])
    func refusesUnsupportedCoverage(scenario: String) async throws {
        do {
            _ = try await fixture(scenario: scenario)
            Issue.record("Unsupported antenna source profile was admitted")
        } catch PhysicalDesignTechnologyError.unsupported { }
    }

    @Test func exactQuotaAndReferenceBindingRefuseBeforePublishingProjection() async throws {
        let (inputs, request) = try await fixture()
        let projection = try project(inputs, request)
        #expect(try project(inputs, request, maximumRecords: projection.recordCount).recordCount == projection.recordCount)
        #expect(throws: PhysicalDesignTechnologyError.self) {
            _ = try project(inputs, request, maximumRecords: projection.recordCount - 1)
        }
        var sources = request.processAssets.mapValues(\.reference)
        sources["cells"] = sources["tech"]
        #expect(throws: PhysicalDesignTechnologyError.self) {
            _ = try PhysicalDesignAntennaSourceProjection(inputs: inputs, manifestReference: request.pdk.manifest,
                sources: sources, maximumRecords: 100)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0])
    func typedValueInputsCannotBypassAreaValidation(value: Double) async throws {
        let (inputs, request) = try await fixture()
        var cells = inputs.cellViews
        var document = try #require(cells["cells"])
        document.macros[0].pins[0].antennaDiffArea = value
        cells["cells"] = document
        let changed = PhysicalDesignProcessInputs(manifest: inputs.manifest,
            technologyViews: inputs.technologyViews, cellViews: cells)
        #expect(throws: PhysicalDesignTechnologyError.self) { _ = try project(changed, request) }
    }

    @Test func cancellationDoesNotReturnProjection() async throws {
        let (inputs, request) = try await fixture()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try project(inputs, request)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled source projection returned") }
        catch is CancellationError { }
    }

    private func project(_ inputs: PhysicalDesignProcessInputs, _ request: PhysicalDesignRequest,
                         maximumRecords: Int = 100) throws -> PhysicalDesignAntennaSourceProjection {
        try .init(inputs: inputs, manifestReference: request.pdk.manifest,
            sources: request.processAssets.mapValues(\.reference), maximumRecords: maximumRecords)
    }

    private func fixture(law: String = "ANTENNADIFFAREARATIO 3 ;", gate: Bool = true,
                         scenario: String = "supported") async throws -> (PhysicalDesignProcessInputs, PhysicalDesignRequest) {
        let (base, store) = try await ProcessGeometryTests().fixtureSources()
        var request = base
        let oldTechnology = try #require(base.processAssets["tech"])
        let oldCells = try #require(base.processAssets["cells"])
        var technology = String(decoding: try await store.read(oldTechnology), as: UTF8.self)
            .replacingOccurrences(of: "END metH", with: law + " END metH")
        var cells = String(decoding: try await store.read(oldCells), as: UTF8.self)
            .replacingOccurrences(of: "PIN Y DIRECTION OUTPUT ;", with: "PIN Y DIRECTION OUTPUT ; ANTENNADIFFAREA 0 ;")
        if gate { cells = cells.replacingOccurrences(of: "PIN A DIRECTION INPUT ;", with: "PIN A DIRECTION INPUT ; ANTENNAGATEAREA 0.126 ;") }
        switch scenario {
        case "oxide": technology = technology.replacingOccurrences(of: law, with: "ANTENNAMODEL OXIDE2 ; " + law)
        case "sidewall": technology = technology.replacingOccurrences(of: law, with: "ANTENNADIFFSIDEAREARATIO 3 ;")
        case "unmapped": technology = technology.replacingOccurrences(of: "END LIBRARY", with: "LAYER unused TYPE CUT ; ANTENNADIFFAREARATIO 3 ; END unused END LIBRARY")
        case "pin-model": cells = cells.replacingOccurrences(of: "ANTENNAGATEAREA 0.126 ;", with: "ANTENNAMODEL OXIDE1 ; ANTENNAGATEAREA 0.126 ;")
        case "direction": cells = cells.replacingOccurrences(of: "PIN A DIRECTION INPUT ;", with: "PIN A")
        case "cell-law": cells = cells.replacingOccurrences(of: "END LIBRARY", with: "LAYER metH TYPE ROUTING ; ANTENNADIFFAREARATIO 3 ; END metH END LIBRARY")
        case "side": technology = technology.replacingOccurrences(of: law, with: "THICKNESS 0.1 ; ANTENNADIFFSIDEAREARATIO 3 ;")
        case "cut": technology = technology.replacingOccurrences(of: "END cutHV", with: "ANTENNADIFFAREARATIO 2 ; END cutHV")
        default: break
        }
        let technologyBytes = Data(technology.utf8), cellBytes = Data(cells.utf8)
        let technologyBinding = try await store.registerInput(technologyBytes, relativePath: "inputs/antenna-source-tech.lef", kind: .technology, format: .lef)
        let cellBinding = try await store.registerInput(cellBytes, relativePath: "inputs/antenna-source-cells.lef", kind: .technology, format: .lef)
        let oldManifest = try request.requireBinding(for: base.pdk.manifest)
        var manifest = try PDKManifestCodec.decode(data: await store.read(oldManifest))
        for (id, binding, bytes) in [("tech", technologyBinding, technologyBytes), ("cells", cellBinding, cellBytes)] {
            let index = try #require(manifest.assets.firstIndex { $0.assetID == id })
            manifest.assets[index].sha256 = binding.reference.digest.hexadecimalValue
            manifest.assets[index].byteCount = Int64(bytes.count)
        }
        let manifestBinding = try await store.registerInput(try PDKManifestCodec.encode(manifest), relativePath: "inputs/antenna-source-process.json", kind: .technology, format: .json)
        request.pdk = try PDKReference(manifest: manifestBinding.reference, manifestLocator: PhysicalDesignFixtureFactory.locator(for: manifestBinding),
            processID: manifest.processID, version: manifest.version)
        request.processAssets = ["tech": technologyBinding, "cells": cellBinding]
        request.inputBindings = request.inputBindings.filter { $0.reference != oldManifest.reference && $0.reference != oldTechnology.reference && $0.reference != oldCells.reference }
            + [manifestBinding, technologyBinding, cellBinding]
        request.inputs = request.inputBindings.map(\.reference)
        let inputs = try #require(try await PhysicalDesignProcessInputs.load(request: request, store: store))
        return (inputs, request)
    }
}
