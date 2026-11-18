import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, SPUUpdaterDelegate {
    @Published private(set) var availableVersion: String?
    private let userDriver: UpdateUserDriver
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                         userDriver: userDriver, delegate: self)

    override init() {
        userDriver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        super.init()
    }

    func start() {
        do {
            try updater.start()
        } catch {
            userDriver.showUpdaterError(error, acknowledgement: {})
            return
        }
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        updater.canCheckForUpdates
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice != .dismiss { availableVersion = nil }
    }
}

@MainActor
private final class UpdateUserDriver: SPUStandardUserDriver {
    private var installConfirmed = false

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installConfirmed = false
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.installConfirmed = choice == .install && !appcastItem.isInformationOnlyUpdate
            reply(choice)
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installConfirmed else {
            super.showReady(toInstallAndRelaunch: reply)
            return
        }
        installConfirmed = false
        reply(.install)
    }

    override func dismissUpdateInstallation() {
        installConfirmed = false
        super.dismissUpdateInstallation()
    }
}
