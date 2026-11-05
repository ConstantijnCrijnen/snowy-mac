import SwiftUI

private struct SceneLibraryDrop: DropDelegate {
    let accepts: () -> Bool
    let hover: (CGPoint?) -> Void
    let place: (CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool { accepts() }
    func dropEntered(info: DropInfo) { hover(accepts() ? info.location : nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepts = accepts()
        hover(accepts ? info.location : nil)
        return DropProposal(operation: accepts ? .copy : .forbidden)
    }
    func dropExited(info: DropInfo) { hover(nil) }
    func performDrop(info: DropInfo) -> Bool {
        hover(nil)
        return accepts() && place(info.location)
    }
}

struct StringLightsCardArt: View {
    var body: some View {
        Canvas { context, size in
            let cable = Path { path in
                path.move(to: CGPoint(x: 1, y: 6))
                path.addQuadCurve(to: CGPoint(x: size.width - 1, y: 6),
                                  control: CGPoint(x: size.width / 2, y: size.height))
            }
            context.stroke(cable, with: .color(Color(red: 0.46, green: 0.62, blue: 0.55)), lineWidth: 1.5)
            for (index, rgb) in LightPalette.classic.colors.enumerated() {
                let x = size.width * CGFloat(index + 1) / 6
                let t = x / size.width
                let y = 6 + 2 * (size.height - 6) * t * (1 - t)
                let bulb = CGRect(x: x - 2.5, y: y, width: 5, height: 7)
                let color = Color(red: Double((rgb >> 16) & 255) / 255,
                                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
                context.fill(Path(ellipseIn: bulb.insetBy(dx: -2.5, dy: -2.5)), with: .color(color.opacity(0.24)))
                context.fill(Path(ellipseIn: bulb), with: .color(color))
            }
        }
    }
}

struct SceneEditorCanvas: View {
    var desktop: SceneDesktop
    @Binding var scene: DecorationScene
    @Binding var selection: SceneSelection?
    @Binding var joint: Int
    @Binding var libraryDrag: SceneLibraryDrag?
    @State private var dropPoint: CGPoint?
    @State private var grabbedProp: (id: UUID, offset: CGFloat)?

    private enum Placement {
        case prop(PlacedDecoration, DecorationPiece)
        case lights(LightString)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 0.94, green: 0.43, blue: 0.38)).frame(width: 6, height: 6)
                Circle().fill(.yellow).frame(width: 6, height: 6)
                Circle().fill(.green).frame(width: 6, height: 6)
                Spacer()
                Text("Desktop Preview").font(.caption2.weight(.medium)).foregroundStyle(.black.opacity(0.68))
                Spacer()
                Color.clear.frame(width: 28, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(LinearGradient(colors: [Color(white: 0.96), Color(red: 0.69, green: 0.75, blue: 0.80)],
                                       startPoint: .top, endPoint: .bottom))
            GeometryReader { geometry in
                let factor = min(geometry.size.width / max(1, desktop.size.width),
                                 geometry.size.height / max(1, desktop.size.height))
                if factor > 0 {
                    board(scale: factor)
                        .frame(width: desktop.size.width * factor, height: desktop.size.height * factor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(red: 0.08, green: 0.14, blue: 0.23))
        }
        .clipShape(.rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.18)) }
    }

    private func board(scale: CGFloat) -> some View {
        let ghost = dropPoint.flatMap { placement(at: $0, scale: scale) }
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.11, green: 0.20, blue: 0.35),
                                    Color(red: 0.32, green: 0.46, blue: 0.60)],
                           startPoint: .top, endPoint: .bottom)
                .onTapGesture { selection = nil }
            geometryMarkers(scale: scale)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Canvas { context, _ in
                for light in scene.lights {
                    drawLights(light, in: context, scale: scale)
                }
                if case .lights(let light) = ghost {
                    var translucent = context
                    translucent.opacity = 0.60
                    drawLights(light, in: translucent, scale: scale)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ForEach(scene.props) { prop in
                if let piece = DecorationCatalog.piece(prop.assetID) {
                    propView(prop, piece: piece, scale: scale)
                }
            }
            ForEach(scene.lights) { light in
                ForEach(light.anchors.indices, id: \.self) { index in
                    handle(light, index: index, scale: scale)
                }
            }
            if case .prop(let prop, let piece) = ghost {
                let frame = DecorationPlacement.frame(for: prop, piece: piece, desktopSize: desktop.size,
                                                      dock: desktop.dock)
                Image(decorative: piece.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .opacity(0.63)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color(red: 0.53, green: 0.84, blue: 1))
                            .frame(height: 2)
                            .offset(y: 1)
                    }
                    .position(x: frame.midX * scale, y: frame.midY * scale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: "sceneBoard")
        .contentShape(Rectangle())
        .onDrop(of: [SceneLibraryDrag.contentType], delegate: SceneLibraryDrop(
            accepts: { canPlace },
            hover: { dropPoint = $0 },
            place: { point in
                defer { libraryDrag = nil }
                guard let placement = placement(at: point, scale: scale) else { return false }
                switch placement {
                case .prop(let prop, _):
                    scene.props.append(prop)
                    selection = .prop(prop.id)
                case .lights(let lights):
                    scene.lights.append(lights)
                    selection = .lights(lights.id)
                    joint = 1
                }
                return true
            }
        ))
        .overlay {
            Rectangle().strokeBorder(ghost != nil ? Color.accentColor : Color.white.opacity(0.25),
                                     lineWidth: ghost != nil ? 2 : 1)
                .allowsHitTesting(false)
        }
        .clipped()
    }

    private var canPlace: Bool {
        guard let item = libraryDrag else { return false }
        return item.assetID == LightString.dragIdentifier
            ? scene.lights.count < DecorationScene.maxLights
            : scene.props.count < DecorationScene.maxProps && DecorationCatalog.piece(item.assetID) != nil
    }

    private func placement(at point: CGPoint, scale: CGFloat) -> Placement? {
        guard let item = libraryDrag, canPlace else { return nil }
        let location = CGPoint(x: point.x / scale, y: point.y / scale)
        if item.assetID == LightString.dragIdentifier {
            var lights = LightString.placed(near: location, in: desktop)
            lights.id = item.id
            return .lights(lights)
        }
        guard let piece = DecorationCatalog.piece(item.assetID) else { return nil }
        let prop = PlacedDecoration(id: item.id, assetID: piece.id, x: normalizedX(location.x),
                                    pushes: piece.movesByDefault,
                                    support: DecorationPlacement.support(at: location, dock: desktop.dock))
        return .prop(prop, piece)
    }

    private func drawLights(_ light: LightString, in context: GraphicsContext, scale: CGFloat) {
        let preview = light.previewPoints(in: desktop)
        let points = preview.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let first = points.first else { return }
        let cable = Path { path in
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        context.stroke(cable, with: .color(Color(red: 0.06, green: 0.16, blue: 0.18)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        let palette = light.palette.colors
        for bulb in light.bulbs(along: preview) {
            let width = max(1.25, bulb.width * scale)
            let height = max(1.6, bulb.height * scale)
            let rect = CGRect(x: bulb.point.x * scale - width / 2, y: bulb.point.y * scale + 1,
                              width: width, height: height)
            let rgb = palette[bulb.colorIndex]
            let color = Color(red: Double((rgb >> 16) & 255) / 255,
                              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -1.7, dy: -1.7)), with: .color(color.opacity(0.24)))
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    @ViewBuilder
    private func geometryMarkers(scale: CGFloat) -> some View {
        if let dock = desktop.dock {
            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(0.24))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.38)) }
                .overlay { Text("Dock").font(.caption2).foregroundStyle(.white.opacity(0.9)) }
                .frame(width: dock.width * scale, height: dock.height * scale)
                .position(x: dock.midX * scale, y: dock.midY * scale)
        }
        ForEach(desktop.anchors) { target in
            let bounds = target.bounds
            RoundedRectangle(cornerRadius: target.kind == .widget ? 8 : 3)
                .fill(.white.opacity(target.kind == .widget ? 0.18 : 0.32))
                .overlay {
                    RoundedRectangle(cornerRadius: target.kind == .widget ? 8 : 3)
                        .strokeBorder(.white.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                .overlay {
                    if bounds.width * scale > 42 {
                        Text(target.kind.title).font(.caption2).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: bounds.width * scale, height: bounds.height * scale)
                .position(x: bounds.midX * scale, y: bounds.midY * scale)
        }
    }

    private func propView(_ prop: PlacedDecoration, piece: DecorationPiece, scale: CGFloat) -> some View {
        let frame = DecorationPlacement.frame(for: prop, piece: piece, desktopSize: desktop.size, dock: desktop.dock)
        let selected = selection == .prop(prop.id)
        return Image(decorative: piece.image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: frame.width * scale, height: frame.height * scale)
            .padding(2)
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = .prop(prop.id) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("sceneBoard"))
                .onChanged { drag in
                    guard let index = scene.props.firstIndex(where: { $0.id == prop.id }) else { return }
                    selection = .prop(prop.id)
                    if grabbedProp?.id != prop.id {
                        grabbedProp = (prop.id, frame.midX - drag.startLocation.x / scale)
                    }
                    let position = CGPoint(x: drag.location.x / scale + (grabbedProp?.offset ?? 0),
                                           y: drag.location.y / scale)
                    scene.props[index].x = normalizedX(position.x)
                    scene.props[index].support = DecorationPlacement.support(at: position, dock: desktop.dock)
                }
                .onEnded { drag in
                    grabbedProp = nil
                    let bounds = CGRect(origin: .zero, size: CGSize(width: desktop.size.width * scale,
                                                                   height: desktop.size.height * scale))
                    if !bounds.insetBy(dx: -8, dy: -8).contains(drag.location) {
                        scene.props.removeAll { $0.id == prop.id }
                        selection = nil
                    }
                })
            .accessibilityLabel(piece.name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = .prop(prop.id) }
            .position(x: frame.midX * scale, y: frame.midY * scale)
    }

    private func handle(_ light: LightString, index: Int, scale: CGFloat) -> some View {
        let point = light.anchors[index].position(in: desktop)
        let selected = selection == .lights(light.id) && joint == index
        return Button {
            selection = .lights(light.id)
            joint = index
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .frame(width: 16, height: 16)
                .background(selected ? Color.accentColor : Color(red: 0.17, green: 0.27, blue: 0.38), in: Circle())
                .foregroundStyle(.white)
                .overlay { Circle().strokeBorder(.white.opacity(0.8)) }
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Light joint \(index + 1)")
        .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("sceneBoard"))
            .onChanged { drag in
                guard let string = scene.lights.firstIndex(where: { $0.id == light.id }),
                      scene.lights[string].anchors.indices.contains(index) else { return }
                selection = .lights(light.id)
                joint = index
                let raw = CGPoint(x: drag.location.x / scale, y: drag.location.y / scale)
                scene.lights[string].anchors[index] = .snapped(near: raw, in: desktop, distance: 14 / scale)
            })
        .position(x: min(desktop.size.width * scale - 11, max(11, point.x * scale)),
                  y: min(desktop.size.height * scale - 11, max(11, point.y * scale)))
    }

    private func normalizedX(_ x: CGFloat) -> Double {
        min(1, max(0, x / max(1, desktop.size.width)))
    }
}
