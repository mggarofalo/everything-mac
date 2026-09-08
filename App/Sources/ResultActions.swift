import AppKit
import IndexCore
import UniformTypeIdentifiers

@MainActor enum ResultActions {
    struct ItemIdentity {
        let path: String
        let device: dev_t
        let inode: ino_t
    }

    static func identity(for rec: FileRecord) -> ItemIdentity? {
        var value = stat()
        guard lstat(rec.path, &value) == 0 else { return nil }
        return ItemIdentity(path: rec.path, device: value.st_dev, inode: value.st_ino)
    }
    static func open(_ rec: FileRecord) { NSWorkspace.shared.open(URL(fileURLWithPath: rec.path)) }
    static func open(_ rec: FileRecord, with appURL: URL) {
        NSWorkspace.shared.open([URL(fileURLWithPath: rec.path)],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }
    static func reveal(_ rec: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.path)])
    }
    static func copyPath(_ rec: FileRecord) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rec.path, forType: .string)
    }
    static func copyName(_ rec: FileRecord) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rec.name, forType: .string)
    }
    static func trash(_ rec: FileRecord, expected: ItemIdentity?) {
        guard let original = expected, original.path == rec.path else {
            NSAlert(error: CocoaError(.fileNoSuchFile)).runModal()
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Move “\(rec.name)” to the Trash?"
        confirmation.informativeText = rec.path
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Move to Trash")
        confirmation.buttons.first?.hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        var current = stat()
        guard lstat(rec.path, &current) == 0,
              current.st_dev == original.device, current.st_ino == original.inode else {
            let changed = NSAlert()
            changed.messageText = "The item changed before it could be moved"
            changed.informativeText = "Nothing was moved. Select the item again and retry."
            changed.alertStyle = .warning
            changed.runModal()
            return
        }

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: rec.path), resultingItemURL: nil)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Couldn’t move “\(rec.name)” to the Trash"
            failure.runModal()
        }
    }

    // Write the current result list to a tab-separated file the user picks. TSV (not
    // CSV) because paths rarely contain tabs but routinely contain commas/quotes that
    // would need escaping; sizes are raw bytes so the file stays script-friendly.
    static func exportResults(_ rows: [FileRecord]) {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "EverythingMac-results.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "Name\tPath\tSize\tKind\tDate Modified\n"
        for r in rows {
            let ext = (r.name as NSString).pathExtension.lowercased()
            let size = r.isDir ? "" : String(r.size)
            let kind = FileIcons.kind(ext: ext, isDir: r.isDir)
            let date = df.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime)))
            out += "\(r.name)\t\(r.path)\t\(size)\t\(kind)\t\(date)\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}
