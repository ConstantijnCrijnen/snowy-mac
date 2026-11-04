import AppKit
import SnowCore

/// Direct manipulation with a short-lived spring only after an elastic pull.
@MainActor
final class WindPad: NSControl {
    var settings = WindSettings() {
        didSet {
            needsDisplay = true
            setAccessibilityValue(settings.summary)
            if !pressed && !stretch.isSettling { stretch.snap(to: settings.speedFraction) }
        }
    }
    var onChange: ((WindSettings) -> Void)?
    var onClose: (() -> Void)?
    private var pressed = false
    private var stretch = StretchyWind()
    private var springTimer: Timer?
    private var previousTick: TimeInterval = 0
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Wind direction and strength")
        setAccessibilityHelp("Drag from the center to rotate and stretch the arrow. Left and right rotate; up and down change strength. Space resets to calm.")
        setAccessibilityValue(settings.summary)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Increase wind strength") { [weak self] in
                MainActor.assumeIsolated { self?.adjust(strength: 0.05); return self != nil }
            },
            NSAccessibilityCustomAction(name: "Decrease wind strength") { [weak self] in
                MainActor.assumeIsolated { self?.adjust(strength: -0.05); return self != nil }
            },
            NSAccessibilityCustomAction(name: "Rotate wind clockwise") { [weak self] in
                MainActor.assumeIsolated { self?.adjust(angle: 15); return self != nil }
            },
            NSAccessibilityCustomAction(name: "Rotate wind counterclockwise") { [weak self] in
                MainActor.assumeIsolated { self?.adjust(angle: -15); return self != nil }
            },
            NSAccessibilityCustomAction(name: "Reset wind to calm") { [weak self] in
                MainActor.assumeIsolated { self?.commit(WindSettings()); return self != nil }
            }
        ])
    }

    required init?(coder: NSCoder) { nil }

    private var pivot: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var maximumLength: CGFloat { min(bounds.width, bounds.height) * 0.37 }

    func stopMotion() {
        springTimer?.invalidate()
        springTimer = nil
        pressed = false
        stretch.snap(to: settings.speedFraction)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopMotion() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22)
        NSColor.controlBackgroundColor.withAlphaComponent(0.62).setFill()
        card.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        card.lineWidth = 0.75
        card.stroke()

        let spacing: CGFloat = 28
        NSColor.secondaryLabelColor.withAlphaComponent(0.26).setFill()
        for row in -2...2 {
            for column in -2...2 where row != 0 || column != 0 {
                let point = CGPoint(x: pivot.x + CGFloat(column) * spacing, y: pivot.y + CGFloat(row) * spacing)
                NSBezierPath(ovalIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)).fill()
            }
        }

        let vector = settings.vector
        let length = CGFloat(stretch.length) * maximumLength
        let magnitude = max(0.0001, settings.speedFraction)
        let end = CGPoint(x: pivot.x + CGFloat(vector.x / magnitude) * length,
                          y: pivot.y + CGFloat(vector.y / magnitude) * length)
        let tint = NSColor.controlAccentColor
        if length >= 4 {
            let unit = CGVector(dx: (end.x - pivot.x) / length, dy: (end.y - pivot.y) / length)
            let normal = CGVector(dx: -unit.dy, dy: unit.dx)
            let headLength = min(14, max(6, length * 0.4)) * CGFloat(stretch.thicknessScale)
            let halfHeadWidth = headLength * 0.58
            let arrow = NSBezierPath()
            arrow.lineWidth = (pressed ? 5.4 : 5) * CGFloat(stretch.thicknessScale)
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: pivot)
            arrow.line(to: end)
            arrow.move(to: CGPoint(x: end.x - unit.dx * headLength + normal.dx * halfHeadWidth,
                                  y: end.y - unit.dy * headLength + normal.dy * halfHeadWidth))
            arrow.line(to: end)
            arrow.line(to: CGPoint(x: end.x - unit.dx * headLength - normal.dx * halfHeadWidth,
                                  y: end.y - unit.dy * headLength - normal.dy * halfHeadWidth))
            tint.setStroke()
            arrow.stroke()
            // A quiet hit-target cue appears only while the user holds the arrow.
            if pressed {
                tint.withAlphaComponent(0.12).setFill()
                NSBezierPath(ovalIn: CGRect(x: end.x - 14, y: end.y - 14, width: 28, height: 28)).fill()
            }
        }
        tint.withAlphaComponent(length < 4 ? 0.65 : 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: pivot.x - 3.2, y: pivot.y - 3.2, width: 6.4, height: 6.4)).fill()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.65).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 21, yRadius: 21)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stopMotion()
        if event.clickCount >= 2 { commit(WindSettings()); return }
        pressed = true
        stretch.beginDrag(length: settings.speedFraction)
        update(from: event)
    }

    override func mouseDragged(with event: NSEvent) { update(from: event) }
    override func mouseUp(with event: NSEvent) {
        update(from: event)
        pressed = false
        stretch.release(to: settings.speedFraction,
                        reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        startSpringIfNeeded()
        needsDisplay = true
    }

    private func update(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var vector = SIMD2(Float((point.x - pivot.x) / maximumLength), Float((point.y - pivot.y) / maximumLength))
        if hypot(vector.x, vector.y) < 0.055 { vector = .zero }
        stretch.drag(to: hypot(vector.x, vector.y),
                     reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if event.modifierFlags.contains(.shift), vector != .zero {
            let heading = atan2(vector.x, -vector.y) * 180 / .pi
            commit(WindSettings(headingDegrees: (heading / 45).rounded() * 45,
                                speedFraction: hypot(vector.x, vector.y)))
        } else { commit(WindSettings(vector: vector)) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let fine = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123: adjust(angle: fine ? -1 : -15)
        case 124: adjust(angle: fine ? 1 : 15)
        case 126: adjust(strength: fine ? 0.01 : 0.05)
        case 125: adjust(strength: fine ? -0.01 : -0.05)
        case 49, 115: commit(WindSettings())
        case 53: stopMotion(); onClose?()
        default: super.keyDown(with: event)
        }
    }

    private func adjust(angle: Float = 0, strength: Float = 0) {
        stopMotion()
        let speed = max(angle == 0 ? 0 : 0.05, settings.speedFraction + strength)
        commit(WindSettings(headingDegrees: settings.headingDegrees + angle, speedFraction: speed))
    }

    private func commit(_ value: WindSettings) {
        guard value != settings else { return }
        settings = value
        onChange?(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func startSpringIfNeeded() {
        springTimer?.invalidate()
        springTimer = nil
        guard stretch.isSettling else { return }
        previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.window != nil else { self.stopMotion(); return }
                let now = ProcessInfo.processInfo.systemUptime
                let needsAnotherFrame = self.stretch.step(dt: Float(now - self.previousTick))
                self.previousTick = now
                self.needsDisplay = true
                if !needsAnotherFrame {
                    self.springTimer?.invalidate()
                    self.springTimer = nil
                }
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }
}

@MainActor
final class WindViewController: NSViewController {
    var onChange: ((WindSettings) -> Void)?
    var onClose: (() -> Void)?
    var settings: WindSettings {
        get { pad.settings }
        set { pad.settings = newValue; updateReadout() }
    }
    private let pad = WindPad(frame: CGRect(x: 20, y: 62, width: 216, height: 216))
    private let readout = NSTextField(labelWithString: "Calm")

    override func loadView() {
        let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 256, height: 350))
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        view = background

        let title = NSTextField(labelWithString: "Wind")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = CGRect(x: 46, y: 314, width: 112, height: 22)
        background.addSubview(title)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close wind control")!,
                             target: self, action: #selector(closeWind))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = CGRect(x: 17, y: 312, width: 24, height: 24)
        close.setAccessibilityLabel("Close wind control")
        background.addSubview(close)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetWind))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = CGRect(x: 176, y: 312, width: 62, height: 25)
        reset.setAccessibilityLabel("Reset wind to calm")
        background.addSubview(reset)

        pad.frame = CGRect(x: 20, y: 84, width: 216, height: 216)
        pad.onChange = { [weak self] value in
            self?.updateReadout()
            self?.onChange?(value)
        }
        pad.onClose = { [weak self] in self?.onClose?() }
        background.addSubview(pad)
        readout.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        readout.alignment = .center
        readout.frame = CGRect(x: 20, y: 53, width: 216, height: 20)
        background.addSubview(readout)

        let hint = NSTextField(labelWithString: "Drag from the center to set the wind")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = CGRect(x: 12, y: 22, width: 232, height: 17)
        background.addSubview(hint)
        preferredContentSize = background.frame.size
        updateReadout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pad)
    }

    override func viewWillDisappear() {
        pad.stopMotion()
        super.viewWillDisappear()
    }

    override func cancelOperation(_ sender: Any?) { closeWind() }

    @objc private func closeWind() {
        pad.stopMotion()
        onClose?()
    }

    @objc private func resetWind() {
        pad.stopMotion()
        settings = WindSettings()
        onChange?(settings)
    }

    private func updateReadout() { readout.stringValue = pad.settings.summary }
}
