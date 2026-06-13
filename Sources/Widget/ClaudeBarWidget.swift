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
        Task { completion(ClaudeUsageEntry(date: Date(), payload: await fetch())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        Task {
            let entry = ClaudeUsageEntry(date: Date(), payload: await fetch())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func fetch() async -> WidgetUsagePayload? {
        var request = URLRequest(url: WidgetUsageEndpoint.url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return WidgetUsagePayload.decode(data)
    }
}

// MARK: - Bar

private func statusColor(_ status: WidgetQuotaStatus) -> Color {
    switch status {
    case .healthy: return .green
    case .warning: return .orange
    case .critical, .depleted: return .red
    }
}

private func clampPct(_ v: Double) -> Double { max(0, min(100, v)) }

/// One quota bar: fill = current usage; line mark = recent-pace projection,
/// caret = sustained-pace projection. Numbers sit inside the bar (current white
/// in the fill, projections in their severity color), collapsing when too close.
private struct QuotaBar: View {
    let quota: WidgetQuota
    var height: CGFloat = 14

    private var current: Double { clampPct(quota.displayPercent) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Collapse a projection if within 7 points of the current value.
            let recent = quota.recent.flatMap { abs(clampPct($0.value) - current) >= 7 ? $0 : nil }
            let sustained = quota.sustained.flatMap { p in
                let c = clampPct(p.value)
                let nearCurrent = abs(c - current) < 7
                let nearRecent = recent.map { abs(c - clampPct($0.value)) < 7 } ?? false
                return (nearCurrent || nearRecent) ? nil : p
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(statusColor(quota.status))
                    .frame(width: max(height, w * current / 100))

                if let r = recent { lineMark(at: clampPct(r.value), w: w) }
                if let s = sustained { caretMark(at: clampPct(s.value), w: w, color: statusColor(s.status)) }

                numberInFill(Int(quota.displayPercent.rounded()), at: current, w: w)
                if let r = recent { numberOnTrack(Int(r.value.rounded()), at: clampPct(r.value), color: statusColor(r.status), w: w) }
                if let s = sustained { numberOnTrack(Int(s.value.rounded()), at: clampPct(s.value), color: statusColor(s.status), w: w) }
            }
        }
        .frame(height: height)
    }

    private func lineMark(at pct: Double, w: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5, height: height)
            .position(x: w * pct / 100, y: height / 2)
    }

    private func caretMark(at pct: Double, w: CGFloat, color: Color) -> some View {
        Triangle().fill(color).frame(width: 6, height: 5)
            .position(x: w * pct / 100, y: 2.5)
    }

    private func numberInFill(_ value: Int, at pct: Double, w: CGFloat) -> some View {
        Text("\(value)")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .position(x: min(w - 10, max(10, w * pct / 100) - 9), y: height / 2)
    }

    private func numberOnTrack(_ value: Int, at pct: Double, color: Color, w: CGFloat) -> some View {
        Text("\(value)")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .position(x: min(w - 8, w * pct / 100 + 9), y: height / 2)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Rows

private struct QuotaRow: View {
    let label: String
    let quota: WidgetQuota?
    var height: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            if let quota { QuotaBar(quota: quota, height: height) } else { Spacer() }
        }
    }
}

private struct CompactAccountRow: View {
    let account: WidgetAccountUsage

    var body: some View {
        HStack(spacing: 8) {
            Text(account.label).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(width: 74, alignment: .leading)
            HStack(spacing: 6) {
                miniBar("S", account.session)
                miniBar("W", account.weekly)
            }
        }
    }

    private func miniBar(_ tag: String, _ quota: WidgetQuota?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.18))
                if let quota {
                    RoundedRectangle(cornerRadius: 5).fill(statusColor(quota.status))
                        .frame(width: max(10, geo.size.width * clampPct(quota.displayPercent) / 100))
                    Text("\(tag) \(Int(quota.displayPercent.rounded()))")
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
                }
            }
        }
        .frame(height: 11)
    }
}

// MARK: - Widget view

struct ClaudeUsageWidgetView: View {
    let entry: ClaudeUsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if let payload = entry.payload {
                content(payload)
            } else {
                Spacer()
                Text("ClaudeBar isn't running").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint)
            Text("Claude usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Rectangle().fill(Color.secondary).frame(width: 1.5, height: 8)
                    Text("recent").font(.system(size: 8))
                }
                HStack(spacing: 3) {
                    Triangle().fill(Color.secondary).frame(width: 5, height: 4)
                    Text("sustained").font(.system(size: 8))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ payload: WidgetUsagePayload) -> some View {
        if payload.combinedSession != nil || payload.combinedWeekly != nil {
            sectionTitle("Combined", subtitle: "weighted")
            QuotaRow(label: "Session", quota: payload.combinedSession)
            QuotaRow(label: "Weekly", quota: payload.combinedWeekly)
            divider
        }
        if let active = payload.activeAccount {
            HStack(spacing: 5) {
                Text(active.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("● active").font(.system(size: 8)).foregroundStyle(.green)
                Spacer()
            }
            QuotaRow(label: "Session", quota: active.session)
            QuotaRow(label: "Weekly", quota: active.weekly)
        }
        if family == .systemLarge, !payload.otherAccounts.isEmpty {
            divider
            Text("Other accounts · least used").font(.system(size: 9)).foregroundStyle(.tertiary)
            ForEach(payload.otherAccounts.prefix(4)) { account in
                CompactAccountRow(account: account)
            }
        }
        Spacer(minLength: 0)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("· \(subtitle)").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5).padding(.vertical, 1)
    }
}

// MARK: - Widget

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetUsageEndpoint.widgetKind, provider: ClaudeUsageProvider()) { entry in
            ClaudeUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude accounts' usage and projected pace.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ClaudeBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
    }
}
