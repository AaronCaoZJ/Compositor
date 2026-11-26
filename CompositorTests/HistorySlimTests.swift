import AppKit
import Testing
@testable import Compositor

/// History holding a stand-in in place of an asset whose pixels can be made again (`DocumentHistory.slim`), as it
/// does for a RAW layer kept as a recipe. Here the stand-ins are a few pixels of any image, by a rule of the test's.
@MainActor
struct HistorySlimTests {
    private func image(_ side: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private func asset(_ side: Int, _ name: String) throws -> ImportedImage {
        ImportedImage(image: try image(side), thumbnail: try image(4), name: name)
    }

    /// A history whose assets named "big" have a 4-pixel stand-in, with the stand-ins it has handed out.
    private func slimming(limit: Int) throws -> (history: DocumentHistory, standIns: () -> [ImportedImage]) {
        let history = DocumentHistory(entryLimit: 100, retainedByteLimit: limit)
        let small = try image(4)
        var made: [ImportedImage] = []
        history.slim = { asset in
            guard asset.name == "big" else { return nil }
            let standIn = ImportedImage(image: small.copy()!, thumbnail: asset.thumbnail, name: "stand-in")
            made.append(standIn)
            return standIn
        }
        return (history, { made })
    }

    @Test func aStepWhosePixelsCanBeMadeAgainIsKeptAsAStandIn() throws {
        // Room for no version of a 256-pixel layer (262 KB), which without stand-ins would leave nothing to undo.
        let (history, standIns) = try slimming(limit: 64 * 1024)
        var document = CanvasDocument(width: 256, height: 256)
        let first = try asset(256, "big")
        document.layers = [ImageLayer(asset: first, origin: .zero)]
        let id = document.layers[0].id
        var versions = [first]
        for _ in 1...5 {
            history.begin("Edit", document: document, selection: id)
            let next = try asset(256, "big")
            document.layers[0].asset = next
            versions.append(next)
            history.end(document: document, selection: id)
        }
        #expect(history.undoCount == 5, "every step is still there")
        #expect(history.retainedBytes(current: document) < 64 * 1024)
        #expect(standIns().count == 5, "one stand-in for each version the document no longer shows")

        // Undone, a step shows its stand-in; the version left behind gives way to one too.
        let snapshot = try #require(history.undo())
        let shown = try #require(snapshot.document?.layers[0].asset)
        #expect(shown.name == "stand-in" && shown.image !== versions[4].image)
        #expect(standIns().count == 6)
        #expect(history.retainedBytes(current: snapshot.document) < 64 * 1024)

        // Its pixels made again go back in every step that held the stand-in. Going on to the newer step, they are no
        // longer shown, and give way to a stand-in of their own: which is how it's known the steps held them.
        let again = try asset(256, "big")
        history.replaceAssets { $0.image === shown.image ? again : nil }
        let redone = try #require(history.redo())
        #expect(redone.document?.layers[0].asset?.name == "stand-in", "the newest version, slimmed when it was left")
        #expect(standIns().count == 7)
        let back = try #require(history.undo())
        let standIn = try #require(back.document?.layers[0].asset)
        #expect(standIn.name == "stand-in" && standIn.image !== shown.image && standIn.image !== again.image)
        #expect(history.undoCount == 4 && history.canRedo)
    }

    @Test func theNearestStepsKeepTheirPixels() throws {
        // Room for two versions of a 256-pixel layer (262 KB each), and no more.
        let room = 600 * 1024
        let (history, standIns) = try slimming(limit: room)
        var document = CanvasDocument(width: 256, height: 256)
        let first = try asset(256, "big")
        document.layers = [ImageLayer(asset: first, origin: .zero)]
        let id = document.layers[0].id
        var versions = [first]
        for _ in 1...5 {
            history.begin("Edit", document: document, selection: id)
            let next = try asset(256, "big")
            document.layers[0].asset = next
            versions.append(next)
            history.end(document: document, selection: id)
        }
        #expect(history.undoCount == 5)
        #expect(standIns().count == 3, "only the three farthest versions gave way")
        let one = try #require(history.undo())
        #expect(one.document?.layers[0].asset?.image === versions[4].image, "a step back is there as pixels")
        let two = try #require(history.undo())
        #expect(two.document?.layers[0].asset?.image === versions[3].image, "and the one before it")
        let three = try #require(history.undo())
        #expect(three.document?.layers[0].asset?.name == "stand-in", "past the room there is, a stand-in")
        #expect(history.undoCount == 2 && history.canRedo)
        #expect(history.retainedBytes(current: three.document) <= room)
    }

    @Test func assetsWithNoStandInAreTrimmedAsBefore() throws {
        let (history, standIns) = try slimming(limit: 0)
        var document = CanvasDocument(width: 64, height: 64)
        document.layers = [ImageLayer(asset: try asset(64, "plain"), origin: .zero)]
        let id = document.layers[0].id
        for _ in 1...3 {
            history.begin("Edit", document: document, selection: id)
            document.layers[0].asset = try asset(64, "plain")
            history.end(document: document, selection: id)
        }
        #expect(standIns().isEmpty)
        #expect(history.undoCount == 0 && history.retainedBytes(current: document) == 0)
    }

    @Test func theEndThatHoldsThePixelsIsTheOneThatGoes() throws {
        // Five cheap steps, then one whose undone result is all that is over the limit: undoing it must not cost the five.
        let (history, _) = try slimming(limit: 64 * 1024)
        var document = CanvasDocument(width: 256, height: 256)
        document.layers = [ImageLayer(asset: try asset(256, "big"), origin: .zero)]
        let id = document.layers[0].id
        for _ in 1...5 {
            history.begin("Recipe", document: document, selection: id)
            document.layers[0].asset = try asset(256, "big")
            history.end(document: document, selection: id)
        }
        history.begin("Filter", document: document, selection: id)
        document.layers[0].asset = try asset(256, "plain")
        history.end(document: document, selection: id)
        #expect(history.undoCount == 6)
        let before = try #require(history.undo())
        #expect(history.undoCount == 5, "the cheap steps stay")
        #expect(!history.canRedo, "the filter's result, with no stand-in, is what was dropped")
        #expect(history.retainedBytes(current: before.document) < 64 * 1024)
    }
}
