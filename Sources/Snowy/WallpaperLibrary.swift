import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WallpaperEntry: Hashable, Identifiable, Sendable {
    case builtIn(WinterWallpaper)
    case imported(String)

    var id: Self { self }

    var title: String {
        switch self {
        case .builtIn(let artwork): artwork.title
        case .imported(let name): String(name.dropFirst(37).dropLast(4))
        }
    }
}

actor WallpaperLibrary {
    static let shared = WallpaperLibrary(supportDirectory: .applicationSupportDirectory)
    static let importTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .webP]
    static let importLimit = 60
    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumSourcePixels = 80_000_000
    private static let maximumWallpaperEdge = 5_120
    private static let thumbnailEdge = 512

    private enum LibraryError: Error {
        case invalidImage, unavailable
    }

    private let fileManager = FileManager.default
    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    func importedEntries() throws -> [WallpaperEntry] {
        let directory = try libraryDirectory(create: false)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return files.compactMap { url -> WallpaperEntry? in
            let name = url.lastPathComponent
            guard Self.isImportedName(name),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return .imported(name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func importImages(_ urls: [URL]) throws -> (entries: [WallpaperEntry], added: [WallpaperEntry]) {
        let directory = try libraryDirectory()
        var entries = try importedEntries()
        var added: [WallpaperEntry] = []
        let availableSlots = max(0, Self.importLimit - entries.count)
        for url in urls.prefix(availableSlots) {
            if let entry = try? importImage(url, into: directory) {
                entries.append(entry)
                added.append(entry)
            }
        }
        entries.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (entries, added)
    }

    func thumbnail(for entry: WallpaperEntry) -> CGImage? {
        switch entry {
        case .builtIn(let artwork): artwork.makeImage(width: Self.thumbnailEdge)
        case .imported:
            try? image(at: existingURL(for: entry), maximumEdge: Self.thumbnailEdge)
        }
    }

    func fileURL(for entry: WallpaperEntry) throws -> URL {
        guard case .builtIn(let artwork) = entry else { return try existingURL(for: entry) }
        let url = try libraryDirectory().appendingPathComponent("built-in-\(artwork.rawValue).jpg")
        if !fileManager.fileExists(atPath: url.path) {
            guard let image = artwork.makeImage(width: 3_840) else { throw LibraryError.unavailable }
            try writeJPEG(image, to: url)
        }
        try validateRegularFile(url)
        return url
    }

    private func importImage(_ url: URL, into directory: URL) throws -> WallpaperEntry {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let image = try image(at: url, maximumEdge: Self.maximumWallpaperEdge)
        let basename = url.deletingPathExtension().lastPathComponent
        let title = String(basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\"
        }.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(UUID().uuidString)-\(title.isEmpty ? "Wallpaper" : title).jpg"
        try writeJPEG(image, to: directory.appendingPathComponent(filename))
        return .imported(filename)
    }

    private func image(at url: URL, maximumEdge: Int) throws -> CGImage {
        try validateRegularFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              Self.importTypes.contains(where: { $0.identifier == type as String }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maximumSourcePixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge
              ] as CFDictionary) else { throw LibraryError.invalidImage }
        return image
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LibraryError.unavailable
        }
        // Re-encode the oriented pixels without copying camera or location metadata.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImageDestinationBackgroundColor: CGColor(gray: 0.12, alpha: 1)
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= Self.maximumFileBytes else {
            throw LibraryError.unavailable
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    private func validateRegularFile(_ url: URL) throws {
        guard url.isFileURL else { throw LibraryError.invalidImage }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumFileBytes else {
            throw LibraryError.invalidImage
        }
    }

    private func existingURL(for entry: WallpaperEntry) throws -> URL {
        guard case .imported(let name) = entry, Self.isImportedName(name) else { throw LibraryError.unavailable }
        let url = try libraryDirectory().appendingPathComponent(name)
        try validateRegularFile(url)
        return url
    }

    private static func isImportedName(_ name: String) -> Bool {
        name.hasSuffix(".jpg") && name.count > 41
            && UUID(uuidString: String(name.prefix(36))) != nil
            && name.dropFirst(36).first == "-"
            && !name.contains("/") && !name.contains("\\")
    }

    private func libraryDirectory(create: Bool = true) throws -> URL {
        let support = supportDirectory.resolvingSymlinksInPath()
        let snow = support.appendingPathComponent("Snowy", isDirectory: true)
        let directory = snow.appendingPathComponent("Wallpapers", isDirectory: true)
        for folder in [snow, directory] {
            guard folder.resolvingSymlinksInPath().path == folder.path else { throw LibraryError.unavailable }
            if create {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
        }
        return directory
    }
}
