import AppKit
import SnowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var coordinator: DesktopCoordinator?
    private var statusItem: NSStatusItem?
    private let pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var weatherItems: [NSMenuItem] = []
    private var windPopover: NSPopover?
    private var toolItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        do {
            let coordinator = try DesktopCoordinator()
            self.coordinator = coordinator
            coordinator.onStateChange = { [weak self] in self?.updateMenu() }
        } catch {
            stateItem.title = "Metal is unavailable on this Mac"
            pauseItem.isEnabled = false
        }
        updateMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windPopover?.performClose(nil)
        coordinator?.stop()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowy")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Snowy — desktop snowfall"
        statusItem = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Snowy", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        let clear = NSMenuItem(title: "Clear Settled Snow", action: #selector(clearSnow), keyEquivalent: "k")
        clear.target = self
        menu.addItem(clear)
        let tool = NSMenuItem(title: "Cursor Tool", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "Cursor Tool")
        tools.autoenablesItems = false
        for (index, name) in ["Glove", "Shovel"].enumerated() {
            let option = NSMenuItem(title: name, action: #selector(selectTool(_:)), keyEquivalent: "")
            option.tag = index
            option.target = self
            tools.addItem(option)
            toolItems.append(option)
        }
        tool.submenu = tools
        menu.addItem(tool)
        menu.addItem(.separator())
        for (index, snowfall) in Snowfall.allCases.enumerated() {
            let option = NSMenuItem(title: snowfall.rawValue, action: #selector(setSnowfall(_:)), keyEquivalent: "")
            option.target = self
            option.tag = index
            weatherItems.append(option)
            menu.addItem(option)
        }
        let wind = NSMenuItem(title: "Wind…", action: #selector(showWind), keyEquivalent: "w")
        wind.target = self
        menu.addItem(wind)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Snowy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    private func updateMenu() {
        guard let coordinator else { return }
        pauseItem.title = coordinator.paused ? "Resume Snow" : "Pause Snow"
        if coordinator.failed { stateItem.title = "Rendering stopped — relaunch to retry" }
        else if coordinator.policy.suspended { stateItem.title = "Resting while your Mac cools down" }
        else if coordinator.paused { stateItem.title = "Snow is paused" }
        else if coordinator.policy.reducedMotion { stateItem.title = "Quiet drifts · Reduce Motion" }
        else if coordinator.policy.particleScale < 1 { stateItem.title = "Gentle snowfall · saving energy" }
        else { stateItem.title = "Brush a snowy edge to sweep it away" }
        for (index, item) in weatherItems.enumerated() {
            item.state = Snowfall.allCases[index] == coordinator.snowfall ? .on : .off
        }
        for (index, item) in toolItems.enumerated() {
            item.state = (index == 1 ? coordinator.tool == .shovel : coordinator.tool == .glove) ? .on : .off
        }
    }

    @objc private func togglePause() { coordinator?.paused.toggle() }
    @objc private func clearSnow() { coordinator?.clear() }
    @objc private func showWind() {
        // A menu action runs during tracking; show after it closes so the popover receives focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem?.button, let coordinator = self.coordinator else { return }
            if let popover = self.windPopover, popover.isShown { popover.performClose(nil); return }
            let content = WindViewController()
            content.settings = coordinator.wind
            content.onChange = { [weak coordinator] value in coordinator?.wind = value }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentViewController = content
            popover.delegate = self
            content.onClose = { [weak popover] in popover?.performClose(nil) }
            self.windPopover = popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === windPopover else { return }
        windPopover = nil
    }

    @objc private func selectTool(_ sender: NSMenuItem) {
        coordinator?.tool = sender.tag == 1 ? .shovel : .glove
    }
    @objc private func setSnowfall(_ sender: NSMenuItem) {
        guard Snowfall.allCases.indices.contains(sender.tag) else { return }
        coordinator?.snowfall = Snowfall.allCases[sender.tag]
    }
}
