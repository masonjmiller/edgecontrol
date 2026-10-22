import AppKit
import SwiftUI
import WebKit

/// YouTube in a tile: the real youtube.com, signed in as you, with a touch
/// toolbar and App Drawer's on-tile keyboard for searching, since typing
/// goes to whichever app is in front. The browser started as
/// edward-mcnair's (YouTubeBrowserModel.swift, from kemalandic/edgecontrol#33).
///
/// A video fills the tile and plays like a TV: the toolbar goes, a tap
/// pauses or plays and brings up the controls, and they fade again while it
/// plays. Browsing, a tap reaches the page as a click and a drag scrolls it,
/// through the dashboard's own touch handling.
public final class YouTubeWidget: DashboardWidget {
    public let widgetId = "youtube"
    public let displayName = "YouTube"
    public let description = "YouTube in a tile, signed in as you, with touch controls"
    public let iconName = "play.rectangle.fill"
    public let category: WidgetCategory = .media
    public let supportedSizes = WidgetSizeRange(min: .size(4, 3), max: .size(20, 6))
    public let defaultSize = WidgetSize.size(8, 5)
    public let configSchema: [ConfigSchemaEntry] = [
        ConfigSchemaEntry(
            key: "dark", label: "Dark Mode", type: .toggle, defaultValue: .bool(true),
            help: "YouTube follows this unless its own Appearance setting is set to Light or Dark."),
        ConfigSchemaEntry(
            key: "fillVideos", label: "Fill the Tile With Videos", type: .toggle, defaultValue: .bool(true),
            help: "A video opens filling the tile, with the tile's own controls. Browse shows the page around it."),
    ]
    public let defaultColors = WidgetColors(primary: .red)

    public init() {}

    @MainActor
    public func body(size: WidgetSize, config: WidgetConfig) -> any View {
        YouTubeWidgetBody(
            instanceId: config.string("_instanceId"), dark: config.bool("dark", default: true),
            fillVideos: config.bool("fillVideos", default: true))
    }
}

/// The catalog's preview has no placement, so no session to show.
private struct YouTubeWidgetBody: View {
    let instanceId: String
    let dark: Bool
    let fillVideos: Bool

    var body: some View {
        if instanceId.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("YouTube").font(.headline)
                Text("Browse, sign in and play on the dashboard.").font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetCard()
        } else {
            YouTubeTile(instanceId: instanceId, dark: dark, fillVideos: fillVideos)
        }
    }
}

private struct YouTubeTile: View {
    let instanceId: String
    let dark: Bool
    let fillVideos: Bool

    @StateObject private var browser: YouTubeBrowserModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.themeSettings) private var ts
    @Environment(\.displayScale) private var displayScale
    @State private var searching = false
    @State private var query = ""
    @State private var onScreen = true
    @State private var offScreenTask: Task<Void, Never>?
    @State private var controlsShown = false
    @State private var hideTask: Task<Void, Never>?

    init(instanceId: String, dark: Bool, fillVideos: Bool) {
        self.instanceId = instanceId
        self.dark = dark
        self.fillVideos = fillVideos
        // The page and what's playing outlive this view: swiping pages and
        // focusing the tile make new ones.
        _browser = StateObject(wrappedValue: YouTubeSessions.shared.model(for: instanceId))
    }

    private var registry: TouchZoneRegistry { model.touchService.zoneRegistry }
    private var accent: Color { Theme.widgetPrimary("youtube", ts: ts, default: .red) }
    private func zone(_ name: String) -> String { "youtube-\(instanceId)-\(name)" }
    private var watching: Bool { browser.fillsVideoArea }
    /// While it plays, the controls fade a few seconds after the last touch.
    private var controlsVisible: Bool { controlsShown || (browser.video?.paused ?? true) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    if !watching { toolbar }
                    YouTubeBrowserView(model: browser)
                }
                if watching { player(compact: geo.size.height < 330) }
                if searching { searchPanel(compact: geo.size.height < 330) }
            }
            .onAppear { browser.setPicture(size: geo.size, scale: displayScale) }
            .onChange(of: geo.size) { _, size in browser.setPicture(size: size, scale: displayScale) }
        }
        .animation(.easeOut(duration: 0.2), value: watching)
        .animation(.easeOut(duration: 0.25), value: controlsVisible)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius(ts), style: .continuous))
        .widgetCard()
        .background(onScreenTracker)
        .onAppear {
            browser.fillsVideos = fillVideos
            Task {
                // The theme goes in before the first page, so it never loads light.
                await browser.setDark(dark)
                if !browser.hasLoaded { browser.loadHome() }
            }
        }
        .onChange(of: dark) { _, isDark in Task { await browser.setDark(isDark) } }
        .onChange(of: fillVideos) { _, fill in
            browser.fillsVideos = fill
            if !fill && watching { browser.showPage() }
        }
        .onChange(of: onScreen) { _, visible in
            if !visible { browser.webView.pauseAllMediaPlayback(completionHandler: {}) }
        }
        .onChange(of: watching) { _, isWatching in if isWatching { showControls() } }
        // The player is read twice a second while the tile is on screen.
        .task(id: onScreen) {
            guard onScreen else { return }
            while !Task.isCancelled {
                await browser.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            offScreenTask?.cancel()
            hideTask?.cancel()
            YouTubeSessions.shared.pauseIfUnhosted(instanceId)
        }
    }

    // MARK: - Browsing

    private var toolbar: some View {
        HStack(spacing: 6) {
            button("back", symbol: "chevron.left") { browser.webView.goBack() }
            button("home", symbol: "house") { browser.loadHome() }
            searchField
            if browser.onWatchPage && fillVideos {
                button("watch", symbol: "arrow.up.left.and.arrow.down.right", title: "Watch") { browser.fillVideo() }
            }
            button("reload", symbol: "arrow.clockwise") { browser.webView.reload() }
            button("open", symbol: "safari") { browser.openExternal() }
        }
        .padding(8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            Text(query.isEmpty ? "Search YouTube" : query)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.body(ts))
        .foregroundStyle(query.isEmpty ? Theme.text3(ts) : Theme.text1(ts))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.white.opacity(0.09), in: Capsule())
        .touchTappable(id: zone("search-field"), registry: registry) {
            Task { @MainActor in searching = true }
        }
    }

    private func button(
        _ id: String, symbol: String, title: String? = nil, enabled: Bool = true,
        _ action: @escaping @MainActor () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            if let title { Text(title).font(Theme.label(ts)) }
        }
        .foregroundStyle(Theme.text1(ts).opacity(enabled ? 1 : 0.35))
        .frame(minWidth: 38, minHeight: 38)
        .padding(.horizontal, title == nil ? 0 : 10)
        .background(Color.white.opacity(0.09), in: Capsule())
        .touchTappable(id: zone(id), registry: registry, enabled: enabled) {
            Task { @MainActor in action() }
        }
    }

    // MARK: - Watching

    /// Over the filled video: a tap anywhere plays or pauses and shows the
    /// controls, which take their own taps.
    private func player(compact: Bool) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .touchTappable(id: zone("video"), registry: registry) {
                    Task { @MainActor in
                        browser.togglePlay()
                        showControls()
                    }
                }
            if controlsVisible {
                controls(compact: compact)
                    .transition(.opacity)
            }
            if let video = browser.video, video.ad {
                adBadge(video)
            }
        }
    }

    private func controls(compact: Bool) -> some View {
        let video = browser.video
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                overlayButton("w-back", symbol: "chevron.left") { browser.webView.goBack() }
                overlayButton("w-browse", symbol: "rectangle.grid.1x2", title: "Browse") { browser.showPage() }
                Text(video?.title ?? "")
                    .font(Theme.body(ts).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                overlayButton("w-search", symbol: "magnifyingglass") { searching = true }
            }
            .padding(10)
            .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)
            HStack(spacing: compact ? 18 : 28) {
                overlayButton("w-rewind", symbol: "gobackward.10", size: compact ? 44 : 52, enabled: video?.ad != true)
                {
                    browser.seek(by: -10)
                }
                overlayButton(
                    "w-play", symbol: (video?.paused ?? true) ? "play.fill" : "pause.fill", size: compact ? 58 : 72,
                    filled: true
                ) {
                    browser.togglePlay()
                }
                overlayButton("w-forward", symbol: "goforward.10", size: compact ? 44 : 52, enabled: video?.ad != true)
                {
                    browser.seek(by: 10)
                }
                if video?.hasNext == true {
                    overlayButton("w-next", symbol: "forward.end.fill", size: compact ? 44 : 52) { browser.nextVideo() }
                }
            }
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(video?.ad == true ? Theme.accentYellow : accent)
                                .frame(width: geo.size.width * (video?.progress ?? 0))
                        }
                }
                .frame(height: 5)
                HStack {
                    Text(YouTubeVideoState.clock(video?.time ?? 0))
                    Spacer()
                    Text(YouTubeVideoState.clock(video?.duration ?? 0))
                }
                .font(Theme.caption(ts).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
        .background(Color.black.opacity(0.25).allowsHitTesting(false))
    }

    /// During an ad, whether the controls show or not: the overlay covers
    /// YouTube's own Skip button, so it has one of its own.
    private func adBadge(_ video: YouTubeVideoState) -> some View {
        HStack(spacing: 8) {
            Text("Ad")
                .font(Theme.label(ts).weight(.heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accentYellow, in: Capsule())
            if video.canSkip {
                overlayButton("w-skip", symbol: "forward.fill", title: "Skip Ad", filled: true) { browser.skipAd() }
            }
        }
        .padding(14)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func overlayButton(
        _ id: String, symbol: String, title: String? = nil, size: CGFloat = 40, filled: Bool = false,
        enabled: Bool = true, _ action: @escaping @MainActor () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold))
            if let title { Text(title).font(Theme.label(ts).weight(.heavy)) }
        }
        .foregroundStyle(filled ? Self.readableText(on: accent) : .white)
        .opacity(enabled ? 1 : 0.35)
        .frame(minWidth: size, minHeight: size)
        .padding(.horizontal, title == nil ? 0 : 12)
        .background(filled ? AnyShapeStyle(accent) : AnyShapeStyle(Color.black.opacity(0.45)), in: Capsule())
        .touchTappable(id: zone(id), registry: registry, enabled: enabled) {
            Task { @MainActor in
                action()
                showControls()
            }
        }
    }

    /// Dark text on light colors like yellow, white on the rest: buttons
    /// in the widget's color sit on video, so their contrast comes from it.
    private static func readableText(on color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private func showControls() {
        controlsShown = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { controlsShown = false }
        }
    }

    // MARK: - Searching

    private func searchPanel(compact: Bool) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(query.isEmpty ? "Search or type a youtube.com link" : query + "|")
                    .font(Theme.body(ts))
                    .foregroundStyle(query.isEmpty ? Theme.text3(ts) : Theme.text1(ts))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(Color.white.opacity(0.09), in: Capsule())
                Text("Search")
                    .font(Theme.label(ts).weight(.heavy))
                    .foregroundStyle(Self.readableText(on: accent))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(accent.opacity(query.isEmpty ? 0.4 : 1), in: Capsule())
                    .touchTappable(id: zone("search-go"), registry: registry, enabled: !query.isEmpty) {
                        Task { @MainActor in submit() }
                    }
            }
            DrawerKeyboard(compact: compact, symbols: true, registry: registry, idPrefix: zone("search")) { press in
                switch press {
                case .character(let character): query += character
                case .backspace: query = String(query.dropLast())
                case .clear: query = ""
                case .hide: searching = false
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
    }

    private func submit() {
        browser.search(query)
        searching = false
    }

    // MARK: - On screen

    /// Pages beside the visible one stay rendered so swipes are smooth; a
    /// video there pauses rather than playing to nobody, a few seconds after
    /// it leaves (a swipe that springs back shouldn't stop it).
    private var onScreenTracker: some View {
        GeometryReader { geo in
            // The frame only says when to look again; whether it's on screen
            // is worked out in the tile's own coordinates.
            let frame = geo.frame(in: .named(TouchCoordinate.name))
            let dashboard = geo.bounds(of: .named(TouchCoordinate.name))
            let size = geo.size
            Color.clear
                .onAppear { updateOnScreen(size: size, dashboard: dashboard) }
                .onChange(of: frame) { _, _ in updateOnScreen(size: size, dashboard: dashboard) }
        }
    }

    private func updateOnScreen(size: CGSize, dashboard: CGRect?) {
        let visible = YouTubeSessions.isOnScreen(size: size, dashboard: dashboard)
        offScreenTask?.cancel()
        if visible {
            if !onScreen { onScreen = true }
        } else if onScreen {
            offScreenTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { onScreen = false }
            }
        }
    }
}

/// Each tile's page and player, kept through page swipes and focus mode.
@MainActor
final class YouTubeSessions {
    static let shared = YouTubeSessions()

    private var models: [String: YouTubeBrowserModel] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Nothing plays to a sleeping display or a locked Mac.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in YouTubeSessions.shared.pauseAll() }
                })
        }
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { _ in
                Task { @MainActor in YouTubeSessions.shared.pauseAll() }
            })
    }

    func model(for id: String) -> YouTubeBrowserModel {
        if let existing = models[id] { return existing }
        let model = YouTubeBrowserModel()
        models[id] = model
        return model
    }

    /// Focusing or unfocusing the tile swaps one host for another; only a
    /// session nobody has taken back once that settles is paused.
    func pauseIfUnhosted(_ id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let model = self?.models[id], model.webView.window == nil else { return }
            model.webView.pauseAllMediaPlayback(completionHandler: {})
        }
    }

    func pauseAll() {
        for model in models.values { model.webView.pauseAllMediaPlayback(completionHandler: {}) }
    }

    /// At least half the tile across is on the dashboard. `dashboard` is the
    /// dashboard's bounds in the tile's own coordinates, as
    /// `GeometryProxy.bounds(of:)` gives them. Outside a dashboard (nil), it's
    /// on screen.
    nonisolated static func isOnScreen(size: CGSize, dashboard: CGRect?) -> Bool {
        guard let dashboard, size.width > 0 else { return true }
        return CGRect(origin: .zero, size: size).intersection(dashboard).width >= size.width / 2
    }
}
