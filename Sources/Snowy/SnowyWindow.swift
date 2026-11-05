import AppKit
import SwiftUI

@MainActor
final class SnowyWindowController: NSWindowController {
    private var sceneEditor: SceneEditorWindowController?

    init(settings: DecorationSettings, resetDecorations: @escaping () -> Void,
         replayWalkthrough: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Snowy"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 710, height: 500)
        super.init(window: window)

        let hosting = NSHostingController(rootView: SnowyWindowView(
            settings: settings, resetDecorations: resetDecorations, replayWalkthrough: replayWalkthrough,
            openEditor: { [weak self] in self?.openSceneEditor(settings: settings) }
        ))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.center()
        window.setFrameAutosaveName("Snowy Settings")
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func openSceneEditor(settings: DecorationSettings) {
        if sceneEditor == nil {
            sceneEditor = SceneEditorWindowController(settings: settings, screen: window?.screen) { [weak self] in
                self?.sceneEditor = nil
            }
        }
        sceneEditor?.present()
    }
}

struct SnowyWindowView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case wallpapers = "Wallpapers"
        case decorations = "Decorations"
        case guide = "Guide"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .wallpapers: "photo.on.rectangle"
            case .decorations: "tree"
            case .guide: "book"
            }
        }
    }

    var settings: DecorationSettings
    var resetDecorations: () -> Void
    var replayWalkthrough: () -> Void
    var openEditor: () -> Void
    @State private var page: Page? = .decorations

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 182, max: 210)
        } detail: {
            switch page ?? .decorations {
            case .wallpapers:
                WallpapersView()
            case .decorations:
                DecorationsView(settings: settings, resetDecorations: resetDecorations, openEditor: openEditor)
            case .guide:
                SnowyGuideView(replayWalkthrough: replayWalkthrough)
            }
        }
    }
}

private struct SnowyGuideView: View {
    var replayWalkthrough: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Guide").font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Replay Walkthrough", action: replayWalkthrough)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(WelcomeStep.allCases, id: \.self) { step in
                            if step != .desktop { Divider() }
                            guideRow(step.title, symbol: step.symbol, detail: step.detail,
                                     note: step.secondaryDetail)
                        }
                    }
                    .padding(8)
                } label: {
                    Text("Snow controls")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 15) {
                        guideRow("Set a wallpaper", symbol: "photo.on.rectangle",
                                 detail: "Choose an image in Wallpapers or import your own, then apply it to your display.")
                        Divider()
                        guideRow("Decorate the desktop", symbol: "tree",
                                 detail: "Choose a preset or open Edit Scene to place props and hang lights. Enable Push with Cursor to slide a prop, and use Reset Positions to put the scene back.")
                    }
                    .padding(8)
                } label: {
                    Text("Make it yours")
                }
            }
            .padding(26)
            .frame(maxWidth: 740, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func guideRow(_ title: String, symbol: String, detail: String, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
                if let note { Text(note).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
