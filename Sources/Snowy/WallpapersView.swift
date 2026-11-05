import AppKit
import SwiftUI

struct WallpapersView: View {
    private enum DisplayTarget: Hashable {
        case all
        case display(UInt32)
    }

    private struct Display: Identifiable {
        let id: UInt32
        let name: String
    }

    private let starters = WinterWallpaper.allCases.map(WallpaperEntry.builtIn)
    @State private var imported: [WallpaperEntry] = []
    @State private var selected = WallpaperEntry.builtIn(.blueHour)
    @State private var displays: [Display] = []
    @State private var target = DisplayTarget.all
    @State private var showsImporter = false
    @State private var isWorking = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Wallpapers")
                                .font(.largeTitle.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text("Pick a backdrop for the snow.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import Images…", systemImage: "plus") { showsImporter = true }
                            .disabled(isWorking)
                    }

                    gallery("Winter collection", entries: starters)
                    if !imported.isEmpty {
                        gallery("Your images", entries: imported)
                    }
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack(spacing: 12) {
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if displays.count > 1 {
                    Picker("Display", selection: $target) {
                        Text("All displays").tag(DisplayTarget.all)
                        ForEach(displays) { display in
                            Text(display.name).tag(DisplayTarget.display(display.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 164)
                }
                Button("Set Wallpaper", action: applyWallpaper)
                    .buttonStyle(.borderedProminent)
                    .disabled(displays.isEmpty)
            }
            .disabled(isWorking)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: WallpaperLibrary.importTypes,
                      allowsMultipleSelection: true, onCompletion: importImages)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            updateDisplays()
        }
        .task {
            updateDisplays()
            do {
                imported = try await WallpaperLibrary.shared.importedEntries()
            } catch {
                status = "Couldn’t open the wallpaper library."
            }
        }
    }

    private func gallery(_ title: String, entries: [WallpaperEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: 2),
                      alignment: .leading, spacing: 15) {
                ForEach(entries) { entry in
                    WallpaperTile(entry: entry, isSelected: entry == selected) {
                        selected = entry
                        status = nil
                    }
                }
            }
            .disabled(isWorking)
        }
    }

    private func importImages(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            status = "Couldn’t read the selected images."
            return
        }
        guard !urls.isEmpty else { return }
        isWorking = true
        status = "Importing images…"
        Task {
            defer { isWorking = false }
            do {
                let result = try await WallpaperLibrary.shared.importImages(urls)
                imported = result.entries
                if let first = result.added.first { selected = first }
                if result.added.count == urls.count {
                    status = nil
                } else if imported.count >= WallpaperLibrary.importLimit {
                    status = "The library holds up to \(WallpaperLibrary.importLimit) imported wallpapers."
                } else {
                    status = "Some images couldn’t be imported. Choose readable images under 64 MB and 80 megapixels."
                }
            } catch {
                status = "Couldn’t save images to the wallpaper library."
            }
        }
    }

    private func applyWallpaper() {
        let entry = selected
        let destination = target
        isWorking = true
        status = "Setting wallpaper…"
        Task {
            defer { isWorking = false }
            do {
                let file = try await WallpaperLibrary.shared.fileURL(for: entry)
                let screens = NSScreen.screens.filter { screen in
                    switch destination {
                    case .all: true
                    case .display(let id): Self.displayID(screen) == id
                    }
                }
                guard !screens.isEmpty else {
                    status = "The selected display is unavailable."
                    return
                }
                let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true
                ]
                var applied = 0
                for screen in screens {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
                        applied += 1
                    } catch {
                        continue
                    }
                }
                if applied == screens.count {
                    status = "Wallpaper set."
                } else if applied > 0 {
                    status = "Wallpaper set on \(applied) of \(screens.count) displays."
                } else {
                    status = "macOS couldn’t set this wallpaper."
                }
            } catch {
                status = "Couldn’t open this wallpaper."
            }
        }
    }

    private func updateDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            Self.displayID(screen).map { Display(id: $0, name: screen.localizedName) }
        }
        if case .display(let id) = target, !displays.contains(where: { $0.id == id }) {
            target = .all
        }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private struct WallpaperTile: View {
    let entry: WallpaperEntry
    let isSelected: Bool
    let select: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                Color(nsColor: .controlBackgroundColor)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let image {
                            GeometryReader { geometry in
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 2 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 18))
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                    }
                Text(entry.title)
                    .lineLimit(1)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task {
            if image == nil {
                image = await WallpaperLibrary.shared.thumbnail(for: entry)
            }
        }
    }
}
