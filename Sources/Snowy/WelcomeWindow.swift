import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Snowy"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView { [weak self] in
            self?.close()
        })
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

enum WelcomeStep: Int, CaseIterable {
    case desktop, wind, menu

    var title: String {
        switch self {
        case .desktop: "Snow on your desktop"
        case .wind: "Sweep snow and set the wind"
        case .menu: "Snowy in the menu bar"
        }
    }

    var detail: String {
        switch self {
        case .desktop: "Snow settles on windows, widgets, and the bottom Dock. When you move a window, its snow moves with it."
        case .wind: "Sweep across a pile with your pointer. For a wider sweep, choose Shovel from Cursor Tool."
        case .menu: "Click the snowflake in the menu bar to change snowfall, pause it, or clear settled snow."
        }
    }

    var secondaryDetail: String? {
        switch self {
        case .desktop: nil
        case .wind: "Choose Wind… and drag the arrow to set its direction and strength."
        case .menu: "Choose Open Snowy… for wallpapers, decorations, and the Guide."
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "snowflake"
        case .wind: "wind"
        case .menu: "menubar.rectangle"
        }
    }
}

struct WelcomeView: View {
    static let contentSize = CGSize(width: 680, height: 320)
    @State private var step: WelcomeStep
    let onFinish: () -> Void

    init(initialPage: Int = 0, onFinish: @escaping () -> Void) {
        _step = State(initialValue: WelcomeStep(rawValue: initialPage) ?? .desktop)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 32) {
                WelcomePreview(step: step)
                    .frame(width: 284, height: 208)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(step.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(step.detail)
                        .foregroundStyle(.secondary)
                    if let secondaryDetail = step.secondaryDetail {
                        Text(secondaryDetail)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button("Skip", action: onFinish)
                Spacer()
                if let previous = WelcomeStep(rawValue: step.rawValue - 1) {
                    Button("Back") { step = previous }
                }
                Button(step == .menu ? "Let it snow" : "Continue") {
                    if let next = WelcomeStep(rawValue: step.rawValue + 1) {
                        step = next
                    } else {
                        onFinish()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .overlay {
                Text("\(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onFinish)
    }
}

/// Feature previews drawn from sample content.
private struct WelcomePreview: View {
    let step: WelcomeStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoFinished = true
    private let surface = Color(nsColor: .controlBackgroundColor)
    private let divider = Color(nsColor: .separatorColor)

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            switch step {
            case .desktop: desktop
            case .wind: wind
            case .menu: menu
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(divider, lineWidth: 1) }
        .task(id: step) {
            demoFinished = reduceMotion || step == .menu
            guard !demoFinished else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeInOut(duration: 0.45)) { demoFinished = true }
            } catch {
                // Leaving the page cancels its preview.
            }
        }
    }

    private var desktop: some View {
        ZStack {
            Color(red: 0.49, green: 0.55, blue: 0.62)
            ForEach(0..<19) { index in
                Circle()
                    .fill(.white.opacity(index.isMultiple(of: 4) ? 0.85 : 0.48))
                    .frame(width: index.isMultiple(of: 4) ? 3 : 2)
                    .offset(x: CGFloat((index * 71) % 264) - 132,
                            y: CGFloat((index * 67 + index * index * 7) % 188) - 94)
            }
            sampleWindow("Notes", width: 150, height: 92)
                .offset(x: demoFinished ? -34 : -56, y: -22)
            sampleWindow("Finder", width: 120, height: 69)
                .offset(x: 49, y: 36)
            Image(systemName: "cursorarrow")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.black)
                .shadow(color: .white.opacity(0.7), radius: 0, x: 1, y: 1)
                .offset(x: demoFinished ? 18 : -4, y: -64)
        }
    }

    private func sampleWindow(_ title: String, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .overlay(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { color in
                            Circle().fill(color.opacity(0.75)).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.leading, 7)
                }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.secondary.opacity(0.25)).frame(width: width * 0.44, height: 3)
                Capsule().fill(.secondary.opacity(0.13)).frame(width: width * 0.63, height: 3)
                Capsule().fill(.secondary.opacity(0.13)).frame(width: width * 0.36, height: 3)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .background(surface)
        .clipShape(.rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(divider, lineWidth: 1) }
        .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
        .overlay(alignment: .top) {
            SnowCap()
                .fill(.white)
                .frame(width: width - 8, height: 10)
                .offset(y: -9)
        }
    }

    private var wind: some View {
        VStack(spacing: 9) {
            Text("Wind")
                .font(.system(size: 11, weight: .semibold))
            ZStack {
                RoundedRectangle(cornerRadius: 11).strokeBorder(divider, lineWidth: 1)
                VStack(spacing: 14) {
                    ForEach(0..<5) { _ in
                        HStack(spacing: 14) {
                            ForEach(0..<5) { _ in
                                Circle().fill(.secondary.opacity(0.27)).frame(width: 2, height: 2)
                            }
                        }
                    }
                }
                Path { path in
                    path.move(to: CGPoint(x: 53, y: 53))
                    path.addLine(to: CGPoint(x: 79, y: 27))
                    path.move(to: CGPoint(x: 65, y: 28))
                    path.addLine(to: CGPoint(x: 79, y: 27))
                    path.addLine(to: CGPoint(x: 78, y: 41))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .scaleEffect(demoFinished ? 1 : 0.55)
                .rotationEffect(.degrees(demoFinished ? 0 : -32))
                Circle().fill(Color.accentColor).frame(width: 4, height: 4)
            }
            .frame(width: 106, height: 106)
            Text("68% · NE")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .padding(13)
        .background(surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(divider, lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    }

    private var menu: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Text("File")
                Text("Edit")
                Spacer()
                Image(systemName: "snowflake")
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 17)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                Text("9:41")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(surface)
            .overlay(alignment: .bottom) { Divider() }

            VStack(alignment: .leading, spacing: 7) {
                Text("Snowy").fontWeight(.semibold)
                Divider()
                Text("Open Snowy…")
                Text("Pause Snow")
                Text("Clear Settled Snow")
                HStack {
                    Text("Cursor Tool")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Steady")
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
                Text("Wind…")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 142)
            .background(surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(divider, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 3)
            .padding(.trailing, 27)
            Spacer(minLength: 0)
        }
    }
}

private struct SnowCap: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addCurve(to: CGPoint(x: rect.width * 0.23, y: rect.height * 0.39),
                          control1: CGPoint(x: rect.width * 0.04, y: rect.height * 0.55),
                          control2: CGPoint(x: rect.width * 0.13, y: rect.height * 0.8))
            path.addCurve(to: CGPoint(x: rect.width * 0.53, y: rect.height * 0.48),
                          control1: CGPoint(x: rect.width * 0.33, y: -rect.height * 0.1),
                          control2: CGPoint(x: rect.width * 0.42, y: rect.height * 0.64))
            path.addCurve(to: CGPoint(x: rect.width, y: rect.height),
                          control1: CGPoint(x: rect.width * 0.75, y: rect.height * 0.1),
                          control2: CGPoint(x: rect.width * 0.95, y: rect.height * 0.45))
            path.closeSubpath()
        }
    }
}
