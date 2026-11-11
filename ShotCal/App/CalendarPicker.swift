import AppKit
import Observation
import SwiftUI

/// What the picker shows above the list.
struct CalendarPickerRequest {
    /// The event's title, or "3 events".
    var title: String
    /// One line per event: its date and time, with the title when there are several.
    var details: [String]
    var choices: CalendarChoices
    var preselected: Int
}

/// The small floating panel that asks which calendar the events go to.
///
/// Up, Down and 1–9 move the selection, a click does too, Return adds, Esc
/// cancels. The panel takes the keyboard without activating ShotCal, so the
/// app the user was in stays in front.
final class CalendarPicker {
    private var queue: Task<CalendarInfo?, Never>?

    /// The chosen calendar, or nil when the user cancelled. A second capture
    /// that finishes meanwhile waits for its turn.
    func choose(_ request: CalendarPickerRequest) async -> CalendarInfo? {
        let earlier = queue
        let task = Task {
            _ = await earlier?.value
            return await present(request)
        }
        queue = task
        return await task.value
    }

    private func present(_ request: CalendarPickerRequest) async -> CalendarInfo? {
        guard !request.choices.calendars.isEmpty else { return nil }
        let model = CalendarPickerModel(request)
        let panel = KeyPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Whichever comes first, a key, a button or a double click, ends it once.
        var waiting: CheckedContinuation<Bool, Never>?
        let finish: (Bool) -> Void = { confirmed in
            guard let continuation = waiting else { return }
            waiting = nil
            panel.orderOut(nil)
            continuation.resume(returning: confirmed)
        }
        model.onFinish = finish
        panel.onKey = { event in
            switch Self.command(for: event) {
            case .move(let step): model.move(by: step)
            case .select(let index): model.select(index)
            case .confirm: finish(true)
            case .cancel: finish(false)
            case nil: return false
            }
            return true
        }

        let host = NSHostingView(rootView: CalendarPickerView(model: model))
        // The hidden title bar would otherwise count as a safe area and leave
        // a gap the height of a title bar.
        host.safeAreaRegions = []
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        Self.place(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Input only arrives once this suspends and the run loop turns.
        let confirmed = await withCheckedContinuation { continuation in
            MainActor.assumeIsolated { waiting = continuation }
        }
        let chosen = confirmed ? model.selected : nil
        panel.onKey = nil
        panel.contentView = nil
        return chosen
    }

    // MARK: - Keys

    enum Command: Equatable {
        case move(Int)
        /// Zero-based, from the keys 1–9.
        case select(Int)
        case confirm
        case cancel
    }

    static func command(for event: NSEvent) -> Command? {
        command(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            hasCommand: event.modifierFlags.contains(.command)
        )
    }

    static func command(keyCode: UInt16, characters: String?, hasCommand: Bool = false) -> Command? {
        guard !hasCommand else { return nil }
        switch keyCode {
        case 126: return .move(-1) // up
        case 125: return .move(1) // down
        case 36, 76: return .confirm // return, keypad enter
        case 53: return .cancel // esc
        default: break
        }
        if let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
            return .select(digit - 1)
        }
        return nil
    }

    // MARK: - Placement

    /// Upper middle of the screen the pointer is on, where the selection was
    /// just made.
    private static func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return panel.center() }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.minY + (area.height - size.height) * 0.62
        ))
    }
}

/// A panel that can take the keyboard although it has no title bar, and that
/// hands key presses to the picker before any view sees them.
private final class KeyPanel: NSPanel {
    /// Returns true when the key was used.
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@Observable
final class CalendarPickerModel {
    let title: String
    let details: [String]
    let choices: CalendarChoices
    private(set) var selection: Int

    /// True: add to the selected calendar. False: cancel.
    @ObservationIgnored var onFinish: ((Bool) -> Void)?

    init(_ request: CalendarPickerRequest) {
        title = request.title
        details = request.details
        choices = request.choices
        selection = min(max(request.preselected, 0), max(request.choices.calendars.count - 1, 0))
    }

    var selected: CalendarInfo? {
        choices.calendars.indices.contains(selection) ? choices.calendars[selection] : nil
    }

    /// Stops at the ends instead of wrapping.
    func move(by step: Int) {
        select(min(max(selection + step, 0), choices.calendars.count - 1))
    }

    func select(_ index: Int) {
        guard choices.calendars.indices.contains(index) else { return }
        selection = index
    }
}

private struct CalendarPickerView: View {
    let model: CalendarPickerModel

    private static let rowHeight: CGFloat = 28
    private static let visibleRows = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(2)
                ForEach(Array(model.details.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.choices.calendars.enumerated()), id: \.offset) { index, calendar in
                            row(index, calendar).id(index)
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(min(model.choices.calendars.count, Self.visibleRows)))
                .onChange(of: model.selection) { _, selection in proxy.scrollTo(selection) }
                .onAppear { proxy.scrollTo(model.selection) }
            }

            HStack {
                Text("↑ ↓ or 1–9, then Return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.onFinish?(false) }
                Button("Add") { model.onFinish?(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func row(_ index: Int, _ calendar: CalendarInfo) -> some View {
        let isSelected = index == model.selection
        return HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: calendar.colorHex) ?? Color.secondary)
                .overlay(Circle().strokeBorder(.white.opacity(isSelected ? 0.8 : 0), lineWidth: 1))
                .frame(width: 10, height: 10)
            Text(model.choices.labels[index])
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if index < 9 {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // A double click is a click followed by Return.
        .onTapGesture(count: 2) {
            model.select(index)
            model.onFinish?(true)
        }
        .simultaneousGesture(TapGesture().onEnded { model.select(index) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension Color {
    /// From "#RRGGBB"; nil for anything else.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
