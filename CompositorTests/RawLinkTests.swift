import AppKit
import Foundation
import Testing
@testable import Compositor

/// A RAW layer's recipe kept by a project (`RawLink`): saved beside the layer's pixels with a read-only bookmark of
/// the file, and the layer's again when the project is opened. The "RAW file" here is any bytes: nothing develops it.
@MainActor
struct RawLinkTests {
    /// A file of `count` bytes that say which file it is.
    private func file(_ fill: UInt8, count: Int = 3 << 20) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shot-\(UUID().uuidString).arw")
        try Data(repeating: fill, count: count).write(to: url)
        return url
    }

    /// A 16-bit layer, as a developed RAW file is.
    private func layer(_ gray: UInt16 = 30_000, width: Int = 24, height: Int = 16) throws -> ImportedImage {
        let context = try DeepLayer.context(width: width, height: height)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for i in 0..<(width * height) { pixels[i * 4] = gray; pixels[i * 4 + 1] = gray; pixels[i * 4 + 2] = gray; pixels[i * 4 + 3] = 65535 }
        return try DeepLayer.asset(try #require(context.makeImage()), name: "Shot")
    }

    /// A session whose one layer is a recipe from `url`, the session's snapshot saved to a project.
    private func saved(from url: URL) async throws -> (project: URL, id: UUID, origin: RawOrigin, session: EditorSession) {
        var develop = RawDevelopSettings()
        develop.exposure = -0.7
        develop.temperature = 6100
        var sliders = CameraRawSettings()
        sliders.contrast = 20
        sliders.grainAmount = 30
        sliders.mixer.saturation[2] = -15
        let origin = try #require(RawOrigin(url: url, settings: develop)).developed(with: develop, recipe: sliders, seed: 4242)
        let session = EditorSession()
        session.createDocument(width: 24, height: 16)
        let asset = try layer()
        session.insert(asset)
        RawOrigins.shared.register(asset, from: origin)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("Recipe-\(UUID().uuidString).comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: project)
        return (project, try #require(session.activeLayerID), origin, session)
    }

    private func opened(_ project: URL) async throws -> (session: EditorSession, snapshot: ProjectSnapshot) {
        let snapshot = try await ProjectStore.shared.load(from: project)
        let session = EditorSession()
        session.installProject(snapshot, from: project)
        return (session, snapshot)
    }

    @Test func aRecipeIsSavedWithTheProjectAndIsTheLayersAgainOnOpening() async throws {
        let url = try file(7)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RawOrigin(url: url, settings: RawDevelopSettings())?.bookmark != nil, "a read-only bookmark can be made of the file")
        let (project, id, origin, _) = try await saved(from: url)
        defer { try? FileManager.default.removeItem(at: project) }

        // The package holds the layer's pixels and the record: the file itself isn't copied in.
        let images = try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("images").path)
        #expect(images == ["\(id.uuidString).png"])
        let (session, snapshot) = try await opened(project)
        #expect(snapshot.manifest.version == ProjectManifest.current, "the format's version is the one it was")
        let link = try #require(snapshot.manifest.layers.first?.raw?.link)
        #expect(link.byteCount == 3 << 20 && link.width == 24 && link.height == 16 && link.seed == 4242)

        let found = try #require(RawOrigins.shared.origin(of: session.activeLayer?.asset), "the layer is its recipe again")
        #expect(found.settings == origin.settings, "what the file is developed with")
        #expect(found.recipe == origin.recipe && found.recipe?.mixer.saturation[2] == -15, "Camera Raw's sliders")
        #expect(found.seed == 4242 && found.data == origin.data, "the grain's seed, and the file's own bytes")
        // Saved again from there, the record is the same one.
        #expect(session.projectSnapshot()?.manifest.layers.first?.raw?.link == link)
    }

    @Test func withItsFileGoneTheLayerOpensAsPixelsAndKeepsItsRecord() async throws {
        let url = try file(7)
        let (project, _, _, _) = try await saved(from: url)
        defer { try? FileManager.default.removeItem(at: project) }
        let record = try #require(try await ProjectStore.shared.load(from: project).manifest.layers.first?.raw)
        try FileManager.default.removeItem(at: url)

        let (session, snapshot) = try await opened(project)
        #expect(snapshot.raws.isEmpty)
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.deep != nil, "the layer is there, as its pixels")
        #expect(RawOrigins.shared.origin(of: asset) == nil && RawOrigins.shared.isAway(asset))
        #expect(session.projectSnapshot()?.manifest.layers.first?.raw == record, "saved again, what the project held is written back")

        // The file back where it was: found the next time it is looked for, with the project still open.
        try Data(repeating: 7, count: 3 << 20).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RawOrigins.shared.reconnected(asset)?.settings.exposure == -0.7)
        #expect(!RawOrigins.shared.isAway(asset) && RawOrigins.shared.origin(of: asset) != nil)
    }

    @Test func anotherFileInItsPlaceIsNotDevelopedForTheLayer() async throws {
        let url = try file(7)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _, _) = try await saved(from: url)
        defer { try? FileManager.default.removeItem(at: project) }
        // The same length, other bytes; then another length.
        for other in [Data(repeating: 9, count: 3 << 20), Data(repeating: 7, count: 2 << 20)] {
            try other.write(to: url)
            let (session, snapshot) = try await opened(project)
            #expect(snapshot.raws.isEmpty && RawOrigins.shared.origin(of: session.activeLayer?.asset) == nil)
            #expect(RawOrigins.shared.isAway(session.activeLayer?.asset), "kept as a file that is away, not dropped")
        }
    }

    @Test func aLayerWhosePixelsAreNoLongerTheRecipesSavesNoRecord() async throws {
        let url = try file(7)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, id, _, session) = try await saved(from: url)
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(session.projectSnapshot()?.manifest.layers.first?.raw != nil)
        // Anything else done to the layer gives it other pixels, which no recipe is known for.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].asset = try layer(40_000)
        #expect(session.projectSnapshot()?.manifest.layers.first?.raw == nil)
    }

    @Test func settingsAreReadOverTodaysDefaults() throws {
        var sliders = CameraRawSettings()
        sliders.contrast = 20
        sliders.vibrance = 15
        sliders.grading.shadows.hue = 210
        guard case .object(var members) = try JSONValue(sliders) else { Issue.record("settings encode to an object"); return }
        #expect(JSONValue.object(members).decoded(over: CameraRawSettings()) == sliders, "as saved, the same settings")
        // A control this build has that the project was saved without, and one the project has that this build lacks.
        members["contrast"] = nil
        members["aControlFromALaterBuild"] = .number(7)
        let read = try #require(JSONValue.object(members).decoded(over: CameraRawSettings()))
        #expect(read.contrast == 0 && read.vibrance == 15 && read.grading.shadows.hue == 210)
        // A member of the wrong kind can't be read at all, and says so rather than guessing.
        members["vibrance"] = .string("a lot")
        #expect(JSONValue.object(members).decoded(over: CameraRawSettings()) == nil)
    }

    @Test func aRecordThatCantBeReadDoesntStopAProjectOpening() async throws {
        let url = try file(7)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _, _) = try await saved(from: url)
        defer { try? FileManager.default.removeItem(at: project) }
        let manifestURL = project.appendingPathComponent("manifest.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var layers = try #require(manifest["layers"] as? [[String: Any]])
        layers[0]["raw"] = ["bookmark": "not a bookmark", "develop": 3]
        manifest["layers"] = layers
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let (session, snapshot) = try await opened(project)
        #expect(session.document?.layers.count == 1 && session.activeLayer?.asset?.deep != nil, "the project opens, with the layer")
        #expect(snapshot.manifest.layers.first?.raw?.link == nil && RawOrigins.shared.origin(of: session.activeLayer?.asset) == nil)
        #expect(session.projectSnapshot()?.manifest.layers.first?.raw == snapshot.manifest.layers.first?.raw, "and what was there is kept")
    }
}
