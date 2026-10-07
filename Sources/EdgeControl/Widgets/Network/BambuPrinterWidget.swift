import SwiftUI

public final class BambuPrinterWidget: DashboardWidget {
    public let widgetId = "bambu-printer"
    public let displayName = "Bambu Lab Printer"
    public let description = "Print progress, temperatures, filament and camera of a Bambu Lab printer"
    public let iconName = "cube"
    public let category: WidgetCategory = .network
    public let requiredServices: Set<ServiceKey> = [.bambu]
    public let supportedSizes = WidgetSizeRange(min: .size(3, 2), max: .size(12, 6))
    public let defaultSize = WidgetSize.size(6, 3)

    public let configSchema: [ConfigSchemaEntry] = [
        ConfigSchemaEntry(
            key: "host", label: "Printer", type: .bambuPrinter, defaultValue: .string(""),
            help: "The printer's network settings, on its own screen, show both its IP address and its access code."),
        ConfigSchemaEntry(
            key: "name", label: "Name", type: .text, defaultValue: .string(""),
            help: "Shown above the print. Left empty, the model is shown, such as P1S."),
        ConfigSchemaEntry(
            key: "showCamera", label: "Show Camera", type: .toggle, defaultValue: .bool(true),
            help: "The live view of P1 and A1 printers, beside the print once the widget is five columns wide."),
    ]
    /// The progress bar and the active spool's ring.
    public let defaultColors = WidgetColors(primary: .green)

    private let service: BambuService

    public init(service: BambuService) {
        self.service = service
    }

    @MainActor
    public func body(size: WidgetSize, config: WidgetConfig) -> any View {
        BambuPrinterView(
            service: service,
            host: config.string("host").trimmingCharacters(in: .whitespaces),
            name: config.string("name").trimmingCharacters(in: .whitespaces),
            showCamera: config.bool("showCamera", default: true) && size.width >= 5
        )
    }
}

private struct BambuPrinterView: View {
    @ObservedObject var service: BambuService
    let host: String
    let name: String
    let showCamera: Bool

    @Environment(\.themeSettings) private var ts
    @State private var watching: String?
    @State private var watchingCamera: String?
    @State private var onScreen = true
    @State private var offScreenTask: Task<Void, Never>?

    private var printer: BambuService.Printer? { service.printers[host] }
    private var primary: Color { Theme.widgetPrimary("bambu-printer", ts: ts, default: .green) }
    private var gap: CGFloat { max(6, CGFloat(ts.widgetGap)) }
    private var wantsCamera: Bool { showCamera && onScreen && !host.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.widgetPadding)
            .background(onScreenTracker)
            .widgetCard()
            .onAppear(perform: syncWatching)
            .onChange(of: host) { syncWatching() }
            .onChange(of: wantsCamera) { syncWatching() }
            .onDisappear {
                if let watching { service.unwatch(watching) }
                if let watchingCamera { service.unwatchCamera(watchingCamera) }
                watching = nil
                watchingCamera = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        if host.isEmpty {
            message(
                icon: "cube", title: "ADD YOUR PRINTER",
                detail: "Enter its IP address and access code in this widget's settings")
        } else if let status = printer?.status {
            GeometryReader { geo in
                HStack(spacing: gap) {
                    if showCamera, let frame = service.frames[host] {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius(ts), style: .continuous))
                            .frame(maxWidth: geo.size.width * 0.55, maxHeight: .infinity)
                    }
                    details(status)
                        .opacity(printer?.connection == .connected ? 1 : 0.55)
                }
            }
        } else {
            connectionMessage
        }
    }

    // MARK: - Details

    private func details(_ status: BambuStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(status)
            if let alert = status.alerts.first {
                Label("HMS \(alert.code)", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption(ts))
                    .foregroundStyle(alert.severity >= .serious ? Theme.accentRed : Theme.accentYellow)
                    .lineLimit(1)
            }
            if status.isActive || status.state == .finished || status.state == .failed, let job = status.jobName {
                Text(job)
                    .font(Theme.body(ts))
                    .foregroundStyle(Theme.text1(ts))
                    .lineLimit(2)
                if let stage = status.stage {
                    Text(stage)
                        .font(Theme.caption(ts))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                } else if status.state == .failed, let error = status.printError {
                    Text("Error \(error)")
                        .font(Theme.caption(ts))
                        .foregroundStyle(Theme.accentRed)
                }
                Spacer(minLength: 0)
                progress(status)
            } else {
                Text(status.state == .unknown ? "Unknown" : "Ready")
                    .font(Theme.value(ts))
                    .foregroundStyle(Theme.text1(ts))
                Spacer(minLength: 0)
            }
            temperatures(status)
            filaments(status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ status: BambuStatus) -> some View {
        let (text, color) = stateLabel(status)
        return HStack(spacing: 6) {
            Text((name.isEmpty ? printer?.model ?? "Bambu Lab" : name).uppercased())
                .font(Theme.caption(ts))
                .foregroundStyle(Theme.text3(ts))
                .lineLimit(1)
            Spacer(minLength: 4)
            if printer?.connection == .connected, status.state == .printing {
                PulsingDot(color: color, size: 6)
            }
            Text(text)
                .font(Theme.caption(ts))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func stateLabel(_ status: BambuStatus) -> (String, Color) {
        guard printer?.connection == .connected else { return ("OFFLINE", Theme.text3(ts)) }
        switch status.state {
        case .idle: return ("IDLE", Theme.text2(ts))
        case .preparing: return ("PREPARING", primary)
        case .printing: return ("PRINTING", primary)
        case .paused: return ("PAUSED", Theme.accentYellow)
        case .finished: return ("FINISHED", Theme.accentGreen)
        case .failed: return ("FAILED", Theme.accentRed)
        case .unknown: return ("—", Theme.text3(ts))
        }
    }

    private func progress(_ status: BambuStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(status.state == .paused ? Theme.accentYellow : primary)
                        .frame(width: geo.size.width * CGFloat(status.progress) / 100)
                }
            }
            .frame(height: 6)
            HStack(alignment: .firstTextBaseline) {
                Text("\(status.progress)%")
                    .font(Theme.value(ts))
                    .foregroundStyle(Theme.text1(ts))
                    .monospacedDigit()
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    if status.isActive, let minutes = status.remainingMinutes {
                        Text("\(Self.duration(minutes)) left")
                            .font(Theme.label(ts))
                            .foregroundStyle(Theme.text1(ts))
                        Text("Done \(Self.finishTime(minutes))")
                            .font(Theme.caption(ts))
                            .foregroundStyle(Theme.text3(ts))
                    }
                    if let layer = status.layer, let total = status.totalLayers {
                        Text("Layer \(layer) / \(total)")
                            .font(Theme.caption(ts))
                            .foregroundStyle(Theme.text3(ts))
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    private func temperatures(_ status: BambuStatus) -> some View {
        HStack(spacing: 12) {
            if let nozzle = status.nozzle { temperature("Nozzle", nozzle) }
            if let bed = status.bed { temperature("Bed", bed) }
        }
        .font(Theme.caption(ts))
        .lineLimit(1)
    }

    private func temperature(_ label: String, _ value: BambuStatus.Temperature) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.text3(ts))
            Text(
                value.target > 0 && value.target != value.current
                    ? "\(value.current)°/\(value.target)°" : "\(value.current)°"
            )
            .foregroundStyle(value.target > 0 ? Theme.text1(ts) : Theme.text2(ts))
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private func filaments(_ status: BambuStatus) -> some View {
        if !status.filaments.isEmpty {
            HStack(spacing: 6) {
                ForEach(status.filaments) { filament in
                    Circle()
                        .fill(filament.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .clear)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Theme.border(ts), lineWidth: 1))
                        .padding(2)
                        .overlay(Circle().strokeBorder(filament.isActive ? primary : .clear, lineWidth: 2))
                        .help("\(filament.slot): \(filament.type)")
                }
                if let active = status.filaments.first(where: \.isActive) {
                    Text("\(active.type) · \(active.slot)")
                        .font(Theme.caption(ts))
                        .foregroundStyle(Theme.text2(ts))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Before the first report

    @ViewBuilder
    private var connectionMessage: some View {
        switch printer?.connection {
        case .needsAccessCode:
            message(icon: "key", title: "ACCESS CODE NEEDED", detail: "Enter it in this widget's settings")
        case .failed(let problem):
            message(icon: "exclamationmark.triangle", title: problem.uppercased(), detail: "\(host) · trying again")
        default:
            message(icon: "cube", title: "CONNECTING", detail: host)
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 26 * ts.fontScale))
                .foregroundStyle(Theme.text3(ts))
            Text(title)
                .font(Theme.body(ts))
                .foregroundStyle(Theme.text3(ts))
            Text(detail)
                .font(Theme.caption(ts))
                .foregroundStyle(Theme.text3(ts))
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Watching

    private func syncWatching() {
        let wanted = host.isEmpty ? nil : host
        if watching != wanted {
            if let watching { service.unwatch(watching) }
            if let wanted { service.watch(wanted) }
            watching = wanted
        }
        let wantedCamera = wantsCamera ? host : nil
        if watchingCamera != wantedCamera {
            if let watchingCamera { service.unwatchCamera(watchingCamera) }
            if let wantedCamera { service.watchCamera(wantedCamera) }
            watchingCamera = wantedCamera
        }
    }

    /// Pages next to the visible one stay rendered so swipes are smooth; the
    /// camera streams only while at least half the widget is on the dashboard.
    private var onScreenTracker: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(TouchCoordinate.name))
            let bounds = geo.bounds(of: .named(TouchCoordinate.name))
            Color.clear
                .onAppear { updateOnScreen(frame: frame, bounds: bounds) }
                .onChange(of: frame) { _, newFrame in updateOnScreen(frame: newFrame, bounds: bounds) }
        }
    }

    private func updateOnScreen(frame: CGRect, bounds: CGRect?) {
        let visible: Bool = {
            guard let bounds, frame.width > 0 else { return true }
            return frame.intersection(bounds).width >= frame.width / 2
        }()
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

    // MARK: - Time

    /// 173 → "2h 53m"; 40 → "40m".
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// The clock time a print ends, with the day when it isn't today.
    static func finishTime(_ minutes: Int, from now: Date = Date()) -> String {
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        return Calendar.current.isDate(end, inSameDayAs: now)
            ? end.formatted(date: .omitted, time: .shortened)
            : end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
