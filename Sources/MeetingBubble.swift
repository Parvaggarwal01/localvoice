import AppKit
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private func makeFloatingPanel(size: NSSize) -> FloatingPanel {
    let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.acceptsMouseMovedEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

// MARK: - Recording bubble

@MainActor
final class MeetingBubbleModel: ObservableObject {
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published var title = ""
    var onStop: (() -> Void)?
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
}

/// A ~56 px always-on-top circle that pulses with the audio level. Click stops; drag moves it;
/// hovering shows the elapsed time. Dictation keeps its own HUD; this is meetings only.
@MainActor
final class MeetingBubbleController {
    static let size: CGFloat = 56
    private let positionKey = "meetings.bubbleOrigin"
    private var panel: FloatingPanel?
    private let model = MeetingBubbleModel()
    private var dragOrigin: NSPoint?
    private var dragMouseStart: NSPoint?

    func show(title: String, onStop: @escaping () -> Void) {
        model.title = title
        model.onStop = onStop
        model.onDrag = { [weak self] in self?.drag() }
        model.onDragEnd = { [weak self] in self?.endDrag() }
        if panel == nil {
            let panel = makeFloatingPanel(size: NSSize(width: Self.size, height: Self.size))
            panel.contentView = NSHostingView(rootView: MeetingBubbleView(model: model))
            self.panel = panel
        }
        guard let panel else { return }
        panel.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        panel.orderFrontRegardless()
    }

    func update(level: Double, elapsed: TimeInterval) {
        model.level = level
        model.elapsed = elapsed
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Moves by the mouse's screen position, not the gesture translation: the panel itself moves,
    /// so window-relative coordinates would feed back into the drag.
    private func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragOrigin == nil {
            dragOrigin = panel.frame.origin
            dragMouseStart = mouse
        }
        guard let origin = dragOrigin, let start = dragMouseStart else { return }
        panel.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
    }

    private func endDrag() {
        dragOrigin = nil
        dragMouseStart = nil
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set([origin.x, origin.y], forKey: positionKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let values = UserDefaults.standard.array(forKey: positionKey) as? [Double], values.count == 2 else { return nil }
        let point = NSPoint(x: values[0], y: values[1])
        let visible = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -10, dy: -10).contains(NSRect(origin: point, size: NSSize(width: Self.size, height: Self.size))) }
        return visible ? point : nil
    }

    private func defaultOrigin() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: frame.maxX - Self.size - 24, y: frame.maxY - Self.size - 24)
    }
}

private struct MeetingBubbleView: View {
    @ObservedObject var model: MeetingBubbleModel
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.22))
                .scaleEffect(0.78 + 0.22 * model.level)
                .animation(.easeOut(duration: 0.12), value: model.level)
            Circle()
                .stroke(Color.red.opacity(0.35), lineWidth: 1.5)
                .scaleEffect(pulse ? 1.0 : 0.82)
                .opacity(pulse ? 0 : 0.9)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.27, blue: 0.27), Color(red: 0.80, green: 0.12, blue: 0.20)], startPoint: .top, endPoint: .bottom))
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            if hovering {
                VStack(spacing: 0) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text(elapsedText).font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(.white)
                            .frame(width: 3, height: 6 + 12 * CGFloat(model.level) * [0.6, 1.0, 0.8, 0.5][index])
                    }
                }
                .animation(.easeOut(duration: 0.1), value: model.level)
            }
        }
        .frame(width: MeetingBubbleController.size, height: MeetingBubbleController.size)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onAppear { pulse = true }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in model.onDrag?() }
                .onEnded { _ in model.onDragEnd?() }
        )
        .onTapGesture { model.onStop?() }
        .help("Recording \(model.title) · \(elapsedText) · click to stop")
        .accessibilityElement()
        .accessibilityLabel("Meeting recording, \(elapsedText). Click to stop.")
        .accessibilityAddTraits(.isButton)
    }

    private var elapsedText: String {
        let total = Int(model.elapsed)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Prompt ("Record <title>?" / "Stop recording?")

/// A small, non-activating card in the top-right corner. It never steals focus and closes itself.
@MainActor
final class MeetingPromptController {
    private var panel: FloatingPanel?
    private var dismissTask: Task<Void, Never>?
    private(set) var isShowing = false
    private var onTimeout: (() -> Void)?

    func show(title: String, subtitle: String, primary: String, secondary: String, timeout: TimeInterval = 90,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        hide()
        let size = NSSize(width: 300, height: 92)
        let view = MeetingPromptView(title: title, subtitle: subtitle, primary: primary, secondary: secondary,
                                     onPrimary: { [weak self] in self?.hide(); onPrimary() },
                                     onSecondary: { [weak self] in self?.hide(); onSecondary() })
        let panel = makeFloatingPanel(size: size)
        panel.contentView = NSHostingView(rootView: view)
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
        panel.orderFrontRegardless()
        self.panel = panel
        isShowing = true
        onTimeout = onSecondary
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let timeoutAction = self.onTimeout
            self.hide()
            timeoutAction?()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        onTimeout = nil
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }
}

private struct MeetingPromptView: View {
    let title: String
    let subtitle: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)
                .background(Color.red.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button(primary, action: onPrimary).buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                    Button(secondary, action: onSecondary).buttonStyle(.bordered).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 300, height: 92)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.10)))
    }
}
