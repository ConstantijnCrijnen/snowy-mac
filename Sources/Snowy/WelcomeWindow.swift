import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Snowy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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

/// Static vector illustrations keep the first-run window light. The initializer
/// also permits offscreen previews without opening a window or starting NSApp.
struct WelcomeView: View {
    @State private var page: Int
    let onFinish: () -> Void
    private let blue = Color(red: 0.12, green: 0.45, blue: 0.76)

    init(initialPage: Int = 0, onFinish: @escaping () -> Void) {
        _page = State(initialValue: min(2, max(0, initialPage)))
        self.onFinish = onFinish
    }

    private var title: String {
        ["Give snow somewhere to land.", "Make a little weather.", "Always in your menu bar."][page]
    }
    private var detail: String {
        ["Snow settles on windows, widgets and your bottom Dock.\nMove a window, and its snow comes along.",
         "Brush piles with your pointer, or choose Shovel for a wider sweep.\nStretch and turn the wind arrow to change the breeze.",
         "Click the snowflake to change snowfall, adjust wind,\npause the weather or clear the snow."][page]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "snowflake").foregroundStyle(blue)
                Text("Snowy").fontWeight(.medium)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 33)
            .padding(.bottom, 19)

            WelcomeIllustration(page: page)
                .frame(width: 460, height: 196)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(.primary)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 466)
                .padding(.top, 11)
            Spacer(minLength: 18)
            Divider().padding(.horizontal, 28)
            HStack(spacing: 11) {
                Button("Skip", action: onFinish)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .controlSize(.large)
                }
                Button(page == 2 ? "Let it snow" : "Continue") {
                    if page == 2 { onFinish() } else { page += 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .tint(blue)
            }
            .overlay(alignment: .center) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle().fill(index == page ? blue : Color.secondary.opacity(0.22))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(page + 1) of 3")
                .allowsHitTesting(false)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .frame(width: 540, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onFinish)
    }
}

private struct WelcomeIllustration: View {
    let page: Int
    private let blue = Color(red: 0.18, green: 0.49, blue: 0.76)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.87, green: 0.94, blue: 0.99),
                                              Color(red: 0.94, green: 0.97, blue: 0.99)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            switch page {
            case 0: snowScene
            case 1: windScene
            default: menuScene
            }
        }
    }

    private var snowScene: some View {
        ZStack {
            ForEach(0..<12) { index in
                Circle().fill(Color.white.opacity(0.95)).frame(width: index.isMultiple(of: 3) ? 4 : 3)
                    .offset(x: CGFloat((index * 71) % 416) - 208,
                            y: CGFloat((index * 47) % 158) - 84)
            }
            miniatureWindow(width: 206, height: 111)
                .rotationEffect(.degrees(-3))
                .offset(x: -28, y: 5)
            miniatureWindow(width: 122, height: 77)
                .rotationEffect(.degrees(4))
                .offset(x: 104, y: 44)
            SnowCap().fill(.white).frame(width: 203, height: 16)
                .rotationEffect(.degrees(-3)).offset(x: -28, y: -54)
            SnowCap().fill(.white).frame(width: 120, height: 12)
                .rotationEffect(.degrees(4)).offset(x: 104, y: 2)
            Image(systemName: "cursorarrow")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color(red: 0.18, green: 0.28, blue: 0.39))
                .shadow(color: .white, radius: 0, x: 1, y: 1)
                .offset(x: 34, y: -27)
        }
    }

    private func miniatureWindow(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(Color(red: 0.73, green: 0.81, blue: 0.86)).frame(width: 5, height: 5) }
                Spacer()
            }
            .padding(.horizontal, 11).frame(height: 23)
            .background(Color(red: 0.94, green: 0.97, blue: 0.99))
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(blue.opacity(0.13)).frame(width: width * 0.49, height: 5)
                Capsule().fill(blue.opacity(0.09)).frame(width: width * 0.66, height: 5)
                Capsule().fill(blue.opacity(0.09)).frame(width: width * 0.38, height: 5)
                Spacer(minLength: 0)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(blue.opacity(0.13), lineWidth: 1) }
        .shadow(color: blue.opacity(0.14), radius: 14, x: 0, y: 8)
    }

    private var windScene: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 13) {
                Label("Glove", systemImage: "hand.point.up.left.fill")
                Label("Shovel", systemImage: "cursorarrow.rays")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(blue.opacity(0.8))
            ZStack {
                RoundedRectangle(cornerRadius: 19).fill(.white.opacity(0.86))
                    .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(blue.opacity(0.14), lineWidth: 1) }
                    .shadow(color: blue.opacity(0.09), radius: 14, x: 0, y: 7)
                VStack(spacing: 20) {
                    ForEach(0..<5) { _ in
                        HStack(spacing: 20) {
                            ForEach(0..<5) { _ in Circle().fill(blue.opacity(0.22)).frame(width: 3, height: 3) }
                        }
                    }
                }
                Path { path in
                    path.move(to: CGPoint(x: 70, y: 85))
                    path.addLine(to: CGPoint(x: 112, y: 40))
                    path.move(to: CGPoint(x: 91, y: 42))
                    path.addLine(to: CGPoint(x: 112, y: 40))
                    path.addLine(to: CGPoint(x: 111, y: 62))
                }
                .stroke(blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                Circle().fill(blue).frame(width: 7, height: 7).offset(x: -5, y: 10)
            }
            .frame(width: 150, height: 150)
        }
    }

    private var menuScene: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Image(systemName: "apple.logo").font(.system(size: 12, weight: .medium))
                Text("Finder").font(.system(size: 10, weight: .semibold))
                Text("File").font(.system(size: 10))
                Text("Edit").font(.system(size: 10))
                Spacer()
                Image(systemName: "snowflake")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 25)
                    .background(blue, in: RoundedRectangle(cornerRadius: 5))
                Text("9:41").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color(red: 0.22, green: 0.34, blue: 0.43))
            VStack(alignment: .leading, spacing: 0) {
                Text("Snowy").font(.system(size: 11, weight: .semibold)).padding(.bottom, 10)
                Label("Pause Snow", systemImage: "pause").padding(.bottom, 9)
                Label("Clear Settled Snow", systemImage: "sparkles").padding(.bottom, 10)
                Divider().padding(.bottom, 9)
                HStack { Text("Steady"); Spacer(); Image(systemName: "checkmark").fontWeight(.semibold) }.padding(.bottom, 9)
                HStack { Text("Wind…"); Spacer(); Image(systemName: "arrow.up.right") }
            }
            .font(.system(size: 10))
            .foregroundStyle(Color(red: 0.22, green: 0.34, blue: 0.43))
            .padding(13)
            .frame(width: 170)
            .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(blue.opacity(0.13), lineWidth: 1) }
            .shadow(color: blue.opacity(0.14), radius: 13, x: 0, y: 6)
            .offset(x: -36, y: 39)
        }
        .frame(width: 330, height: 177, alignment: .top)
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
