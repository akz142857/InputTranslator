import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, SPUUpdaterDelegate {
    @Published private(set) var availableVersion: String?
    private let windowPresentation = UpdateWindowPresentation()
    private let userDriver: UpdateUserDriver
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                         userDriver: userDriver, delegate: self)

    override init() {
        userDriver = UpdateUserDriver(hostBundle: .main, presentation: windowPresentation)
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
final class UpdateUserDriver: SPUStandardUserDriver {
    private let presentation: UpdateWindowPresentation
    private var installConfirmed = false

    init(hostBundle: Bundle, presentation: UpdateWindowPresentation) {
        self.presentation = presentation
        super.init(hostBundle: hostBundle, delegate: presentation)
    }

    override func show(_ request: SPUUpdatePermissionRequest,
                       reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        presentation.beginSession()
        super.show(request, reply: reply)
        presentation.refresh()
    }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        presentation.beginSession()
        super.showUserInitiatedUpdateCheck(cancellation: cancellation)
        presentation.refresh()
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installConfirmed = false
        presentation.beginSession()
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.installConfirmed = choice == .install && !appcastItem.isInformationOnlyUpdate
            reply(choice)
        }
        presentation.refresh()
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        presentation.beginSession()
        super.showDownloadInitiated(cancellation: cancellation)
        presentation.refresh()
    }

    override func showUpdateInFocus() {
        presentation.beginSession()
        super.showUpdateInFocus()
        presentation.refresh()
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
        presentation.finishSession()
    }
}
