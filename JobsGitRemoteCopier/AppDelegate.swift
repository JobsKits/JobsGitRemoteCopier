//
//  AppDelegate.swift
//  JobsGitRemoteCopier
//
//  Created by Jobs on 2026年6月27日，星期六.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let extensionIdentifier = "com.jobs.JobsGitRemoteCopier.FinderSyncExtension"
    private let logURL = URL(fileURLWithPath: "/tmp/JobsGitRemoteCopier.log")
    private let finderRefreshMarkerURL = URL(fileURLWithPath: "/tmp/JobsGitRemoteCopierNeedsFinderRestart")
    private let finderRefreshDelay: TimeInterval = 2.5
    private let finderRefreshRetryDelay: TimeInterval = 1.0
    private let finderRefreshRetryLimit = 12
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeLog("applicationDidFinishLaunching begin")
        let viewController = MainViewController()
        _ = viewController.view
        writeLog("main view loaded")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jobs Git Remote Copier"
        window.center()
        window.contentViewController = viewController
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        scheduleFinderRefreshIfNeeded()
        writeLog("applicationDidFinishLaunching end")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

private extension AppDelegate {
    func scheduleFinderRefreshIfNeeded() {
        guard FileManager.default.fileExists(atPath: finderRefreshMarkerURL.path) else {
            writeLog("finder refresh marker missing")
            return
        }

        writeLog("schedule Finder refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + finderRefreshDelay) { [weak self] in
            self?.refreshFinderAfterExtensionActivation(remainingAttempts: self?.finderRefreshRetryLimit ?? 0)
        }
    }

    func refreshFinderAfterExtensionActivation(remainingAttempts: Int) {
        guard FileManager.default.fileExists(atPath: finderRefreshMarkerURL.path) else {
            writeLog("finder refresh marker already consumed")
            return
        }

        _ = runPluginKit(arguments: ["-e", "use", "-i", extensionIdentifier])
        if isFinderExtensionEnabledByPluginKit() {
            writeLog("Finder extension enabled, restart Finder")
            restartFinder()
            try? FileManager.default.removeItem(at: finderRefreshMarkerURL)
            return
        }

        guard remainingAttempts > 0 else {
            writeLog("Finder extension still not enabled, keep marker")
            return
        }

        writeLog("Finder extension not enabled yet, retry remaining=\(remainingAttempts)")
        DispatchQueue.main.asyncAfter(deadline: .now() + finderRefreshRetryDelay) { [weak self] in
            self?.refreshFinderAfterExtensionActivation(remainingAttempts: remainingAttempts - 1)
        }
    }

    func isFinderExtensionEnabledByPluginKit() -> Bool {
        let result = runPluginKit(arguments: ["-m", "-p", "com.apple.FinderSync", "-A", "-v"])
        let matchedLine = result.output.components(separatedBy: .newlines).first { $0.contains(extensionIdentifier) } ?? ""
        let isEnabled = matchedLine.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        writeLog("Finder extension status line=\(matchedLine), isEnabled=\(isEnabled)")
        return isEnabled
    }

    func restartFinder() {
        let result = runCommand(executablePath: "/usr/bin/killall", arguments: ["Finder"])
        writeLog("killall Finder success=\(result.didSucceed), output=\(result.output)")
    }

    func runPluginKit(arguments: [String]) -> AppCommandResult {
        runCommand(executablePath: "/usr/bin/pluginkit", arguments: arguments)
    }

    func runCommand(executablePath: String, arguments: [String]) -> AppCommandResult {
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
            return AppCommandResult(didSucceed: false, output: error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        writeLog("\(executablePath) \(arguments.joined(separator: " ")) status=\(process.terminationStatus) output=\(output)")
        return AppCommandResult(didSucceed: process.terminationStatus == 0, output: output)
    }

    func writeLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        NSLog("JobsGitRemoteCopier %@", message)

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

private struct AppCommandResult {
    let didSucceed: Bool
    let output: String
}
