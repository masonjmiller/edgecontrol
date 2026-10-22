// Started from edward-mcnair's YouTube widget (kemalandic/edgecontrol#33). His:
// the persistent sign-in, the video-filling styles, which pages stay in the
// tile, crash recovery and page dialogs. Added since: first clicks reaching the
// page, dark mode, the player's state and controls for the tile's own overlay,
// opening videos filled, and choosing a quality for the tile's size. The
// toolbar, search and touch are in YouTubeWidget.swift.

import AppKit
import SwiftUI
import WebKit

@MainActor
final class YouTubeBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var hasLoaded = false
    @Published var status = ""
    @Published var fillsVideoArea = false
    @Published var changingVideoArea = false
    /// The video on the page, read twice a second while the tile shows.
    @Published private(set) var video: YouTubeVideoState?
    /// On a video's page, filled or not.
    @Published private(set) var onWatchPage = false
    /// Videos open filling the tile; Browse shows the page around this one,
    /// until the next video.
    var fillsVideos = true
    private(set) var browsingWatchPage = false
    /// How tall the video is drawn, in pixels, for choosing its quality.
    private(set) var pictureHeight: CGFloat = 0
    /// The video and quality last settled on, so a quality picked in
    /// YouTube's own menu afterwards isn't overruled.
    private var qualitySettled: String?
    private var qualityPending: String?
    private var qualityAttempts = 0
    private var layoutGeneration = 0
    private var urlObservation: NSKeyValueObservation?
    let webView: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: UUID(uuidString: "D9F84713-FA9B-48C6-9037-1235638CD107")!)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The tile's own play button and tap-to-pause call play() from script.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = TouchWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = .black
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.browsingWatchPage = false
                self.onWatchPage = self.isWatchPage
                // Video to video, the styles follow the player; anywhere
                // else, the page comes back.
                if self.fillsVideoArea && !self.isWatchPage { await self.setVideoAreaFilled(false) }
            }
        }
        // Deliberately no user-agent spoofing, injected auth scripts or cookie imports.
    }

    /// In a web view YouTube ignores the system's dark mode and keeps its
    /// theme in its PREF cookie, so the cookie is set before the page loads
    /// (and the page reloaded if it already has). Its other settings stay.
    func setDark(_ dark: Bool) async {
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.underPageBackgroundColor = dark ? .black : .white
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let current = await store.allCookies().first { $0.name == "PREF" && $0.domain.hasSuffix("youtube.com") }
        let value = Self.preference(current?.value, dark: dark)
        guard value != current?.value,
            let cookie = HTTPCookie(properties: [
                .domain: ".youtube.com", .path: "/", .name: "PREF", .value: value, .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 2 * 365 * 24 * 3600),
            ])
        else { return }
        await store.setCookie(cookie)
        if hasLoaded { webView.reload() }
    }

    /// PREF is `key=value` pairs joined by `&`; `f6` holds hex flags, where
    /// 0x400 is the dark theme and 0x80000 the light one.
    nonisolated static func preference(_ current: String?, dark: Bool) -> String {
        var parts = (current ?? "").split(separator: "&").map(String.init)
        let index = parts.firstIndex { $0.hasPrefix("f6=") }
        var flags = index.flatMap { UInt64(parts[$0].dropFirst(3), radix: 16) } ?? 0
        flags = dark ? (flags | 0x400) & ~0x80000 : flags & ~0x400
        let entry = "f6=" + String(flags, radix: 16)
        switch (index, flags) {
        case (let index?, 0): parts.remove(at: index)
        case (let index?, _): parts[index] = entry
        case (nil, 0): break
        case (nil, _): parts.append(entry)
        }
        return parts.joined(separator: "&")
    }

    var isWatchPage: Bool { Self.isWatchPage(webView.url) }

    nonisolated static func isWatchPage(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(),
            host == "youtube.com" || host.hasSuffix(".youtube.com")
        else { return false }
        let path = url.path
        return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
    }

    // MARK: Player

    /// Reads the player, and fills the tile once a video's player is there.
    func tick() async {
        guard hasLoaded else { return }
        let raw = try? await webView.evaluateJavaScript(Self.stateScript)
        let state = YouTubeVideoState(raw as? [String: Any])
        if state != video { video = state }
        if let state { applyQuality(state) }
        if fillsVideos, isWatchPage, !browsingWatchPage, !fillsVideoArea, !changingVideoArea, video != nil {
            await setVideoAreaFilled(true)
        }
    }

    // MARK: Quality

    /// The size the video is drawn at. A 16:9 picture is as tall as the tile,
    /// or as the tile's width allows.
    func setPicture(size: CGSize, scale: CGFloat) {
        let height = (min(size.height, size.width * 9 / 16) * scale).rounded()
        guard height != pictureHeight else { return }
        // Bigger than before (the tile focused, say): choose again.
        if height > pictureHeight { qualitySettled = nil }
        pictureHeight = height
    }

    /// Left to itself YouTube picks from the size of the page's player before
    /// the video fills the tile, and from the connection, which in a tile
    /// came out at 480p or 720p. So the tile asks for one that's sharp at the
    /// size it's drawn, once per video.
    private func applyQuality(_ state: YouTubeVideoState) {
        guard !state.ad, !state.videoId.isEmpty, pictureHeight > 0,
            let wanted = Self.quality(forPixelHeight: pictureHeight, offered: state.levels)
        else { return }
        let key = state.videoId + "|" + wanted
        guard key != qualitySettled else { return }
        if key != qualityPending {
            qualityPending = key
            qualityAttempts = 0
        }
        if state.quality == wanted {
            qualitySettled = key
            qualityAttempts = 0
            return
        }
        // It switches within a couple of seconds; one that won't isn't
        // asked for forever.
        qualityAttempts += 1
        guard qualityAttempts <= 20 else {
            qualitySettled = key
            qualityAttempts = 0
            return
        }
        guard qualityAttempts % 4 == 1 else { return }
        webView.evaluateJavaScript(
            """
            (() => {
              const p = document.getElementById('movie_player');
              if (!p || !p.setPlaybackQualityRange) return;
              p.setPlaybackQualityRange('\(wanted)', '\(wanted)');
              if (p.setPlaybackQuality) p.setPlaybackQuality('\(wanted)');
            })()
            """
        ) { _, _ in }
    }

    /// YouTube's quality names, by the height they're labelled with.
    nonisolated static let qualityLadder: [(name: String, height: CGFloat)] = [
        ("tiny", 144), ("small", 240), ("medium", 360), ("large", 480), ("hd720", 720), ("hd1080", 1080),
        ("hd1440", 1440), ("hd2160", 2160), ("highres", 4320),
    ]

    /// Half as tall again as the picture, since YouTube's lower qualities
    /// are soft as well as small, and 720p at least. Not offered that high,
    /// the best that is.
    nonisolated static func quality(forPixelHeight height: CGFloat, offered: [String]) -> String? {
        let wanted = max(720, height * 1.5)
        let available = qualityLadder.filter { offered.contains($0.name) }
        return (available.first { $0.height >= wanted } ?? available.last)?.name
    }

    /// Back to the page around the video: its description, comments and
    /// what's next. The next video fills the tile again.
    func showPage() {
        browsingWatchPage = true
        Task { await setVideoAreaFilled(false) }
    }

    func fillVideo() {
        browsingWatchPage = false
        Task { await setVideoAreaFilled(true) }
    }

    func togglePlay() {
        run(
            "p && p.getPlayerState ? (p.getPlayerState() === 1 ? p.pauseVideo() : p.playVideo()) : (v.paused ? v.play() : v.pause())"
        )
    }
    func seek(by seconds: Int) {
        run("p && p.seekTo ? p.seekTo(p.getCurrentTime() + (\(seconds)), true) : (v.currentTime += \(seconds))")
    }
    func nextVideo() { run("p && p.nextVideo ? p.nextVideo() : document.querySelector('.ytp-next-button')?.click()") }
    /// Presses YouTube's own Skip button, once it offers one: the overlay
    /// covers the player, so the button can't be tapped through it.
    func skipAd() {
        run("document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button')?.click()")
    }

    /// YouTube's player element has its own API; the video element is the
    /// fallback when it isn't ready.
    private func run(_ body: String) {
        let script = """
            (() => {
              const p = document.getElementById('movie_player');
              const v = document.querySelector('#movie_player video') || document.querySelector('video');
              if (!p && !v) return;
              \(body);
            })()
            """
        webView.evaluateJavaScript(script) { _, _ in }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await tick()
        }
    }

    static let stateScript = """
        (() => {
          const p = document.getElementById('movie_player');
          const v = document.querySelector('#movie_player video') || document.querySelector('video');
          if (!v) return null;
          const visible = e => !!e && e.offsetParent !== null;
          const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button');
          const next = document.querySelector('.ytp-next-button');
          return {
            paused: v.paused,
            time: v.currentTime || 0,
            duration: isFinite(v.duration) ? v.duration : 0,
            title: (document.title || '').replace(/^\\(\\d+\\) /, '').replace(/ - YouTube$/, ''),
            ad: !!(p && p.classList.contains('ad-showing')),
            canSkip: visible(skip),
            hasNext: visible(next) && next.getAttribute('aria-disabled') !== 'true',
            quality: p && p.getPlaybackQuality ? p.getPlaybackQuality() : '',
            levels: p && p.getAvailableQualityLevels ? p.getAvailableQualityLevels() : [],
            videoId: p && p.getVideoData ? (p.getVideoData().video_id || '') : ''
          };
        })()
        """
    // Presentation-only styling retains the original player, account, controls and playback.
    // No iframe replacement, stream extraction, authentication changes or media reload.
    static func videoAreaScript(_ enabled: Bool) -> String {
        """
        (() => {
          const key = 'data-edge-media-path';
          const styleID = 'edge-media-video-area';
          document.getElementById(styleID)?.remove();
          document.querySelectorAll('[' + key + ']').forEach(e => e.removeAttribute(key));
          if (!\(enabled ? "true" : "false")) {
            window.dispatchEvent(new Event('resize'));
            return false;
          }
          const player = document.getElementById('movie_player');
          if (!player || !player.querySelector('video')) return false;
          // Live ancestor selectors follow YouTube when theater mode reparents its player.
          const style = document.createElement('style');
          style.id = styleID;
          style.textContent = `
            html:has(#movie_player video), body:has(#movie_player video) {
              overflow: hidden !important; background: black !important;
            }
            body:has(#movie_player video), body:has(#movie_player video) :has(#movie_player) {
              transform: none !important; perspective: none !important;
              filter: none !important; contain: none !important;
              content-visibility: visible !important; overflow: visible !important;
            }
            body:has(#movie_player video) > :not(:has(#movie_player)):not(#movie_player),
            body:has(#movie_player video) :has(#movie_player) > :not(:has(#movie_player)):not(#movie_player) {
              visibility: hidden !important; pointer-events: none !important;
            }
            #movie_player {
              position: fixed !important; inset: 0 !important; margin: 0 !important;
              width: 100vw !important; height: 100vh !important;
              min-width: 0 !important; min-height: 0 !important;
              max-width: none !important; max-height: none !important;
              z-index: 2147483647 !important; background: black !important;
            }
            #movie_player .html5-video-container {
              width: 100% !important; height: 100% !important;
            }
            #movie_player video {
              width: 100% !important; height: 100% !important;
              left: 0 !important; top: 0 !important; object-fit: contain !important;
            }
            #movie_player .ytp-chrome-bottom, #movie_player .ytp-chrome-top,
            #movie_player .ytp-gradient-bottom, #movie_player .ytp-gradient-top {
              opacity: 0 !important; pointer-events: none !important;
            }
          `;
          document.head.appendChild(style);
          window.dispatchEvent(new Event('resize'));
          return true;
        })()
        """
    }
    func toggleVideoArea() {
        guard !changingVideoArea else { return }
        Task { await setVideoAreaFilled(!fillsVideoArea) }
    }
    func setVideoAreaFilled(_ enabled: Bool) async {
        guard !enabled || ["www.youtube.com", "youtube.com", "m.youtube.com"].contains(webView.url?.host ?? "") else {
            status = "Open a YouTube video first."; return
        }
        let generation = layoutGeneration
        changingVideoArea = true
        defer { changingVideoArea = false }
        do {
            let filled = (try await webView.evaluateJavaScript(Self.videoAreaScript(enabled)) as? Bool) == true
            guard generation == layoutGeneration else { return }
            fillsVideoArea = filled
            status =
                fillsVideoArea
                ? "Video fills this panel · Restore page returns to browsing"
                : (enabled ? "Open a video before filling the video area." : "YouTube page restored")
        } catch {
            fillsVideoArea = false
            status = "Could not change video layout: \(error.localizedDescription)"
        }
    }
    func loadHome() { navigate(URL(string: "https://www.youtube.com/")!) }
    func search(_ text: String) {
        if let url = Self.searchURL(text) { navigate(url) }
    }

    /// A YouTube link as it is, or a search for the words.
    nonisolated static func searchURL(_ text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let direct = URL(string: input), direct.scheme == "https",
            ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(direct.host ?? "")
        {
            return direct
        }
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [URLQueryItem(name: "search_query", value: input)]
        return url.url
    }
    func navigate(_ url: URL) { hasLoaded = true; status = "Loading…"; webView.load(URLRequest(url: url)) }
    func openExternal() {
        let url = webView.url ?? URL(string: "https://www.youtube.com/")!
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
    func clearSession() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            [weak self] in
            Task { @MainActor in
                self?.hasLoaded = false; self?.status = "YouTube website data cleared"
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Reload may keep the same URL, so URL observation alone cannot reset the toolbar.
        layoutGeneration += 1
        fillsVideoArea = false
        status = "Loading…"
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        layoutGeneration += 1
        fillsVideoArea = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status = "\(webView.url?.host ?? "Local test")"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status = error.localizedDescription
    }
    /// Pages that belong in the panel: YouTube and Google sign-in/consent.
    /// Everything else (links in video descriptions, sponsors) opens in your
    /// browser, keeping arbitrary sites out of the signed-in panel.
    nonisolated static func opensInPanel(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let domains = ["youtube.com", "youtu.be", "google.com", "youtube-nocookie.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard ["https", "about"].contains(url.scheme ?? "") else {
            status = "Unsupported navigation was not opened"; decisionHandler(.cancel); return
        }
        // Embedded frames (players, sign-in widgets, ads) load as the page
        // needs; only whole-page navigations are kept to YouTube and Google.
        if url.scheme == "https", navigationAction.targetFrame?.isMainFrame ?? true, !Self.opensInPanel(url) {
            NSWorkspace.shared.open(url)
            status = "Opened \(url.host ?? "link") in your browser"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pop-ups: YouTube's own stay in the panel, anything else goes to the
        // browser rather than replacing the video you're watching.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" {
            if Self.opensInPanel(url) {
                navigate(url)
            } else {
                NSWorkspace.shared.open(url); status = "Opened \(url.host ?? "link") in your browser"
            }
        }
        return nil
    }

    // MARK: Recovery

    private var recentCrashes: [Date] = []
    /// WebKit's content process can be killed (memory pressure, long sleep).
    /// Without this the panel stays blank until Reload; reload automatically,
    /// but stop after repeated crashes so a broken page can't loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        layoutGeneration += 1
        fillsVideoArea = false
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard recentCrashes.count <= 2 else {
            status = "YouTube stopped repeatedly. Tap Reload to try again."
            return
        }
        status = "YouTube stopped unexpectedly · reloading"
        if webView.url != nil { webView.reload() } else if hasLoaded { loadHome() }
    }

    // MARK: Page dialogs

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "YouTube"
        alert.informativeText = message
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(); return }
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "YouTube"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(false); return }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

/// The session's web view outlives any one host: a tile on the grid and its
/// expanded (focus) copy take turns showing it. Each host is a plain container
/// that claims the web view when it is created or updated, so whichever host
/// is current shows the page however SwiftUI orders the swap.
struct YouTubeBrowserView: NSViewRepresentable {
    let model: YouTubeBrowserModel
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        claim(into: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) { claim(into: container) }
    private func claim(into container: NSView) {
        let web = model.webView
        guard web.superview !== container else { return }
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
    }
}

/// The video on the page, as the tile's controls show it.
struct YouTubeVideoState: Equatable, Sendable {
    var paused: Bool
    var time: Double
    var duration: Double
    var title: String
    var ad: Bool
    var canSkip: Bool
    var hasNext: Bool
    var quality: String
    var levels: [String]
    var videoId: String

    init?(_ raw: [String: Any]?) {
        guard let raw, let paused = raw["paused"] as? Bool else { return nil }
        self.paused = paused
        time = (raw["time"] as? Double) ?? Double(raw["time"] as? Int ?? 0)
        duration = (raw["duration"] as? Double) ?? Double(raw["duration"] as? Int ?? 0)
        title = raw["title"] as? String ?? ""
        ad = raw["ad"] as? Bool ?? false
        canSkip = raw["canSkip"] as? Bool ?? false
        hasNext = raw["hasNext"] as? Bool ?? false
        quality = raw["quality"] as? String ?? ""
        levels = raw["levels"] as? [String] ?? []
        videoId = raw["videoId"] as? String ?? ""
    }

    var progress: Double { duration > 0 ? min(1, max(0, time / duration)) : 0 }

    /// "3:07", or "1:02:07" past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// A dashboard is glanced at and tapped while another app is in front, and
/// WKWebView takes the first click only over selected text: without this, a
/// tap would only bring EdgeControl forward and never reach the page.
private final class TouchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
