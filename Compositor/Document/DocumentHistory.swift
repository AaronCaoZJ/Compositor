import Foundation
import CoreGraphics
import Observation

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
    }
    private struct Entry {
        let name: String
        let before: Snapshot
        let after: Snapshot
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var depth = 0
    let entryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last.map { L10n.string($0.name) } ?? "" }
    var redoName: String { future.last.map { L10n.string($0.name) } ?? "" }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    func reset() {
        past.removeAll()
        future.removeAll()
        pending = nil
        depth = 0
        revision = UUID()
        savedRevision = revision
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?) {
        if depth == 0 {
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
        }
        depth += 1
    }

    /// The document as it was when the edit now ending began, if this is its outermost `end`.
    var endingEditBefore: CanvasDocument? { depth == 1 ? pending?.document : nil }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        revision = UUID()
        // What starts a document (an image opened onto the welcome screen, a new canvas) is where its history
        // starts: undoing all the way back stops at it rather than closing it.
        guard before.document != nil else {
            past.removeAll()
            future.removeAll()
            return
        }
        past.append(Entry(name: pendingName, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision)))
        future.removeAll()
        trim(current: document)
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.popLast() else { return nil }
        future.append(entry)
        revision = entry.before.revision
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        trim(current: entry.after.document)
        return entry.after
    }

    /// Every image an asset holds: a 16-bit layer's 16-bit pixels too, twice the size of its 8-bit copy.
    private static func images(of asset: ImportedImage) -> [CGImage] {
        [asset.image, asset.thumbnail] + (asset.deep.map { [$0] } ?? [])
    }

    private static func assets(of layer: ImageLayer) -> [ImportedImage] {
        [layer.asset, layer.mask?.asset].compactMap { $0 } + Array(layer.gifAnimation?.framePixels.values ?? [:].values)
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int { retainedBytes(of: past + future, current: current) }

    private func retainedBytes(of entries: [Entry], current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        var seenSources = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in Self.assets(of: layer) {
                for image in Self.images(of: asset) { seen.insert(ObjectIdentifier(image)) }
            }
            if let source = layer.gifAnimation?.source {
                seenSources.insert(ObjectIdentifier(source))
                for frame in source.frames { seen.insert(ObjectIdentifier(frame.thumbnail)) }
            }
        }
        var bytes = 0
        for entry in entries {
            for snapshot in [entry.before, entry.after] {
                for layer in snapshot.document?.layers ?? [] {
                    for asset in Self.assets(of: layer) {
                        for image in Self.images(of: asset) where seen.insert(ObjectIdentifier(image)).inserted {
                            bytes += image.bytesPerRow * image.height
                        }
                    }
                    if let source = layer.gifAnimation?.source {
                        if seenSources.insert(ObjectIdentifier(source)).inserted { bytes += source.data.count }
                        for frame in source.frames where seen.insert(ObjectIdentifier(frame.thumbnail)).inserted {
                            bytes += frame.thumbnail.bytesPerRow * frame.thumbnail.height
                        }
                    }
                }
            }
        }
        return bytes
    }

    private func trim(current: CanvasDocument?) {
        slimDown(current: current)
        while past.count + future.count > entryLimit {
            if !past.isEmpty { past.removeFirst() } else { future.removeFirst() }
        }
        // Over the pixels it may hold, a step goes from one end: the oldest undo, unless the farthest redo gives
        // back more. An undone filter's result is hundreds of megabytes where the oldest steps may each be a RAW
        // layer's stand-in, and dropping those first would empty the history without making the room.
        while true {
            let held = retainedBytes(of: past + future, current: current)
            guard held > retainedByteLimit else { break }
            let withoutOldest = past.isEmpty ? held : retainedBytes(of: Array(past.dropFirst()) + future, current: current)
            let withoutFarthest = future.isEmpty ? held : retainedBytes(of: past + Array(future.dropFirst()), current: current)
            if !future.isEmpty, withoutFarthest < withoutOldest { future.removeFirst() }
            else if !past.isEmpty { past.removeFirst() }
            else if !future.isEmpty { future.removeFirst() }
            else { break }
        }
    }

    /// A small stand-in for an asset whose pixels can be made again from what it stands for (a RAW layer kept as a
    /// recipe: `RawOrigins.standIn`), or nil for one that can't. Over what it may hold, history keeps the stand-in
    /// in such an asset's place before it drops any step, so the step costs a few megabytes where its pixels would
    /// cost hundreds; returning to it, the pixels are made again and put back with `replaceAssets`.
    @ObservationIgnored var slim: ((ImportedImage) -> ImportedImage?)?

    /// While more is held than may be, assets `current` doesn't show give way to their stand-ins: those of the steps
    /// farthest from where the document is first, so the nearest steps keep their pixels and are returned to at once,
    /// as any step is. The one stand-in goes wherever the asset was, so steps still tell by their images which layers
    /// they share.
    private func slimDown(current: CanvasDocument?) {
        guard let slim, retainedBytes(of: past + future, current: current) > retainedByteLimit else { return }
        var shown = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] { if let image = layer.asset?.image { shown.insert(ObjectIdentifier(image)) } }
        // How many steps away each asset is, at its nearest: a step's `after` is one nearer than its `before` going
        // back, and one farther going forward.
        var nearest: [ObjectIdentifier: (steps: Int, asset: ImportedImage)] = [:]
        func note(_ snapshot: Snapshot, _ steps: Int) {
            for layer in snapshot.document?.layers ?? [] {
                guard let asset = layer.asset, !shown.contains(ObjectIdentifier(asset.image)) else { continue }
                let image = ObjectIdentifier(asset.image)
                if steps < nearest[image]?.steps ?? .max { nearest[image] = (steps, asset) }
            }
        }
        for (index, entry) in past.enumerated() {
            note(entry.before, past.count - index)
            note(entry.after, past.count - index - 1)
        }
        for (index, entry) in future.enumerated() {
            note(entry.before, future.count - index - 1)
            note(entry.after, future.count - index)
        }
        for (_, asset) in nearest.values.sorted(by: { $0.steps > $1.steps }) {
            guard let standIn = slim(asset) else { continue }
            replaceAssets { $0.image === asset.image ? standIn : nil }
            if retainedBytes(of: past + future, current: current) <= retainedByteLimit { break }
        }
    }

    /// Puts another asset in a layer's place in every step, as `replacement` says; nil leaves one as it is.
    func replaceAssets(_ replacement: (ImportedImage) -> ImportedImage?) {
        var any = false
        func replaced(_ snapshot: Snapshot) -> Snapshot {
            guard var document = snapshot.document else { return snapshot }
            var changed = false
            for index in document.layers.indices {
                guard let asset = document.layers[index].asset, let other = replacement(asset) else { continue }
                document.layers[index].asset = other
                changed = true
            }
            guard changed else { return snapshot }
            any = true
            return Snapshot(document: document, activeLayerID: snapshot.activeLayerID, revision: snapshot.revision)
        }
        let earlier = past.map { Entry(name: $0.name, before: replaced($0.before), after: replaced($0.after)) }
        let later = future.map { Entry(name: $0.name, before: replaced($0.before), after: replaced($0.after)) }
        let open = pending.map(replaced)
        // Left alone when nothing changed, which is nearly every time: these are watched.
        guard any else { return }
        past = earlier
        future = later
        pending = open
    }
}
