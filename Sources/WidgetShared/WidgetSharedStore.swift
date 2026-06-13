import Foundation

/// Shared contract for how the app exposes usage to the widget. To avoid App
/// Groups (which need a provisioning profile / paid Developer account), the app
/// serves the payload over loopback HTTP on a fixed port and the sandboxed
/// widget fetches it with a plain `network.client` connection.
public enum WidgetUsageEndpoint {
    /// WidgetKit kind identifier for the all-accounts usage widget.
    public static let widgetKind = "ClaudeBarUsageWidget"

    /// Fixed loopback port the app serves usage on (high, uncommon — personal use).
    public static let port: UInt16 = 51763

    public static let path = "/usage"

    /// The URL the widget fetches usage from.
    public static var url: URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}
