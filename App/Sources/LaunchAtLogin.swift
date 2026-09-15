import Foundation
import ServiceManagement

@MainActor enum BackgroundServices {
    // Bump this when an embedded launch-agent plist changes in a way that an
    // existing SMAppService registration must reload. Revision 1 migrated the
    // renamed executable; revisions 2 and 3 briefly moved the indexer into an
    // app-like wrapper. Revision 4 restores the shared signing identity used by
    // the single EverythingMac Full Disk Access grant.
    private static let registrationRevision = 4
    private static let registrationRevisionKey = "services.registrationRevision"
    private static let services = [
        SMAppService.agent(plistName: "com.everythingmac.indexing-agent.plist"),
        SMAppService.agent(plistName: "com.everythingmac.search.plist"),
    ]

    static var areEnabled: Bool { services.allSatisfy { $0.status == .enabled } }
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
        for obsoleteIndexer in obsoleteIndexers where obsoleteIndexer.status == .enabled {
            do {
                try obsoleteIndexer.unregister()
            } catch {
                NSLog("EverythingMac could not remove an obsolete indexing service: %@",
                      error.localizedDescription)
                return
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

    static func restartAfterFullDiskAccessChange() -> Bool {
        guard areEnabled else { return false }

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
