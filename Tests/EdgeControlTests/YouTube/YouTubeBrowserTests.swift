import Foundation
import Testing

@testable import EdgeControl

@Suite("YouTube: where the browser goes")
struct YouTubeBrowserTests {

    @Test("words become a YouTube search; a YouTube link is opened as it is")
    func searchURLs() {
        #expect(
            YouTubeBrowserModel.searchURL("  lofi beats ")?.absoluteString
                == "https://www.youtube.com/results?search_query=lofi%20beats")
        #expect(
            YouTubeBrowserModel.searchURL("https://youtu.be/dQw4w9WgXcQ")?.absoluteString
                == "https://youtu.be/dQw4w9WgXcQ")
        #expect(YouTubeBrowserModel.searchURL("   ") == nil)
    }

    @Test("a link to another site is searched for, not opened in the signed-in tile")
    func otherSitesAreSearched() {
        #expect(
            YouTubeBrowserModel.searchURL("https://example.com/x")?.host == "www.youtube.com")
    }

    @Test("only YouTube and Google pages stay in the tile; the rest open in the browser")
    func staysInPanel() {
        #expect(YouTubeBrowserModel.opensInPanel(URL(string: "https://www.youtube.com/watch?v=x")!))
        #expect(YouTubeBrowserModel.opensInPanel(URL(string: "https://accounts.google.com/signin")!))
        #expect(!YouTubeBrowserModel.opensInPanel(URL(string: "https://example.com/")!))
        #expect(!YouTubeBrowserModel.opensInPanel(URL(string: "https://notyoutube.com/")!))
        #expect(!YouTubeBrowserModel.opensInPanel(URL(string: "http://www.youtube.com/")!))
    }
}

@Suite("YouTube: the player")
struct YouTubePlayerTests {

    @Test("watch, Shorts and live pages fill the tile; the rest of YouTube doesn't")
    func watchPages() {
        #expect(YouTubeBrowserModel.isWatchPage(URL(string: "https://www.youtube.com/watch?v=abc")))
        #expect(YouTubeBrowserModel.isWatchPage(URL(string: "https://m.youtube.com/shorts/abc")))
        #expect(YouTubeBrowserModel.isWatchPage(URL(string: "https://www.youtube.com/live/abc")))
        #expect(!YouTubeBrowserModel.isWatchPage(URL(string: "https://www.youtube.com/results?search_query=x")))
        #expect(!YouTubeBrowserModel.isWatchPage(URL(string: "https://www.youtube.com/")))
        #expect(!YouTubeBrowserModel.isWatchPage(URL(string: "https://example.com/watch")))
        #expect(!YouTubeBrowserModel.isWatchPage(nil))
    }

    @Test("the player's state reads from what the page script returns")
    func state() throws {
        let raw: [String: Any] = [
            "paused": false, "time": 229.4, "duration": 575, "title": "A video", "ad": false, "canSkip": false,
            "hasNext": true,
        ]
        let state = try #require(YouTubeVideoState(raw))
        #expect(!state.paused)
        #expect(state.duration == 575)
        #expect(abs(state.progress - 229.4 / 575) < 0.0001)
        #expect(state.hasNext)
        #expect(YouTubeVideoState(nil) == nil)
        #expect(YouTubeVideoState(["title": "no video"]) == nil)
    }

    @Test("times read as the player shows them")
    func clock() {
        #expect(YouTubeVideoState.clock(0) == "0:00")
        #expect(YouTubeVideoState.clock(229.9) == "3:49")
        #expect(YouTubeVideoState.clock(3727) == "1:02:07")
    }
}

@Suite("YouTube: dark mode")
struct YouTubeDarkModeTests {

    @Test("dark mode sets YouTube's dark flag, and keeps the cookie's other settings")
    func dark() {
        #expect(YouTubeBrowserModel.preference(nil, dark: true) == "f6=400")
        #expect(
            YouTubeBrowserModel.preference("f4=4000000&tz=America.New_York", dark: true)
                == "f4=4000000&tz=America.New_York&f6=400")
        // The light flag goes; other flags stay.
        #expect(YouTubeBrowserModel.preference("f6=40080000&hl=en", dark: true) == "f6=40000400&hl=en")
    }

    @Test("turning it off takes only the dark flag away")
    func light() {
        #expect(YouTubeBrowserModel.preference("f4=4000000&f6=400", dark: false) == "f4=4000000")
        #expect(YouTubeBrowserModel.preference("f6=40000400", dark: false) == "f6=40000000")
        #expect(YouTubeBrowserModel.preference(nil, dark: false) == "")
    }
}

@Suite("YouTube: on screen or not")
struct YouTubeOnScreenTests {
    @Test("a tile on the right half of the dashboard keeps playing; one on the next page pauses")
    func onScreen() {
        let tile = CGSize(width: 1024, height: 600)
        #expect(YouTubeSessions.isOnScreen(size: tile, dashboard: CGRect(x: -1536, y: 0, width: 2560, height: 720)))
        #expect(!YouTubeSessions.isOnScreen(size: tile, dashboard: CGRect(x: -2660, y: 0, width: 2560, height: 720)))
        #expect(YouTubeSessions.isOnScreen(size: tile, dashboard: nil))
    }
}

@Suite("YouTube: video quality")
struct YouTubeQualityTests {
    private let all = ["hd2160", "hd1440", "hd1080", "hd720", "large", "medium", "small", "tiny", "auto"]

    @Test("half as tall again as the picture, and 720p at least")
    func sharpForTheTile() {
        // An 8×5 tile's picture on the Edge is about 576 pixels tall.
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 576, offered: all) == "hd1080")
        // A small tile still gets 720p, not the 360p its size alone would get.
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 288, offered: all) == "hd720")
        // A picture 1080 pixels tall, on a Retina display, say.
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 1080, offered: all) == "hd2160")
    }

    @Test("a video not offered that high plays at its best")
    func bestOffered() {
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 576, offered: ["small", "tiny", "auto"]) == "small")
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 576, offered: ["auto"]) == nil)
        #expect(YouTubeBrowserModel.quality(forPixelHeight: 576, offered: []) == nil)
    }
}
