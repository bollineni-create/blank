import Foundation
import CoreData
import CloudKit
import Observation

/// Watches iCloud sync so Settings can say whether the library is syncing, and if not, why.
/// SwiftData quietly keeps a device-only library when iCloud isn't set up, so without this
/// the Mac and iPhone just drift apart with no hint of the cause.
@MainActor
@Observable
final class SyncMonitor {
    static let containerID = "iCloud.com.bollineni.loom"

    enum Tone { case ok, busy, problem }

    /// True once iCloud has reported anything; false if it stayed silent after launch.
    private(set) var hasCloudKit: Bool?
    private(set) var accountStatus: CKAccountStatus?
    private(set) var lastError: String?
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    private var running: Set<UUID> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        })
        // iCloud says something within a few seconds of opening the library when sync is on.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if self?.hasCloudKit == nil { self?.hasCloudKit = false }
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        let firstEvent = hasCloudKit != true
        hasCloudKit = true
        if firstEvent { refreshAccount() }
        guard let end = event.endDate else {
            running.insert(event.identifier)
            return
        }
        running.remove(event.identifier)
        if let error = event.error {
            lastError = Self.describe(error)
            refreshAccount()
            return
        }
        lastError = nil
        switch event.type {
        case .import: lastImport = end
        case .export: lastExport = end
        default: break
        }
    }

    func refreshAccount() {
        // Asking CloudKit anything without the iCloud entitlement crashes the app, so only once it has spoken.
        guard hasCloudKit == true else { return }
        Task { accountStatus = try? await CKContainer(identifier: Self.containerID).accountStatus() }
    }

    var headline: String {
        switch (hasCloudKit, accountStatus) {
        case (nil, _): "Checking…"
        case (false?, _): "Not syncing"
        case (_, .noAccount?): "Signed out of iCloud"
        case (_, .restricted?): "iCloud is restricted"
        case (_, .temporarilyUnavailable?): "iCloud is temporarily unavailable"
        default: !running.isEmpty ? "Syncing…" : (lastError != nil ? "Sync problem" : "On")
        }
    }

    var detail: String? {
        switch (hasCloudKit, accountStatus) {
        case (false?, _):
            "Loom hasn't heard from iCloud on this device, so this library stays here. Either this copy of Loom was built without the iCloud capability (it needs the paid Apple Developer Program; a free team can't add it), or this device isn't signed in to iCloud."
        case (_, .noAccount?):
            "Sign in to iCloud with the same Apple Account on your Mac and iPhone."
        case (_, .restricted?):
            "Screen Time or a device profile is blocking iCloud for this app."
        case (_, .temporarilyUnavailable?):
            "Open the iCloud settings on this device. You may need to re-enter your password."
        default:
            running.isEmpty ? lastError : nil
        }
    }

    var tone: Tone {
        if hasCloudKit == nil || !running.isEmpty { return .busy }
        return detail == nil ? .ok : .problem
    }

    private static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated:
            return "This device isn't signed in to iCloud."
        case .quotaExceeded:
            return "Your iCloud storage is full, so new items can't upload."
        case .networkUnavailable, .networkFailure:
            return "No internet connection. Loom will sync when it's back."
        case .badContainer, .missingEntitlement, .permissionFailure:
            return "iCloud refused Loom's container (\(containerID)). In the Apple Developer portal, make sure both the iPhone and Mac app IDs have iCloud turned on with this container."
        case .partialFailure:
            if let first = ck.partialErrorsByItemID?.values.first { return describe(first) }
            return ck.localizedDescription
        default:
            return ck.localizedDescription
        }
    }
}
