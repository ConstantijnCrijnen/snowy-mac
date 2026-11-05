import AppKit
import Sparkle

/// Sparkle owns discovery, verification, installation, and relaunch. Snowy
/// adds a menu affordance and uses that click as consent for an eligible update.
@MainActor
final class SnowyUpdater: NSObject, SPUUpdaterDelegate {
    private let driver = SnowyUpdateDriver(hostBundle: .main, delegate: nil)
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                         userDriver: driver, delegate: self)
    private(set) var availableVersion: String?
    var onChange: (() -> Void)?

    var canInstall: Bool {
        availableVersion != nil && !driver.installRequested && !updater.sessionInProgress
    }

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdateInformation()
            }
        } catch {
            NSLog("Snowy updater could not start: %@", error.localizedDescription)
        }
    }

    func install() {
        guard canInstall, updater.canCheckForUpdates else { return }
        driver.installRequested = true
        onChange?()
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = SnowyUpdateDriver.isEligible(item) ? item.displayVersionString : nil
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didNotFindUpdateWithError error: any Error) {
        availableVersion = nil
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        driver.installRequested = false
        driver.approvedInstall = false
        // Refresh after Sparkle has finished changing its session state.
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

@MainActor
private final class SnowyUpdateDriver: SPUStandardUserDriver {
    var installRequested = false
    var approvedInstall = false

    static func isEligible(_ item: SUAppcastItem) -> Bool {
        // A later paid upgrade must use a separate purchase/entitlement flow.
        item.signingValidationStatus == .succeeded && !item.isInformationOnlyUpdate && !item.isMajorUpgrade
    }

    override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installRequested, state.userInitiated, Self.isEligible(item) else {
            reply(.dismiss)
            return
        }
        approvedInstall = true
        // Clear the checking panel. Sparkle presents native download progress
        // and any system authorization or error from here onward.
        dismissUpdateInstallation()
        reply(.install)
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(approvedInstall ? .install : .dismiss)
    }
}
