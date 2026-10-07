import SwiftUI

/// The printer a Bambu Lab widget shows: its address, kept in the layout, and
/// its access code, kept in the Keychain. Both are on the printer's own
/// network settings screen. Connecting happens as soon as they're saved, so
/// the line underneath says straight away whether the code was right.
struct BambuPrinterEditor: View {
    let entry: ConfigSchemaEntry
    @Binding var config: WidgetConfig
    @ObservedObject var service: BambuService
    let accent: Color

    @State private var address = ""
    @State private var code = ""
    @State private var hasSavedCode = false
    @State private var keychainError = false

    private var savedHost: String { config.string(entry.key).trimmingCharacters(in: .whitespaces) }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("IP Address") {
                TextField("192.168.1.50", text: $address)
                    .onSubmit(save)
            }
            row("Access Code") {
                SecureField(hasSavedCode && trimmedAddress == savedHost ? "Saved" : "8 characters", text: $code)
                    .onSubmit(save)
            }
            HStack(spacing: 8) {
                statusLine
                Spacer()
                Button(trimmedAddress == savedHost && code.isEmpty ? "Reconnect" : "Connect", action: save)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .disabled(trimmedAddress.isEmpty)
            }
        }
        .onAppear {
            address = savedHost
            hasSavedCode = service.hasAccessCode(for: savedHost)
        }
    }

    private func row(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            field()
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    private func save() {
        let host = trimmedAddress
        guard !host.isEmpty else { return }
        keychainError = false
        config[entry.key] = .string(host)
        if code.trimmingCharacters(in: .whitespaces).isEmpty {
            service.reconnect(host)
        } else {
            do {
                try service.setAccessCode(code, for: host)
                code = ""
            } catch {
                keychainError = true
            }
        }
        hasSavedCode = service.hasAccessCode(for: host)
    }

    @ViewBuilder
    private var statusLine: some View {
        let (text, color): (String, Color) = {
            if keychainError { return ("Couldn't save the code to the Keychain", Theme.accentRed) }
            guard !savedHost.isEmpty, let printer = service.printers[savedHost] else { return ("", Theme.textTertiary) }
            switch printer.connection {
            case .connected: return ("Connected to \(printer.model ?? "the printer")", Theme.accentGreen)
            case .connecting: return ("Connecting…", Theme.textTertiary)
            case .needsAccessCode: return ("Enter the access code", Theme.accentYellow)
            case .failed(let problem): return (problem, Theme.accentRed)
            }
        }()
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
