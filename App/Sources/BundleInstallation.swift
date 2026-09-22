import Foundation

enum BundleInstallation {
    static func identity(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(url.standardizedFileURL.path):\(device):\(inode)"
    }
}
