import WidgetKit
import SwiftUI
// WidgetShared model sources are compiled into this target directly (see Project.swift).

// MARK: - Timeline

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let payload: WidgetUsagePayload?
}

struct ClaudeUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(), payload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        Task {
            completion(ClaudeUsageEntry(date: Date(), payload: await fetch()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        Task {
            let entry = ClaudeUsageEntry(date: Date(), payload: await fetch())
            // Refresh roughly every 15 minutes (WidgetKit budgets refreshes).
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// Fetches usage from the running app over loopback. Returns nil if the app
    /// isn't running (server unavailable) — the view shows a hint in that case.
    private func fetch() async -> WidgetUsagePayload? {
        var request = URLRequest(url: WidgetUsageEndpoint.url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return WidgetUsagePayload.decode(data)
    }
}

// MARK: - Views

struct ClaudeUsageWidgetView: View {
    let entry: ClaudeUsageEntry
    @Environment(\.widgetFamily) private var family

    private var maxAccounts: Int { family == .systemLarge ? 6 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Claude usage")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let payload = entry.payload {
                    Text(payload.displayModeLabel.lowercased())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("open ClaudeBar")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let accounts = entry.payload?.accounts, !accounts.isEmpty {
                ForEach(accounts.prefix(maxAccounts)) { account in
                    if family == .systemLarge {
                        accountDetail(account)
                    } else {
                        accountRow(account)
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                Text(entry.payload == nil ? "ClaudeBar isn't running" : "No usage yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func accountRow(_ account: WidgetAccountUsage) -> some View {
        HStack(spacing: 8) {
            Text(account.label)
                .font(.system(size: 13, weight: account.isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)

            if let quota = account.lowestQuota {
                bar(percent: quota.displayPercent, status: quota.status)
                Text("\(Int(quota.displayPercent.rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Spacer()
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Large family: account name + one labeled bar per quota (Session, Weekly, …).
    @ViewBuilder
    private func accountDetail(_ account: WidgetAccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(account.label)
                    .font(.system(size: 14, weight: account.isActive ? .semibold : .medium))
                    .lineLimit(1)
                if account.isActive {
                    Text("default")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if account.quotas.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(account.quotas.prefix(2), id: \.label) { quota in
                    HStack(spacing: 8) {
                        Text(quota.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 54, alignment: .leading)
                        bar(percent: quota.displayPercent, status: quota.status)
                        Text("\(Int(quota.displayPercent.rounded()))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func bar(percent: Double, status: WidgetQuotaStatus) -> some View {
        let fraction = max(0, min(1, percent / 100))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color(for: status))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 9)
        .frame(maxWidth: .infinity)
    }

    private func color(for status: WidgetQuotaStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .critical, .depleted: return .red
        }
    }
}

// MARK: - Widget

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetUsageEndpoint.widgetKind, provider: ClaudeUsageProvider()) { entry in
            ClaudeUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude accounts' usage at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ClaudeBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
    }
}
