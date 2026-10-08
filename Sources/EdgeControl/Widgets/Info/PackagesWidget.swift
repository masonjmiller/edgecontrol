import AppKit
import SwiftUI

public final class PackagesWidget: DashboardWidget {
    public let widgetId = "packages"
    public let displayName = "Packages"
    public let description = "Tracking numbers you add, each a tap from its carrier's tracking page"
    public let iconName = "barcode"
    public let category: WidgetCategory = .info
    public let supportedSizes = WidgetSizeRange(min: .size(3, 2), max: .size(12, 6))
    public let defaultSize = WidgetSize.size(4, 3)

    public let configSchema: [ConfigSchemaEntry] = [
        ConfigSchemaEntry(
            key: "packages", label: "Packages", type: .packageList, defaultValue: .stringArray([]),
            help:
                "UPS, USPS, FedEx, DHL, Amazon, OnTrac and LaserShip, Canada Post and international post numbers are recognised; others open on 17TRACK."
        ),
        ConfigSchemaEntry(
            key: "keep", label: "Remove After", type: .picker,
            defaultValue: .string(TrackedPackage.Keep.month.rawValue),
            options: TrackedPackage.Keep.allCases.map(\.rawValue),
            help: "A tracking link can't tell when a package arrives, so packages leave the list once they're this old."
        ),
        ConfigSchemaEntry(
            key: "showNumbers", label: "Show Tracking Numbers", type: .toggle, defaultValue: .bool(true)),
    ]
    public let defaultColors = WidgetColors(primary: .blue)
    /// Its highlights take the theme's accent, like the rest of the dashboard's.
    public let defaultsToAccentColor = true

    public init() {}

    @MainActor
    public func body(size: WidgetSize, config: WidgetConfig) -> any View {
        PackagesWidgetView(config: config)
    }
}

private struct PackagesWidgetView: View {
    let config: WidgetConfig

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var layoutEngine: LayoutEngine
    @Environment(\.themeSettings) private var ts
    /// Keeps touch zone ids apart when the widget is placed twice.
    @State private var instance = String(UUID().uuidString.prefix(8))
    /// What the last paste did, shown on the button for a few seconds.
    @State private var pasteResult: String?
    @State private var pasteResultTask: Task<Void, Never>?

    private var touchRegistry: TouchZoneRegistry { model.touchService.zoneRegistry }
    private var accent: Color { Theme.widgetPrimaryOrAccent("packages", ts: ts) }
    private var gap: CGFloat { CGFloat(ts.widgetGap) }
    private var scale: CGFloat { CGFloat(ts.fontScale) }

    private var keep: TrackedPackage.Keep {
        TrackedPackage.Keep(rawValue: config.string("keep", default: TrackedPackage.Keep.month.rawValue)) ?? .month
    }
    private var packages: [TrackedPackage] {
        TrackedPackage.pruned(TrackedPackage.decode(config.stringArray("packages")), keep: keep)
    }

    var body: some View {
        let packages = packages
        let now = Date()
        VStack(spacing: gap) {
            if packages.isEmpty {
                emptyState
                    .padding(Theme.widgetPadding)
            } else {
                TouchScrollView {
                    VStack(spacing: gap) {
                        ForEach(packages) { row($0, now: now) }
                    }
                }
            }
            pasteButton
        }
        // The rows and the button are cards of their own, so they sit inside
        // the widget the way widgets sit on the page: inset by the theme's
        // gap, and edge to edge when the gap is nothing.
        .padding(gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetCard()
        .onAppear(perform: clearOld)
    }

    // MARK: - Rows

    private func row(_ package: TrackedPackage, now: Date) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.16))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 30 * scale, height: 30 * scale)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.title)
                    .font(Theme.label(ts))
                    .foregroundStyle(Theme.text1(ts))
                    .lineLimit(1)
                Text(detailLine(package))
                    .font(Theme.caption(ts))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Text("Added " + AddedDay.name(package.added, now: now))
                    .font(Theme.micro(ts))
                    .foregroundStyle(Theme.text3(ts))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(Theme.text3(ts))
        }
        .padding(.horizontal, Theme.widgetPadding)
        .padding(.vertical, 12)
        .modifier(CardRow(ts: ts))
        .contentShape(Rectangle())
        .touchTappable(id: "packages-\(instance)-\(package.id)", registry: touchRegistry) {
            Task { @MainActor in
                if let url = package.trackingURL { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// "UPS · 1Z5R 8939 0357 5671 27", or just the carrier.
    private func detailLine(_ package: TrackedPackage) -> String {
        guard config.bool("showNumbers", default: true) else { return package.carrier.name }
        return package.carrier.name + " · " + package.spacedNumber
    }

    // MARK: - Paste

    private var pasteButton: some View {
        HStack(spacing: 8) {
            Image(systemName: pasteResult == nil ? "doc.on.clipboard" : "checkmark")
                .font(.system(size: 13 * scale, weight: .semibold))
            Text(pasteResult ?? "Paste Tracking Number")
                .font(Theme.label(ts))
                .lineLimit(1)
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .modifier(CardRow(ts: ts))
        .contentShape(Rectangle())
        .touchTappable(id: "packages-\(instance)-paste", registry: touchRegistry) {
            Task { @MainActor in paste() }
        }
    }

    /// Adds the tracking numbers on the clipboard: a number copied on its
    /// own, or a whole shipping email.
    private func paste() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let found = TrackingNumber.find(in: text)
        let current = packages
        let (list, added) = TrackedPackage.adding(found, to: current)
        if !added.isEmpty { save(list) }
        let result: String
        switch (found.isEmpty, added.count) {
        case (true, _): result = "No tracking number on the clipboard"
        case (false, 0): result = "Already on the list"
        case (false, 1): result = "Added " + added[0].title
        default: result = "Added \(added.count) packages"
        }
        pasteResultTask?.cancel()
        pasteResult = result
        pasteResultTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { pasteResult = nil }
        }
    }

    // MARK: - Keeping the list

    /// Takes packages past their time off the list for good, rather than
    /// only hiding them.
    private func clearOld() {
        let stored = TrackedPackage.decode(config.stringArray("packages"))
        if stored.count != packages.count { save(packages) }
    }

    private func save(_ list: [TrackedPackage]) {
        let pageId = config.string("_pageId")
        let instanceId = config.string("_instanceId")
        guard !pageId.isEmpty, !instanceId.isEmpty else { return }
        var stored = config
        stored["_pageId"] = nil
        stored["_instanceId"] = nil
        stored["packages"] = .stringArray(TrackedPackage.encode(list))
        layoutEngine.updateWidgetConfig(pageId: pageId, instanceId: instanceId, config: stored)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "barcode")
                .font(.system(size: 30 * scale))
                .foregroundStyle(Theme.text3(ts))
            Text("NO PACKAGES")
                .font(Theme.body(ts))
                .foregroundStyle(Theme.text3(ts))
            Text("Copy a tracking number or a shipping email, then tap Paste")
                .font(Theme.caption(ts))
                .foregroundStyle(Theme.text3(ts))
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row drawn like a widget card: the theme's card color, border and radius.
private struct CardRow: ViewModifier {
    let ts: ThemeSettings

    func body(content: Content) -> some View {
        content
            .background(Theme.cardBg(ts), in: RoundedRectangle(cornerRadius: Theme.radius(ts), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius(ts), style: .continuous)
                    .strokeBorder(Theme.border(ts), lineWidth: 1)
            )
    }
}

/// "today", "yesterday", a weekday this past week, or a date.
enum AddedDay {
    static func name(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...6:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        default:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return formatter.string(from: date)
        }
    }
}
