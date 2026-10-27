import Foundation

public enum BrowserURLScripts {
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "company.thebrowser.Browser", "company.thebrowser.dia", "ai.perplexity.comet", "org.chromium.Chromium",
    ]

    public static var supportedBundleIDs: [String] { Array(safari) + Array(chromium) }

    public static func isSupported(_ bundleID: String) -> Bool {
        safari.contains(bundleID) || chromium.contains(bundleID)
    }

    static let privateMarker = "__weft_private__"

    static func script(for bundleID: String) -> String? {
        if safari.contains(bundleID) {
            return """
            tell application id "\(bundleID)"
                if (count of windows) = 0 then return ""
                return URL of current tab of front window
            end tell
            """
        }
        if chromium.contains(bundleID) {
            // Not every Chromium fork exposes `mode`, hence the try.
            return """
            tell application id "\(bundleID)"
                if (count of windows) = 0 then return ""
                set w to front window
                try
                    if mode of w is "incognito" then return "\(privateMarker)"
                end try
                return URL of active tab of w
            end tell
            """
        }
        return nil
    }
}

public enum BrowserURLResult: Equatable, Sendable {
    case url(String)
    case privateWindow
    case unavailable
}

/// Reads the active tab URL through AppleScript. Runs `osascript` in a child process so a
/// hung browser can never block the main thread, and kills it after a short timeout.
public struct BrowserURLProvider: Sendable {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    public func currentURL(bundleID: String) async -> BrowserURLResult {
        guard let source = BrowserURLScripts.script(for: bundleID) else { return .unavailable }
        guard let output = await run(source) else { return .unavailable }
        if output == BrowserURLScripts.privateMarker { return .privateWindow }
        return output.isEmpty ? .unavailable : .url(output)
    }

    private func run(_ source: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            let timeout = self.timeout
            Task.detached {
                try? await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
            }
        }
    }
}
