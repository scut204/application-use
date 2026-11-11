import AppKit
import Foundation

extension ComputerUseService {
    /// Binds an already running app. Launch callbacks can activate an app even
    /// when NSWorkspace is asked not to, so launch is intentionally unsupported.
    public func applicationUseOpen(app query: String) throws -> [String: Any] {
        let app: RunningAppDescriptor
        do {
            app = try AppDiscovery.resolveRunning(query)
        } catch ComputerUseError.appNotFound {
            throw ComputerUseError.message("application-use only binds already running applications. Open '\(query)' yourself first; background-safe launch cannot be guaranteed")
        }
        guard !app.runningApplication.isHidden else {
            throw ComputerUseError.stateUnavailable("The target application is hidden; application-use will not activate or unhide it")
        }
        return [
            "app": app.name,
            "bundleIdentifier": app.bundleIdentifier as Any? ?? NSNull(),
            "pid": Int(app.pid),
            "bound": true,
            "launched": false,
        ]
    }

    /// Normal termination may display a save dialog and steal focus; force
    /// termination would risk data loss. Neither is a background-only action.
    public func applicationUseClose(app query: String) throws -> [String: Any] {
        throw ComputerUseError.message("Closing applications is unavailable in application-use because save dialogs can take focus; close the application yourself")
    }

    public func applicationUseSearch(query: String) throws -> [String: Any] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ComputerUseError.invalidArguments("search query must not be empty")
        }
        let running = AppDiscovery.runningApps()
        let applications = AppDiscovery.searchApplicationURLs(matching: trimmedQuery).map { url -> [String: Any] in
            let bundle = Bundle(url: url)
            let bundleIdentifier = bundle?.bundleIdentifier
            let runningApp = running.first { app in
                app.runningApplication.bundleURL?.standardizedFileURL == url.standardizedFileURL
                    || (bundleIdentifier != nil && app.bundleIdentifier == bundleIdentifier)
            }
            return [
                "app": (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent,
                "bundleIdentifier": bundleIdentifier as Any? ?? NSNull(),
                "path": url.path,
                "running": runningApp != nil,
                "pid": runningApp.map { Int($0.pid) } as Any? ?? NSNull(),
            ]
        }
        return ["applications": applications]
    }
}
