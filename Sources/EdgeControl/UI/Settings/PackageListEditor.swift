import AppKit
import SwiftUI

/// The packages a Packages widget lists. Each can be renamed, given the
/// right carrier when its number was taken for another's, or taken off; new
/// ones are typed or pasted, a whole shipping email at a time if need be.
struct PackageListEditor: View {
    let entry: ConfigSchemaEntry
    @Binding var config: WidgetConfig
    let accent: Color

    @State private var number = ""
    @State private var name = ""
    @State private var note: String?

    private var packages: [TrackedPackage] { TrackedPackage.decode(config.stringArray(entry.key)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if packages.isEmpty {
                Text("None yet. Add a tracking number below, or tap Paste on the widget.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(packages) { row($0) }

            HStack(spacing: 6) {
                TextField("Tracking number", text: $number)
                    .onSubmit(add)
                TextField("Name (optional)", text: $name)
                    .frame(width: 150)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(TrackingNumber.normalize(number).isEmpty)
                Button("Paste", action: paste)
                    .help("Adds the tracking numbers on the clipboard, from a number or a whole shipping email")
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .rounded))
            .tint(accent)

            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func row(_ package: TrackedPackage) -> some View {
        HStack(spacing: 8) {
            TextField(
                package.carrier.name + " package",
                text: Binding(get: { package.name }, set: { text in change(package) { $0.name = text } })
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            Text(package.spacedNumber)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Picker(
                "",
                selection: Binding(
                    get: { package.carrier }, set: { carrier in change(package) { $0.carrier = carrier } })
            ) {
                ForEach(Carrier.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(accent)
            .frame(width: 120)
            Button {
                save(packages.filter { $0.id != package.id })
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Theme.accentRed)
            }
            .buttonStyle(.plain)
            .help("Take this package off the widget")
        }
        .font(.system(size: 12, design: .rounded))
    }

    private func add() {
        let normalized = TrackingNumber.normalize(number)
        guard !normalized.isEmpty else { return }
        guard !packages.contains(where: { $0.number == normalized }) else {
            note = "That one's already on the list."
            return
        }
        let package = TrackedPackage(number: normalized, name: name)
        save([package] + packages)
        note =
            package.carrier == .other
            ? "Not a format recognised here, so it opens on 17TRACK. Pick the carrier if you know it."
            : "Added as \(package.carrier.name)."
        number = ""
        name = ""
    }

    private func paste() {
        let found = TrackingNumber.find(in: NSPasteboard.general.string(forType: .string) ?? "")
        let (list, added) = TrackedPackage.adding(found, to: packages)
        if !added.isEmpty { save(list) }
        switch (found.isEmpty, added.count) {
        case (true, _): note = "No tracking number on the clipboard."
        case (false, 0): note = "Those are already on the list."
        default: note = "Added " + added.map { "\($0.carrier.name) \($0.number)" }.joined(separator: ", ") + "."
        }
    }

    private func change(_ package: TrackedPackage, _ edit: (inout TrackedPackage) -> Void) {
        save(
            packages.map {
                guard $0.id == package.id else { return $0 }
                var changed = $0
                edit(&changed)
                return changed
            })
    }

    private func save(_ list: [TrackedPackage]) {
        config[entry.key] = .stringArray(TrackedPackage.encode(list))
    }
}
