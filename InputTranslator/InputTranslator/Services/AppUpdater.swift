import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, NSMenuItemValidation {
    private let userDriver: UpdateUserDriver
    private let updater: SPUUpdater

    override init() {
        let bundle = Bundle.main
        userDriver = UpdateUserDriver(hostBundle: bundle, delegate: nil)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: nil)
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
