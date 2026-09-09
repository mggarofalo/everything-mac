import ServiceManagement

@MainActor enum BackgroundServices {
    private static let services = [
        SMAppService.agent(plistName: "com.everythingmac.indexer.plist"),
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
        try? legacyMain.unregister()
        try? legacyHelper.unregister()
        for service in services where service.status != .enabled {
            do {
                try service.register()
            } catch {
                NSLog("EverythingMac could not register background service: %@", error.localizedDescription)
            }
        }
    }
}
