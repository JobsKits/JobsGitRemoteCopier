//
//  FinderSync.swift
//  JobsGitRemoteCopyFinderSync
//
//  Created by Jobs on 2026年6月27日，星期六.
//

import AppKit
import FinderSync

final class FinderSync: FIFinderSync {
    private let resolver = GitRemoteResolver()
    private let logURL: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("JobsGitRemoteCopyFinderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("FinderSync.log")
    }()

    override init() {
        super.init()
        configureObservedDirectories()
        writeLog("FinderSync init")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let urls = candidateURLs()
        writeLog("menu kind=\(menuKind.rawValue), candidates=\(urls.map(\.path).joined(separator: " | "))")
        guard menuKind == .contextualMenuForItems, urls.count == 1 else { return nil }

        let menu = NSMenu(title: "")
        let copyItem = NSMenuItem(title: "复制 Git 远程地址", action: #selector(copyGitRemoteURL(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = true
        menu.addItem(copyItem)
        return menu
    }
}

private extension FinderSync {
    func configureObservedDirectories() {
        let directoryURLs: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        FIFinderSyncController.default().directoryURLs = directoryURLs
        writeLog("observed=\(directoryURLs.map(\.path).sorted().joined(separator: " | "))")
    }

    @objc func copyGitRemoteURL(_ sender: Any?) {
        let urls = candidateURLs()
        var messages: [String] = []
        writeLog("action candidates=\(urls.map(\.path).joined(separator: " | "))")

        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let remoteURLString = try resolver.remoteURLString(from: url)
                try copyToPasteboard(remoteURLString)
                writeLog("copied \(remoteURLString)")
                showSuccessPrompt(remoteURLString: remoteURLString)
                return
            } catch {
                writeLog("failed \(url.path): \(error.localizedDescription)")
                messages.append(error.localizedDescription)
            }
        }

        showFailureAlert(messages: messages)
    }

    func candidateURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        guard let selectedURLs = controller.selectedItemURLs(),
              selectedURLs.count == 1,
              let selectedURL = selectedURLs.first,
              selectedURL.isFileURL else { return [] };return [selectedURL.standardizedFileURL]
    }

    func showFailureAlert(messages: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "复制 Git 远程地址失败"
        alert.informativeText = messages.isEmpty ? "请选择一个 Git 仓库文件或文件夹后再试。" : messages.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func copyToPasteboard(_ value: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            throw ClipboardError.copyFailed(value)
        }
    }

    func showSuccessPrompt(remoteURLString: String) {
        let escapedRemoteURLString = remoteURLString.replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runCommand(
                executablePath: "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "display notification \"\(escapedRemoteURLString)\" with title \"复制 Git 远程地址成功\" subtitle \"已写入剪贴板\""
                ]
            )
            self?.writeLog("success notification didSucceed=\(result?.didSucceed == true), status=\(result?.terminationStatus ?? -1), output=\(result?.output ?? "")")
        }
    }

    func runCommand(executablePath: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            writeLog("\(executablePath) \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)")
            return CommandResult(didSucceed: false, terminationStatus: -1, output: error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return CommandResult(didSucceed: process.terminationStatus == 0, terminationStatus: process.terminationStatus, output: output)
    }

    func writeLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        NSLog("JobsGitRemoteCopyFinderSync %@", message)

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            return
        }

        try? Data(line.utf8).write(to: logURL)
    }
}

private enum ClipboardError: LocalizedError {
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let value):
            return "写入剪贴板失败：\(value)"
        }
    }
}

private struct CommandResult {
    let didSucceed: Bool
    let terminationStatus: Int32
    let output: String
}
