import Foundation
import ServiceManagement

@MainActor enum BackgroundServices {
    enum Availability: Equatable {
        case enabled
        case requiresApproval
        case unavailable
    }

    // Bump this when an embedded launch-agent plist changes in a way that an
    // existing SMAppService registration must reload. Revision 1 migrated the
    // renamed executable; revisions 2 and 3 briefly moved the indexer into an
    // app-like wrapper. Revision 4 restores the shared signing identity used by
    // the single EverythingMac Full Disk Access grant. Revision 5 proactively
    // refreshes registrations that a 0.9.4 upgrade may have left unresponsive.
    // Revision 6 removes disabled Background Task Management records for both
    // retired indexer labels, which used the current indexer's Mach service.
    private static let registrationRevision = 6
    private static let registrationRevisionKey = "services.registrationRevision"
    private static let services = [
        SMAppService.agent(plistName: "com.everythingmac.indexing-agent.plist"),
        SMAppService.agent(plistName: "com.everythingmac.search.plist"),
    ]

    static var areEnabled: Bool { services.allSatisfy { $0.status == .enabled } }
    static var availability: Availability {
        if areEnabled { return .enabled }
        if services.contains(where: { $0.status == .requiresApproval }) {
            return .requiresApproval
        }
        return .unavailable
    }
    static var statusText: String {
        services.map { service in
            switch service.status {
            case .enabled: return "Running"
            case .requiresApproval: return "Needs approval"
            case .notFound: return "Not installed"
            case .notRegistered: return "Not registered"
            @unknown default: return "Unavailable"
            }
        }.joined(separator: " / ")
    }

    static func install() {
        let legacyMain = SMAppService.mainApp
        let legacyHelper = SMAppService.loginItem(identifier: "com.everythingmac.loginhelper")
        let obsoleteIndexers = [
            SMAppService.agent(plistName: "com.everythingmac.indexer.plist"),
            SMAppService.agent(plistName: "com.everythingmac.indexing-service.plist"),
        ]
        try? legacyMain.unregister()
        try? legacyHelper.unregister()
        for obsoleteIndexer in obsoleteIndexers {
            do {
                try obsoleteIndexer.unregister()
            } catch {
                NSLog("EverythingMac could not remove an obsolete indexing service: %@",
                      error.localizedDescription)
            }
        }

        let defaults = UserDefaults.standard
        let needsRefresh = defaults.integer(forKey: registrationRevisionKey)
            < registrationRevision
        var registrationSucceeded = true

        // Service Management retains the BundleProgram from the registered plist.
        // Reload both services together so the forwarding service cannot retain a
        // dead connection when an upgrade changes either embedded executable.
        if needsRefresh {
            for service in services where service.status == .enabled {
                do {
                    try service.unregister()
                } catch {
                    registrationSucceeded = false
                    NSLog("EverythingMac could not refresh background service: %@",
                          error.localizedDescription)
                }
            }
        }

        for service in services where service.status != .enabled {
            do {
                try service.register()
            } catch {
                registrationSucceeded = false
                NSLog("EverythingMac could not register background service: %@", error.localizedDescription)
            }
        }

        if needsRefresh, registrationSucceeded {
            defaults.set(registrationRevision, forKey: registrationRevisionKey)
        }
    }

    /// Reconcile registration and restart enabled agents after an XPC lookup
    /// fails. Retrying the same connection cannot repair a missing or stale
    /// launchd job, which is common after an in-place application upgrade.
    static func recoverAfterConnectionFailure() -> Availability {
        install()
        guard availability == .enabled else { return availability }
        _ = restartEnabledServices()
        return availability
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func restartAfterFullDiskAccessChange() -> Bool {
        guard areEnabled else { return false }

        return restartEnabledServices()
    }

    private static func restartEnabledServices() -> Bool {
        for service in services.reversed() {
            do {
                try service.unregister()
            } catch {
                NSLog("EverythingMac could not stop background service: %@",
                      error.localizedDescription)
                install()
                return false
            }
        }

        var registrationSucceeded = true
        for service in services {
            do {
                try service.register()
            } catch {
                registrationSucceeded = false
                NSLog("EverythingMac could not restart background service: %@",
                      error.localizedDescription)
            }
        }
        return registrationSucceeded
    }
}
