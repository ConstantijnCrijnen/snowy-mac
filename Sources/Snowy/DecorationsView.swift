import SwiftUI

struct DecorationsView: View {
    @Bindable var settings: DecorationSettings
    var resetDecorations: () -> Void
    var openEditor: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Decorations")
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Choose a pixel-art layout for your desktop. Snow settles on the pieces as it falls.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 14)
                    Button("Turn Off") { settings.selectPreset(.none) }
                        .disabled(settings.layout == .none && !settings.usesCustomScenes)
                    Button("Edit Scene…", action: openEditor)
                        .buttonStyle(.borderedProminent)
                }

                if settings.usesCustomScenes {
                    Label("Custom scene active", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(DecorationLayout.allCases.filter { $0 != .none }) { layout in
                        layoutCard(layout)
                    }
                }

                GroupBox(settings.usesCustomScenes ? "On the desktop" : "Preset settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if !settings.usesCustomScenes {
                            HStack(spacing: 16) {
                                Slider(value: $settings.scale, in: DecorationSettings.scaleRange, step: 0.05) {
                                    Text("Size")
                                }
                                Text(settings.scale, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 42, alignment: .trailing)
                                    .accessibilityHidden(true)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            if !settings.usesCustomScenes {
                                Toggle("Push with Cursor", isOn: $settings.pushes)
                            }
                            Spacer()
                            Button("Reset Positions", action: resetDecorations)
                                .disabled(settings.layout == .none && !settings.usesCustomScenes)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(26)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func layoutCard(_ layout: DecorationLayout) -> some View {
        let selected = !settings.usesCustomScenes && settings.layout == layout
        return Button {
            settings.selectPreset(layout)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                DecorationThumbnail(pieces: layout.pieces)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layout.title).font(.headline)
                        Text(layout.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.background)
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.22),
                                  lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DecorationThumbnail: View {
    let pieces: [DecorationPiece]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color(red: 0.94, green: 0.43, blue: 0.38), .yellow, .green], id: \.self) { color in
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(LinearGradient(colors: [Color(white: 0.96), Color(red: 0.69, green: 0.75, blue: 0.80)],
                                       startPoint: .top, endPoint: .bottom))

            GeometryReader { geometry in
                let gap: CGFloat = 6
                let pixelWidth = CGFloat(pieces.reduce(0) { $0 + $1.image.width })
                let pixelHeight = CGFloat(pieces.map { $0.image.height }.max() ?? 1)
                let availableWidth = geometry.size.width - 20 - gap * CGFloat(max(0, pieces.count - 1))
                let scale = max(0.1, min(availableWidth / max(1, pixelWidth), (geometry.size.height - 12) / pixelHeight))

                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(red: 0.09, green: 0.17, blue: 0.29),
                                            Color(red: 0.30, green: 0.44, blue: 0.59)],
                                   startPoint: .top, endPoint: .bottom)
                    Canvas { context, size in
                        for index in 0..<19 {
                            let x = size.width * Double((index * 37 + 13) % 97) / 97
                            let y = size.height * Double((index * 23 + 8) % 67) / 76
                            let rect = CGRect(x: x, y: y, width: 1, height: 1)
                            context.fill(Path(rect), with: .color(.white.opacity(0.58)))
                        }
                    }
                    Rectangle().fill(Color(red: 0.83, green: 0.89, blue: 0.94))
                        .frame(height: 6)
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                            Image(decorative: piece.image, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: CGFloat(piece.image.width) * scale,
                                       height: CGFloat(piece.image.height) * scale)
                        }
                    }
                    .padding(.bottom, 5)
                }
            }
            .frame(height: 86)
        }
        .accessibilityHidden(true)
    }
}
