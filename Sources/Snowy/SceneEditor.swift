import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneLibraryDrag {
    static let contentType = UTType(exportedAs: "app.snowy.desktop.editor-card", conformingTo: .data)

    let assetID: String
    let id = UUID()

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(assetID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor
final class SceneEditorWindowController: NSWindowController, NSWindowDelegate {
    private let settings: DecorationSettings
    private let onClose: () -> Void

    init(settings: DecorationSettings, screen: NSScreen?, onClose: @escaping () -> Void) {
        self.settings = settings
        self.onClose = onClose
        let area = (screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 820)
        let width = min(1240, area.width - 32)
        let height = min(850, area.height - 54)
        let window = NSWindow(contentRect: CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                                                   width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Scene Editor"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: min(780, width), height: min(530, height))
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: SceneEditor(settings: settings) { [weak self] in self?.close() })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrameAutosaveName("Snowy Scene Editor")
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        settings.onEditorVisibility?(true)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settings.onEditorVisibility?(false)
        onClose()
    }
}

enum SceneSelection: Equatable {
    case prop(UUID)
    case lights(UUID)
}

struct SceneEditor: View {
    @Bindable var settings: DecorationSettings
    var dismiss: () -> Void
    @State private var libraryDrag: SceneLibraryDrag?
    @State private var displayID: UInt32?
    @State private var drafts: [UInt32: DecorationScene] = [:]
    @State private var selection: SceneSelection?
    @State private var joint = 0
    @State private var saveFailed = false

    private var desktop: SceneDesktop? {
        settings.desktops.first(where: { $0.id == displayID }) ?? settings.desktops.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let desktop {
                let draft = binding(for: desktop)
                HSplitView {
                    library(scene: draft)
                        .frame(minWidth: 226, idealWidth: 278, maxWidth: 360)
                    VStack(spacing: 0) {
                        SceneEditorCanvas(desktop: desktop, scene: draft, selection: $selection, joint: $joint,
                                          libraryDrag: $libraryDrag)
                            .id(desktop.id)
                            .padding(14)
                            .frame(maxHeight: .infinity)
                        Divider()
                        inspector(scene: draft, desktop: desktop)
                            .frame(minHeight: 104, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No Display Available", systemImage: "display")
            }
            Divider()
            footer
        }
        .onChange(of: desktop?.id) {
            selection = nil
            joint = 0
        }
        .alert("Couldn’t Save the Scene", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes are still in the editor.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Desktop Layout")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Arrange your decorations and string lights.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if settings.desktops.count > 1 {
                Picker("Display", selection: Binding(get: { desktop?.id }, set: { displayID = $0 })) {
                    ForEach(Array(settings.desktops.enumerated()), id: \.element.id) { index, screen in
                        Text("Display \(index + 1)").tag(Optional(screen.id))
                    }
                }
                .frame(maxWidth: 174)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if settings.includesDesktopIcons && DesktopIconGeometry.isTrusted {
                Button("Hide Icon Anchors") { settings.includesDesktopIcons = false }
            } else {
                Button("Allow Icon Anchors…") {
                    settings.includesDesktopIcons = true
                    DesktopIconGeometry.requestAccess()
                }
                .help("Allow Snowy in Privacy & Security → Accessibility to use Finder icon edges")
            }
            if let desktop, settings.layout != .none {
                Button("Load Preset") {
                    drafts[desktop.id] = .preset(settings.layout, scale: settings.scale,
                                                 pushes: settings.pushes, in: desktop)
                    selection = nil
                }
                .help("Replace this draft with the selected preset")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply Scene") {
                guard let desktop else { return }
                var changes = drafts
                changes[desktop.id] = binding(for: desktop).wrappedValue
                if settings.saveScenes(changes) { dismiss() }
                else { saveFailed = true }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(desktop == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func binding(for desktop: SceneDesktop) -> Binding<DecorationScene> {
        Binding {
            drafts[desktop.id] ?? settings.scenes[desktop.id] ?? settings.configuration.scene(for: desktop)
        } set: { scene in
            drafts[desktop.id] = scene
        }
    }

    private func library(scene: Binding<DecorationScene>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decoration Library")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                    libraryCard("String Lights", id: LightString.dragIdentifier) {
                        guard let desktop else { return }
                        let lights = LightString.placed(near: CGPoint(x: desktop.size.width / 2, y: 0), in: desktop)
                        scene.wrappedValue.lights.append(lights)
                        selection = .lights(lights.id)
                        joint = 1
                    } artwork: {
                        StringLightsCardArt().frame(width: 64, height: 40)
                    }
                    .disabled(scene.wrappedValue.lights.count >= DecorationScene.maxLights)
                    ForEach(DecorationCatalog.all) { piece in
                        libraryCard(piece.name, id: piece.id) {
                            let x = min(0.82, 0.22 + Double(scene.wrappedValue.props.count) * 0.055)
                            let prop = PlacedDecoration(assetID: piece.id, x: x, pushes: piece.movesByDefault)
                            scene.wrappedValue.props.append(prop)
                            selection = .prop(prop.id)
                        } artwork: {
                            Image(decorative: piece.image, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 62, height: 56)
                        }
                        .disabled(scene.wrappedValue.props.count >= DecorationScene.maxProps)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.38))
    }

    private func libraryCard<Artwork: View>(_ name: String, id: String, add: @escaping () -> Void,
                                           @ViewBuilder artwork: () -> Artwork) -> some View {
        Button(action: add) {
            VStack(spacing: 0) {
                artwork()
                    .frame(maxWidth: .infinity)
                    .frame(height: 74)
                    .background(LinearGradient(colors: [Color(red: 0.14, green: 0.24, blue: 0.38),
                                                        Color(red: 0.28, green: 0.41, blue: 0.55)],
                                               startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .background(.background)
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.18)) }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(name)")
        .onDrag {
            let item = SceneLibraryDrag(assetID: id)
            libraryDrag = item
            return item.provider()
        } preview: {
            artwork().opacity(0.66).padding(4)
        }
    }

    @ViewBuilder
    private func inspector(scene: Binding<DecorationScene>, desktop: SceneDesktop) -> some View {
        switch selection {
        case .prop(let id):
            if let prop = scene.wrappedValue.props.first(where: { $0.id == id }) {
                propInspector(prop, scene: scene, desktop: desktop)
            }
        case .lights(let id):
            if let light = scene.wrappedValue.lights.first(where: { $0.id == id }) {
                lightInspector(light, scene: scene, desktop: desktop)
            }
        case nil:
            VStack(alignment: .leading, spacing: 5) {
                Text("Select a piece or light joint").font(.headline)
                Text("Drag a piece outside the desktop to remove it. You can also remove it here.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func propInspector(_ prop: PlacedDecoration, scene: Binding<DecorationScene>, desktop: SceneDesktop) -> some View {
        func field<Value>(_ keyPath: WritableKeyPath<PlacedDecoration, Value>) -> Binding<Value> {
            Binding {
                (scene.wrappedValue.props.first { $0.id == prop.id } ?? prop)[keyPath: keyPath]
            } set: { value in
                if let index = scene.wrappedValue.props.firstIndex(where: { $0.id == prop.id }) {
                    scene.wrappedValue.props[index][keyPath: keyPath] = value
                }
            }
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(DecorationCatalog.piece(prop.assetID)?.name ?? "Decoration").font(.headline)
                Spacer()
                Button("Remove", role: .destructive) {
                    scene.wrappedValue.props.removeAll { $0.id == prop.id }
                    selection = nil
                }
            }
            HStack(spacing: 14) {
                Slider(value: field(\.scale), in: DecorationSettings.scaleRange, step: 0.05) { Text("Size") }
                Text(prop.scale, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
                Toggle("Push with Cursor", isOn: field(\.pushes))
            }
            Picker("Surface", selection: field(\.support)) {
                ForEach(DecorationSupport.allCases) { support in
                    Text(support.title).tag(support).disabled(support == .dock && desktop.dock == nil)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    private func lightInspector(_ light: LightString, scene: Binding<DecorationScene>, desktop: SceneDesktop) -> some View {
        func field<Value>(_ keyPath: WritableKeyPath<LightString, Value>) -> Binding<Value> {
            Binding {
                (scene.wrappedValue.lights.first { $0.id == light.id } ?? light)[keyPath: keyPath]
            } set: { value in
                if let index = scene.wrappedValue.lights.firstIndex(where: { $0.id == light.id }) {
                    scene.wrappedValue.lights[index][keyPath: keyPath] = value
                }
            }
        }
        let anchors = field(\.anchors)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("String Lights").font(.headline)
                Spacer()
                Button("Add Joint") {
                    let insert = min(max(1, joint + 1), light.anchors.count - 1)
                    let start = light.anchors[insert - 1].position(in: desktop)
                    let end = light.anchors[insert].position(in: desktop)
                    let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 18)
                    anchors.wrappedValue.insert(.snapped(near: middle, in: desktop), at: insert)
                    joint = insert
                }
                .disabled(light.anchors.count >= DecorationScene.maxJoints)
                Button("Remove Joint") {
                    guard anchors.wrappedValue.indices.contains(joint), anchors.wrappedValue.count > 2 else { return }
                    anchors.wrappedValue.remove(at: joint)
                    joint = min(joint, anchors.wrappedValue.count - 1)
                }
                .disabled(light.anchors.count <= 2)
                Button("Remove Lights", role: .destructive) {
                    scene.wrappedValue.lights.removeAll { $0.id == light.id }
                    selection = nil
                }
            }
            HStack(spacing: 16) {
                Picker("Colors", selection: field(\.palette)) {
                    ForEach(LightPalette.allCases) { palette in Text(palette.title).tag(palette) }
                }
                .frame(maxWidth: 220)
                Slider(value: field(\.slack), in: LightString.slackRange) { Text("Slack") }
            }
            Text(jointDescription(for: light, desktop: desktop))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func jointDescription(for light: LightString, desktop: SceneDesktop) -> String {
        guard light.anchors.indices.contains(joint) else { return "Drag a numbered joint to move it." }
        let anchor = light.anchors[joint]
        let description: String
        switch anchor.attachment {
        case .desktop: description = "Desktop edge"
        case .object(let id, _, _):
            description = desktop.anchors.first(where: { $0.id == id }).map { "\($0.kind.title) edge" }
                ?? "Anchor unavailable"
        case nil: description = "Free point"
        }
        return "Joint \(joint + 1) · \(description)"
    }
}
