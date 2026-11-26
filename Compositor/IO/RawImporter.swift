import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a camera recorded, before anyone decided how it should look. The file holds one value per
/// photosite at 12–14 bits; every choice a JPEG has already baked in — exposure, white balance,
/// contrast — is still open. Compositor's layers are 8-bit, so that latitude has to be spent at
/// import: these are the controls for spending it deliberately rather than accepting a default.
nonisolated struct RawDevelopSettings: Equatable, Sendable, Codable {
    /// Stops of exposure, either side of what the camera recorded.
    var exposure: Float = 0
    /// White balance in Kelvin, starting from the camera's own reading.
    var temperature: Float = 5000
    /// Green–magenta balance, starting from the camera's own reading.
    var tint: Float = 0
    /// Apple's tone curve: 1 is its full interpretation, 0 leaves the image flat and neutral.
    var boost: Float = 1
    /// Luminance noise reduction, 0–1, starting where the system's RAW engine starts for this camera.
    var noiseReduction: Float = 0
    /// The lens's distortion and vignetting taken out, from the profile in the file, where it has one.
    var lensCorrection = false
    /// Detail brought back in highlights the camera only partly clipped (one or two channels blown).
    var highlightRecovery = false
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0
    var asShotNoiseReduction: Float = 0
    var asShotLensCorrection = false
    var asShotHighlightRecovery = false
    /// Which of those this file's camera allows; the others stay as they are.
    var supportsNoiseReduction = false
    var supportsLensCorrection = false
    var supportsHighlightRecovery = false

    /// False for settings a hand-written project could hold and the engine couldn't take.
    var isFinite: Bool {
        [exposure, temperature, tint, boost, noiseReduction, asShotTemperature, asShotTint, asShotNoiseReduction].allSatisfy(\.isFinite)
    }

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && noiseReduction == asShotNoiseReduction && lensCorrection == asShotLensCorrection
            && highlightRecovery == asShotHighlightRecovery
    }
    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
        noiseReduction = asShotNoiseReduction
        lensCorrection = asShotLensCorrection
        highlightRecovery = asShotHighlightRecovery
    }
}

nonisolated enum RawImporter {
    /// One context for every develop: building a CIContext allocates GPU resources, and the sheet
    /// develops again on each slider move. Half-float in linear light throughout, named rather than left to
    /// Core Image's defaults, so nothing is rounded before the final 8-bit pixels.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])

    /// Developing a RAW is seconds of work, so only one runs at a time and the caller waits its
    /// turn. Without this a dragged slider starts a render per pixel moved and they all pile up.
    ///
    /// The preview keeps its filter between renders, which is what makes the sliders feel live:
    /// building a new CIRAWFilter decodes the file again (about 1.5s here), while changing exposure
    /// or white balance on one that already exists costs nothing measurable.
    actor Queue {
        static let shared = Queue()
        private var cached: (url: URL, limit: CGFloat, filter: CIRAWFilter)?

        /// `sixteenBit`: the full frame at 16 bits a channel, for a 16-bit layer (`DeepLayer`); otherwise dithered to 8.
        func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat?, sixteenBit: Bool = false) -> CGImage? {
            guard let limit else { return try? RawImporter.develop(url, settings: settings, limit: nil, sixteenBit: sixteenBit) }
            let filter: CIRAWFilter
            if let cached, cached.url == url, cached.limit == limit {
                filter = cached.filter
            } else {
                guard let made = CIRAWFilter(imageURL: url) else { return nil }
                let longest = max(made.nativeSize.width, made.nativeSize.height)
                if longest > limit {
                    made.scaleFactor = Float(limit / longest)
                    made.isDraftModeEnabled = true
                }
                cached = (url, limit, made)
                filter = made
            }
            return RawImporter.render(filter, settings: settings)
        }

        /// Lets go of the decoded frame when the sheet closes.
        func release() { cached = nil }
    }

    /// Every camera RAW the system can develop — 30 formats, from Canon and Nikon to DNG — rather
    /// than a list of vendors that would need extending with each new camera.
    static func matches(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// The camera's own white balance and the engine's own starting points for this camera, which is where the
    /// controls start.
    static func asShot(_ url: URL) -> RawDevelopSettings? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        var settings = RawDevelopSettings(temperature: filter.neutralTemperature, tint: filter.neutralTint)
        settings.noiseReduction = filter.isLuminanceNoiseReductionSupported ? filter.luminanceNoiseReductionAmount : 0
        settings.lensCorrection = filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled
        settings.highlightRecovery = filter.supportsHighlightRecovery && filter.highlightRecovery
        settings.asShotTemperature = settings.temperature
        settings.asShotTint = settings.tint
        settings.asShotNoiseReduction = settings.noiseReduction
        settings.asShotLensCorrection = settings.lensCorrection
        settings.asShotHighlightRecovery = settings.highlightRecovery
        settings.supportsNoiseReduction = filter.isLuminanceNoiseReductionSupported
        settings.supportsLensCorrection = filter.isLensCorrectionSupported
        settings.supportsHighlightRecovery = filter.supportsHighlightRecovery
        return settings
    }

    /// The developed image. `limit` caps the long edge for the preview the sheet shows while the
    /// sliders move; the import itself passes nil and gets the full frame.
    static func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat? = nil, sixteenBit: Bool = false) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ImageImportError.unreadable }
        if let limit {
            let size = filter.nativeSize
            let longest = max(size.width, size.height)
            if longest > limit {
                filter.scaleFactor = Float(limit / longest)
                filter.isDraftModeEnabled = true
            }
        }
        guard let image = render(filter, settings: settings, sixteenBit: sixteenBit) else { throw ImageImportError.unreadable }
        return image
    }

    /// Applies the settings to a filter that already holds the decoded frame, and reads the pixels out.
    fileprivate static func render(_ filter: CIRAWFilter, settings: RawDevelopSettings, sixteenBit: Bool = false) -> CGImage? {
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.boost
        if settings.supportsNoiseReduction { filter.luminanceNoiseReductionAmount = settings.noiseReduction }
        if settings.supportsLensCorrection { filter.isLensCorrectionEnabled = settings.lensCorrection }
        if settings.supportsHighlightRecovery { filter.highlightRecovery = settings.highlightRecovery }
        guard let output = filter.outputImage else { return nil }
        if sixteenBit {
            return context.createCGImage(output, from: output.extent.integral, format: .RGBA16,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return dithered(output, context: context)
    }

    /// The image as 8-bit sRGB pixels, rounded with a little noise rather than straight down. A RAW holds 12–14 bits;
    /// rounded plainly to 8, a smooth sky came out in visible steps, which curves and levels then pulled further apart.
    /// Noise of about one 8-bit step, too fine to see, breaks the steps up, as Lightroom does on export. The frame is
    /// rendered once at 16 bits, then rounded on every core in C: a few tens of milliseconds on a 20-megapixel photo.
    static func dithered(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let target = try? BrushRaster.context(width: width, height: height, mask: false),
              let data = target.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var wide = [UInt16](repeating: 0, count: width * height * 4)
        wide.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 8, bounds: extent, format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // In C, where the per-pixel work is quick in any build.
        wide.withUnsafeBufferPointer { dither_quantize16($0.baseAddress!, data, width, height, target.bytesPerRow) }
        return target.makeImage()
    }


    /// The frame's size without developing it, so an oversized file is refused before the work.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Whether this macOS has highlight recovery at all: the engine gained it in macOS 26.
    static var systemHasHighlightRecovery: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// The RAW file a layer's pixels were developed from, and what made them from it: the settings it was developed
/// with, and Camera Raw's own sliders if they have been applied on top. A layer's pixels kept as that recipe, as
/// Lightroom keeps a photo: Camera Raw opens on the layer with every control where it was left and renders from the
/// file again, so nothing it did is ever baked in (`RawDeveloper`, `FilterEdit.rawSettings`).
/// The file's own bytes, not its place on disk: that may be a dropped file's short-lived copy, or somewhere the
/// sandbox lets the app read only while it is being imported.
nonisolated final class RawOrigin: @unchecked Sendable {
    let data: Data
    /// The file's type, which tells the engine whose format the bytes are.
    let type: String?
    let settings: RawDevelopSettings
    /// Camera Raw's sliders, applied to the develop to make the layer's pixels. Nil: the pixels are the develop itself.
    let recipe: CameraRawSettings?
    /// What the sliders' grain was drawn with, so that made again it falls where it did.
    let seed: UInt32
    /// A read-only bookmark of the file, by which a saved project finds it again (`RawLink`). Nil when none could be
    /// made, and a project then keeps the layer's pixels alone.
    let bookmark: Data?
    /// `digest(of:)` the file's bytes: with their count, how a project knows the file again.
    let digest: String

    init(data: Data, type: String?, settings: RawDevelopSettings, recipe: CameraRawSettings? = nil, seed: UInt32 = 0,
         bookmark: Data? = nil, digest: String? = nil) {
        self.data = data
        self.type = type
        self.settings = settings
        self.recipe = recipe
        self.seed = seed
        self.bookmark = bookmark
        self.digest = digest ?? Self.digest(of: data)
    }

    /// The file mapped rather than read, where that is safe, so a 90 MB file costs no memory until it is developed.
    convenience init?(url: URL, settings: RawDevelopSettings) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data, type: UTType(filenameExtension: url.pathExtension)?.identifier, settings: settings,
                  bookmark: Self.bookmark(of: url))
    }

    func developed(with settings: RawDevelopSettings, recipe: CameraRawSettings? = nil, seed: UInt32 = 0) -> RawOrigin {
        RawOrigin(data: data, type: type, settings: settings, recipe: recipe, seed: seed, bookmark: bookmark, digest: digest)
    }

    /// The layer these make: the file developed whole at 16 bits by a decoder of its own, and the recipe's sliders
    /// applied the way OK applies a filter to a 16-bit layer. The one routine that makes a RAW layer's pixels, when OK
    /// is pressed and when a step in the history is returned to, so the two can't come out differently.
    func render(name: String) throws -> ImportedImage {
        // Stopped between its passes when the step it is for has been left again (`rehydrateRawLayers`).
        try Task.checkCancellation()
        guard let filter = CIRAWFilter(imageData: data, identifierHint: type),
              let developed = RawImporter.render(filter, settings: settings, sixteenBit: true) else { throw ImageImportError.unreadable }
        let source = try DeepLayer.asset(developed, name: name)
        guard let recipe, let deep = source.deep else { return source }
        var applied = FilterSettings()
        applied.cameraRaw = recipe
        let job = FilterJob(kind: .cameraRaw, image: source.image, settings: applied, scale: 1, selection: nil, mapping: .identity, seed: seed)
        let made = try DeepLayer.run(deep, mixesChannels: FilterKind.cameraRaw.mixesChannels) { half in
            try Task.checkCancellation()
            var run = job
            run.image = half
            return try PixelFilter.run(run)
        }
        return try DeepLayer.asset(made, name: name)
    }
}

/// Which pixels were made from which RAW file, and how. Told by the images themselves rather than kept on the layer:
/// once anything but Camera Raw is done to a layer its images are new ones, which aren't found here, and undone they
/// are the old ones again. Nothing is held: an entry goes when its images do. A project saves each layer's as a
/// `RawLink` and puts it back here on opening.
final class RawOrigins {
    static let shared = RawOrigins()
    private struct Entry {
        weak var image: CGImage?
        weak var deep: CGImage?
        let origin: RawOrigin
    }
    private var entries: [Entry] = []

    func register(_ asset: ImportedImage, from origin: RawOrigin) {
        entries.removeAll { $0.image == nil || $0.deep == nil }
        guard let deep = asset.deep else { return }
        entries.append(Entry(image: asset.image, deep: deep, origin: origin))
    }

    /// Nil for a layer that has been painted on, whose strokes lie over these pixels (`raster`), and for any whose
    /// pixels are no longer the developed ones.
    func origin(of asset: ImportedImage?) -> RawOrigin? {
        guard let asset, asset.raster == nil, let deep = asset.deep else { return nil }
        return entries.first { $0.image === asset.image && $0.deep === deep }?.origin
    }

    private struct Away {
        weak var image: CGImage?
        weak var deep: CGImage?
        let record: RawLinkRecord
    }
    private var away: [Away] = []

    /// A layer opened from a project whose RAW file wasn't found, or whose recipe this build can't read: `record`
    /// is what the project held for it. Kept while the layer's pixels are those the project had, to be saved again
    /// as it was and tried again when Camera Raw next opens on the layer (`reconnected`).
    func keep(_ record: RawLinkRecord, for asset: ImportedImage) {
        away.removeAll { $0.image == nil || $0.deep == nil }
        guard let deep = asset.deep else { return }
        away.append(Away(image: asset.image, deep: deep, record: record))
    }

    /// Whether the layer's RAW file is one that couldn't be found.
    func isAway(_ asset: ImportedImage?) -> Bool {
        guard let asset, asset.raster == nil, let deep = asset.deep else { return false }
        return away.contains { $0.image === asset.image && $0.deep === deep }
    }

    /// `origin(of:)`, looking again for a file that was away: a drive plugged back in since the project opened.
    func reconnected(_ asset: ImportedImage?) -> RawOrigin? {
        if let origin = origin(of: asset) { return origin }
        guard let asset, asset.raster == nil, let deep = asset.deep,
              let index = away.firstIndex(where: { $0.image === asset.image && $0.deep === deep }),
              let origin = away[index].record.link?.origin() else { return nil }
        away.remove(at: index)
        register(asset, from: origin)
        return origin
    }

    /// What a project saves for the layer: its recipe, or what the project it came from held while its file is away.
    func record(for asset: ImportedImage?) -> RawLinkRecord? {
        guard let asset, asset.raster == nil, let deep = asset.deep else { return nil }
        if let origin = origin(of: asset) {
            return RawLink(origin, width: deep.width, height: deep.height).flatMap(RawLinkRecord.init)
        }
        return away.first { $0.image === asset.image && $0.deep === deep }?.record
    }

    private struct StandIn {
        weak var image: CGImage?
        let origin: RawOrigin
        let name: String
    }
    private var standIns: [StandIn] = []
    /// A stand-in's longest side: enough to show the layer well, fitted to a window, for the seconds its pixels take
    /// to make again.
    static let standInLimit: CGFloat = 2048

    /// A small copy to hold in the history in a RAW layer's place (`DocumentHistory.slim`), remembered with what
    /// makes the layer's pixels again: 11 MB where a 42-megapixel layer's 16-bit pixels and their 8-bit copy are 480.
    /// Nil for any other layer, and for one no larger than its stand-in would be.
    func standIn(for asset: ImportedImage) -> ImportedImage? {
        guard let origin = origin(of: asset) else { return nil }
        let factor = Self.standInLimit / CGFloat(max(asset.image.width, asset.image.height))
        guard factor < 1 else { return nil }
        let width = max(1, Int(CGFloat(asset.image.width) * factor)), height = max(1, Int(CGFloat(asset.image.height) * factor))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        BrushRaster.draw(asset.image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let small = context.makeImage() else { return nil }
        standIns.removeAll { $0.image == nil }
        standIns.append(StandIn(image: small, origin: origin, name: asset.name))
        return ImportedImage(image: small, thumbnail: asset.thumbnail, name: asset.name)
    }

    /// What makes the pixels a stand-in holds the place of; nil for anything that isn't one.
    func standsFor(_ asset: ImportedImage?) -> (origin: RawOrigin, name: String)? {
        guard let asset, asset.deep == nil, asset.raster == nil else { return nil }
        return standIns.first { $0.image === asset.image }.map { ($0.origin, $0.name) }
    }
}

/// A RAW file held open while Camera Raw works on a layer developed from it. The engine decodes the file once, about
/// a second for 42 megapixels; after that a change of exposure or white balance renders in about 10 ms at a draft's
/// size and 0.2 s at the photo's own, which is what lets the RAW controls follow a drag.
actor RawDeveloper {
    private let origin: RawOrigin
    /// The decoder kept between develops, and the white point it read from the file.
    private var kept: (filter: CIRAWFilter, asShot: CGPoint)?

    init(_ origin: RawOrigin) { self.origin = origin }

    /// The file developed with `settings`: no longer than `limit` on its longest side and dithered to 8 bits, as a
    /// preview's source; or whole, at 8 bits or (`sixteenBit`) the 16 a layer keeps. As `RawImporter.develop` makes
    /// it, so the same settings give the pixels the import did. `fresh` decodes the file anew, about a second more:
    /// for the pixels a layer keeps, which then owe nothing to what this decoder was asked for before.
    func develop(_ settings: RawDevelopSettings, limit: CGFloat? = nil, sixteenBit: Bool = false, fresh: Bool = false) -> CGImage? {
        if fresh {
            guard let filter = CIRAWFilter(imageData: origin.data, identifierHint: origin.type) else { return nil }
            return RawImporter.render(filter, settings: settings, sixteenBit: sixteenBit)
        }
        if kept == nil, let made = CIRAWFilter(imageData: origin.data, identifierHint: origin.type) {
            kept = (made, made.neutralChromaticity)
        }
        guard let (filter, asShot) = kept else { return nil }
        // Every develop starts from the file's own exposure and white point. Without that the engine's result
        // depends a little on the way its settings came: exposure moved in draft mode, away from the camera's white
        // balance, left most values a fraction of a level off those of a decoder set there at once, and a few far off.
        filter.exposure = 0
        filter.neutralChromaticity = asShot
        let longest = max(filter.nativeSize.width, filter.nativeSize.height)
        if let limit, longest > limit {
            filter.scaleFactor = Float(limit / longest)
            filter.isDraftModeEnabled = true
        } else {
            filter.scaleFactor = 1
            filter.isDraftModeEnabled = false
        }
        return RawImporter.render(filter, settings: settings, sixteenBit: sixteenBit)
    }
}

/// Highlight recovery arrived in macOS 26. Before it the engine has no such switch, so it reads as unsupported and
/// off, and the develop sheet greys its toggle out as it does for a camera without it.
nonisolated private extension CIRAWFilter {
    var supportsHighlightRecovery: Bool {
        if #available(macOS 26.0, *) { return isHighlightRecoverySupported }
        return false
    }

    var highlightRecovery: Bool {
        get {
            if #available(macOS 26.0, *) { return isHighlightRecoveryEnabled }
            return false
        }
        set {
            if #available(macOS 26.0, *) { isHighlightRecoveryEnabled = newValue }
        }
    }
}
