#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Quick alarms set from the overlay. When one is due it takes over every screen with a loud,
/// looping alarm until you snooze it (5 minutes) or stop it. Alarms survive relaunches.
@MainActor @Observable
final class AlarmCenter {
    struct Alarm: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var fireAt: Date
        var label: String
        var snoozes = 0
    }

    static let snoozeMinutes = 5

    private(set) var alarms: [Alarm] = []
    private(set) var ringing: Alarm?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var takeover: AlarmTakeover?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    private let defaultsKey: String

    init(defaultsKey: String = "alarms.pending") {
        self.defaultsKey = defaultsKey
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = saved.sorted { $0.fireAt < $1.fireAt }
        }
        // Timers pause while the Mac sleeps; check right away on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.tick() } }
        updateTimer()
    }

    @discardableResult
    func add(at date: Date, label: String) -> Alarm {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let alarm = Alarm(fireAt: date, label: title.isEmpty ? "Alarm" : title)
        alarms.append(alarm)
        alarms.sort { $0.fireAt < $1.fireAt }
        save()
        tick()
        return alarm
    }

    func cancel(_ id: Alarm.ID) {
        alarms.removeAll { $0.id == id }
        save()
        if ringing?.id == id { stopRinging() }
    }

    func snooze() {
        guard var alarm = ringing else { return }
        alarms.removeAll { $0.id == alarm.id }
        alarm.fireAt = Date.now.addingTimeInterval(TimeInterval(Self.snoozeMinutes * 60))
        alarm.snoozes += 1
        alarms.append(alarm)
        alarms.sort { $0.fireAt < $1.fireAt }
        save()
        stopRinging()
    }

    func stop() {
        guard let alarm = ringing else { return }
        alarms.removeAll { $0.id == alarm.id }
        save()
        stopRinging()
    }

    // MARK: Ringing

    private func tick() {
        if ringing == nil, let due = alarms.first(where: { $0.fireAt <= .now }) {
            ringing = due
            let takeover = AlarmTakeover(center: self)
            self.takeover = takeover
            takeover.show()
        }
        updateTimer()
    }

    private func stopRinging() {
        takeover?.close()
        takeover = nil
        ringing = nil
        // Another alarm may already be due; give the screen a beat before it rings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
    }

    private func updateTimer() {
        if alarms.isEmpty || ringing != nil {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alarms), forKey: defaultsKey)
    }
}

/// One borderless window per screen, above everything (including full-screen apps), plus the sound.
@MainActor
private final class AlarmTakeover {
    private weak var center: AlarmCenter?
    private var windows: [AlarmWindow] = []
    private let sound = AlarmSound()
    /// Whatever you were using gets focus back once the alarm is dealt with.
    private var previousApplication: NSRunningApplication?
    /// The screen under the mouse, which takes the keyboard.
    private weak var primary: AlarmWindow?
    private var focusTimer: Timer?

    init(center: AlarmCenter) { self.center = center }

    func show() {
        guard let center, let alarm = center.ringing else { return }
        let mouse = NSEvent.mouseLocation
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        for screen in NSScreen.screens {
            // A non-activating panel, like the overlay: it can sit on top of another app's full-screen
            // Space and take the keyboard. Activating the app instead (a normal window) makes macOS
            // switch to the app's own Space, which left the alarm behind full-screen apps.
            let window = AlarmWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.onSnooze = { [weak center] in center?.snooze() }
            window.onStop = { [weak center] in center?.stop() }
            window.contentView = NSHostingView(rootView: AlarmTakeoverView(
                alarm: alarm,
                onSnooze: { [weak center] in center?.snooze() },
                onStop: { [weak center] in center?.stop() }))
            window.setFrame(screen.frame, display: true)
            windows.append(window)
        }
        primary = windows.first { $0.screen?.frame.contains(mouse) == true } ?? windows.first
        sound.start()
        takeFocus()
        // Take it again next tick (the same approach as Mac Lock's cover), and keep taking it back while it rings.
        DispatchQueue.main.async { [weak self] in self?.takeFocus() }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let primary = self.primary else { return }
                if !primary.isKeyWindow || !primary.isVisible || !primary.isOnActiveSpace { self.takeFocus() }
            }
        }
    }

    /// Front of every screen (full-screen Spaces included) and the keyboard, without switching Spaces.
    private func takeFocus() {
        for window in windows { window.orderFrontRegardless() }
        primary?.makeKeyAndOrderFront(nil)
        primary?.makeFirstResponder(primary?.contentView)
    }

    func close() {
        focusTimer?.invalidate()
        focusTimer = nil
        sound.stop()
        for window in windows { window.orderOut(nil) }
        windows = []
        primary = nil
        previousApplication?.activate(options: [])
        previousApplication = nil
    }
}

@MainActor
private final class AlarmWindow: NSPanel {
    var onSnooze: (() -> Void)?
    var onStop: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (_, "s"), (49, _): onSnooze?()        // S or Space
        case (53, _), (36, _), (76, _): onStop?()  // Escape, Return, Enter
        default: break
        }
    }
    override func cancelOperation(_ sender: Any?) { onStop?() }
}

/// Full-screen and impossible to miss, without strobing: the red breathes about once a second.
struct AlarmTakeoverView: View {
    let alarm: AlarmCenter.Alarm
    let onSnooze: () -> Void
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi * 0.9) + 1) / 2
            ZStack {
                RadialGradient(colors: [Color(red: 0.86 + 0.12 * pulse, green: 0.16 + 0.08 * pulse, blue: 0.16),
                                        Color(red: 0.42, green: 0.04, blue: 0.07)],
                               center: .center, startRadius: 40, endRadius: 1100)
                VStack(spacing: 0) {
                    Label("ALARM", systemImage: "alarm.waves.left.and.right.fill")
                        .font(.system(size: 22, weight: .heavy)).tracking(4)
                        .symbolEffect(.wiggle, options: .repeating, isActive: !reduceMotion)
                        .opacity(0.9)
                    Text(alarm.fireAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 150, weight: .bold, design: .rounded)).monospacedDigit()
                        .padding(.top, 10)
                    Text(alarm.label).font(.system(size: 48, weight: .bold)).multilineTextAlignment(.center).lineLimit(3)
                    if let late = lateText(context.date) {
                        Text(late).font(.system(size: 20, weight: .semibold)).opacity(0.75).padding(.top, 8)
                    }
                    HStack(spacing: 20) {
                        Button(action: onSnooze) {
                            VStack(spacing: 4) {
                                Label("Snooze \(AlarmCenter.snoozeMinutes) min", systemImage: "zzz")
                                Text("S or Space").font(.system(size: 13, weight: .semibold)).opacity(0.7)
                            }
                            .frame(width: 300, height: 96)
                        }
                        .buttonStyle(TakeoverButtonStyle(fill: .white.opacity(0.18), stroke: .white.opacity(0.6)))
                        Button(action: onStop) {
                            VStack(spacing: 4) {
                                Label("Stop", systemImage: "stop.fill")
                                Text("Return or Esc").font(.system(size: 13, weight: .semibold)).opacity(0.6)
                            }
                            .frame(width: 300, height: 96)
                        }
                        .buttonStyle(TakeoverButtonStyle(fill: .white, foreground: Color(red: 0.7, green: 0.08, blue: 0.1)))
                    }
                    .padding(.top, 48)
                    if alarm.snoozes > 0 {
                        Text("Snoozed \(alarm.snoozes)×").font(.system(size: 15, weight: .semibold)).opacity(0.6).padding(.top, 18)
                    }
                }
                .foregroundStyle(.white)
                .padding(60)
            }
        }
        .ignoresSafeArea()
    }

    private func lateText(_ now: Date) -> String? {
        let seconds = Int(now.timeIntervalSince(alarm.fireAt))
        if seconds >= 3600 { return "Missed: was due \(alarm.fireAt.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))" }
        return seconds >= 60 ? "Ringing for \(seconds / 60) min" : nil
    }
}

private struct TakeoverButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white
    var stroke: Color = .clear
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(foreground)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(stroke, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A classic alarm-clock beep (four quick beeps, then a pause), generated in memory and looped.
@MainActor
private final class AlarmSound {
    private var sound: NSSound?

    func start() {
        guard sound == nil, let sound = NSSound(data: Self.wav()) else { return }
        sound.loops = true
        sound.volume = 1
        sound.play()
        self.sound = sound
    }

    func stop() {
        sound?.stop()
        sound = nil
    }

    private static func wav() -> Data {
        let rate = 44_100
        var samples = [Int16](repeating: 0, count: rate)   // One second per loop.
        for beep in 0..<4 {
            let start = Int(Double(beep) * 0.13 * Double(rate))
            let length = Int(0.08 * Double(rate))
            for i in 0..<length {
                let t = Double(i) / Double(rate)
                let envelope = min(1, Double(i) / 200, Double(length - i) / 200)
                // A square-ish 2.4 kHz tone cuts through other audio.
                let value = sin(2 * .pi * 2400 * t) + 0.35 * sin(2 * .pi * 7200 * t)
                samples[start + i] = Int16(max(-1, min(1, value * 0.85 * envelope)) * Double(Int16.max))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
#endif
