import Foundation

/// Reads and writes the widget usage payload to the shared App Group container,
/// the only location both the (non-sandboxed) app and the (sandboxed) widget
/// extension can access.
public enum WidgetSharedStore {
    /// App Group identifier shared by the app and the widget extension. Must
    /// match the `com.apple.security.application-groups` entitlement in both.
    public static let appGroupIdentifier = "group.com.tddworks.claudebar"

    /// WidgetKit kind identifier for the all-accounts usage widget.
    public static let widgetKind = "ClaudeBarUsageWidget"

    private static let fileName = "widget-usage.json"

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    /// Writes the payload to the shared container. Returns false if the App
    /// Group container is unavailable (e.g. entitlement missing) or the write
    /// fails — callers can log/ignore.
    @discardableResult
    public static func write(_ payload: WidgetUsagePayload) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Reads the latest payload from the shared container, or nil if absent.
    public static func read() -> WidgetUsagePayload? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetUsagePayload.self, from: data)
    }
}
