import AppKit
import OSLog

@MainActor
final class AppleMusicArtworkProvider {
    private var refreshTask: Task<Void, Never>?

    func refreshArtwork(
        for track: NowPlayingTrack?,
        appState: AppState,
        onArtworkChanged: (@MainActor () -> Void)? = nil
    ) {
        refreshTask?.cancel()
        refreshTask = nil

        guard appState.isLiveModeRunning, let track else {
            appState.clearNowPlayingArtwork()
            onArtworkChanged?()
            return
        }

        appState.applyNowPlayingArtwork(nil, forTrackID: track.id)
        onArtworkChanged?()
        refreshTask = Task { @MainActor [weak appState] in
            let image = await PublicAppleMusicArtworkProvider.currentTrackArtwork()
            guard !Task.isCancelled, let appState else { return }
            appState.applyNowPlayingArtwork(image, forTrackID: track.id)
            onArtworkChanged?()
        }
    }

    func cancel(appState: AppState, onArtworkChanged: (@MainActor () -> Void)? = nil) {
        refreshTask?.cancel()
        refreshTask = nil
        appState.clearNowPlayingArtwork()
        onArtworkChanged?()
    }
}

enum PublicAppleMusicArtworkProvider {
    private static let artworkScript = """
    tell application id "com.apple.Music"
        if it is running then
            try
                set artData to data of artwork 1 of current track
                return artData
            on error
                return ""
            end try
        else
            return ""
        end if
    end tell
    """

    static func currentTrackArtwork() async -> NSImage? {
        guard await MainActor.run(body: { AppleMusicEventListener.isMusicAppRunning }) else {
            return nil
        }
        guard let data = await AppleScriptRunner.runDataOffMain(artworkScript),
              !data.isEmpty else {
            await MainActor.run {
                AppTelemetry.performance.info("Music artwork unavailable from AppleScript")
            }
            return nil
        }

        guard let thumbnailData = await ArtworkImageProcessor.downsampledImageData(from: data),
              let image = NSImage(data: thumbnailData) else {
            await MainActor.run {
                AppTelemetry.performance.info("Music artwork unavailable after thumbnail downsampling")
            }
            return nil
        }

        return image
    }
}

enum ArtworkImageProcessor {
    nonisolated static let defaultMaxPixelSize = 256

    nonisolated static func downsampledImageData(
        from data: Data,
        maxPixelSize: Int = defaultMaxPixelSize
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            downsampledImageDataSync(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func downsampledImageDataSync(
        from data: Data,
        maxPixelSize: Int
    ) -> Data? {
        autoreleasepool {
            guard let source = NSImage(data: data) else {
                return nil
            }

            let sourcePixelSize = source.bestPixelSize
            guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
                return nil
            }

            let targetPixelSize = scaledPixelSize(
                source: sourcePixelSize,
                maxPixelSize: max(1, maxPixelSize)
            )
            guard let bitmap = unsafe NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(targetPixelSize.width.rounded(.toNearestOrAwayFromZero)),
                pixelsHigh: Int(targetPixelSize.height.rounded(.toNearestOrAwayFromZero)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                return nil
            }
            bitmap.size = targetPixelSize

            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(
                in: NSRect(origin: .zero, size: targetPixelSize),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()

            return bitmap.representation(using: .png, properties: [:])
        }
    }

    nonisolated private static func scaledPixelSize(
        source: NSSize,
        maxPixelSize: Int
    ) -> NSSize {
        let maxDimension = max(source.width, source.height)
        guard maxDimension > CGFloat(maxPixelSize) else {
            return source
        }

        let scale = CGFloat(maxPixelSize) / maxDimension
        return NSSize(
            width: max(1, source.width * scale),
            height: max(1, source.height * scale)
        )
    }
}

private extension NSImage {
    nonisolated var bestPixelSize: NSSize {
        guard let largestRepresentation = representations.max(by: { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }) else {
            return size
        }

        guard largestRepresentation.pixelsWide > 0, largestRepresentation.pixelsHigh > 0 else {
            return size
        }

        return NSSize(width: largestRepresentation.pixelsWide, height: largestRepresentation.pixelsHigh)
    }
}
