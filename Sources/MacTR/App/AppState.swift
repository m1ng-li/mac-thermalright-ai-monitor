// AppState.swift — App-wide state management
//
// USB I/O runs entirely on a background queue. Only UI state updates
// dispatch to @MainActor. This prevents USB timeouts from blocking
// the main thread (which causes macOS rainbow spinner + keyboard freeze).

import AppKit
import Foundation
import Observation

// MARK: - Display Set

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

enum DisplaySet: String, CaseIterable, Identifiable, Sendable {
    case systemMonitor = "System Monitor"

    var id: String { rawValue }
}

// MARK: - Night schedule

/// Nightly window during which the LCD is blanked and the dashboard shows on the
/// Mac instead. Defaults to 18:30 → 09:00 (spans midnight).
enum NightSchedule {
    static let startMinute = 18 * 60 + 30   // 18:30
    static let endMinute = 9 * 60           // 09:00

    static var isNight: Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return startMinute < endMinute
            ? (m >= startMinute && m < endMinute)      // same-day window
            : (m >= startMinute || m < endMinute)      // window spanning midnight
    }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    // Connection (UI-facing)
    var isConnected = false
    var deviceInfo: DeviceInfo?
    var statusMessage = "Disconnected"

    // Display
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int = 5
    var refreshInterval: Double = 0.5
    var rotateDisplay: Bool = false

    // AI Agents panel — which source fills each column
    var leftAgent: AgentKind = AgentKind.left
    var rightAgent: AgentKind = AgentKind.right

    // Metrics (for menu bar display)
    var frameCount = 0
    var lastFrameSize = 0

    // MARK: - Internal

    private var engine: DisplayEngine?

    // MARK: - Lifecycle

    func start() {
        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.isConnected
                self.isConnected = status.connected
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                    NotificationCenter.default.post(name: .deviceStateChanged, object: nil)
                }
            }
        }
        engine = eng
        eng.start(set: currentSet, brightness: brightness, interval: refreshInterval, rotate: rotateDisplay)
    }

    func stop() {
        engine?.stop()
        engine = nil
        isConnected = false
        statusMessage = "Stopped"
    }

    func connect() {
        engine?.reconnect()
    }

    func disconnect() {
        engine?.stop()
        isConnected = false
        statusMessage = "Disconnected"
        frameCount = 0
    }

    /// Called when user changes display set, brightness, or interval
    func applySettings() {
        engine?.updateSettings(set: currentSet, brightness: brightness, interval: refreshInterval, rotate: rotateDisplay)
    }

    /// Persist the AI Agents column mapping. The renderer reads AgentKind.left /
    /// AgentKind.right on the next frame, so no engine restart is needed.
    func applyAgentSelection() {
        AgentKind.left = leftAgent
        AgentKind.right = rightAgent
    }

    /// Latest rendered frame for the on-Mac preview window
    func currentFrame() -> CGImage? {
        engine?.currentFrame()
    }
}

// MARK: - Engine Status

struct EngineStatus: Sendable {
    let connected: Bool
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    // Cached all-black JPEG used to blank the LCD during the night window.
    nonisolated(unsafe) private static var _blackFrame: Data?
    static func blackFrame(rotate: Bool) -> Data? {
        if let f = _blackFrame { return f }
        let w = Layout.width, h = Layout.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        _blackFrame = JPEGEncoder.encode(img, brightness: 1, rotate: rotate)
        return _blackFrame
    }

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")
    private var device: USBDevice?
    private var hotplug: USBHotplug?
    private var running = false
    private var frameCount = 0
    private var lastFrameSize = 0

    // Settings (atomically accessed)
    private var currentSet: DisplaySet = .systemMonitor
    private var brightness: Int = 5
    private var interval: Double = 0.5
    private var rotateDisplay: Bool = false

    // Renderers
    private let monitorRenderer = MonitorRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(set: DisplaySet, brightness: Int, interval: Double, rotate: Bool) {
        self.currentSet = set
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate

        usbQueue.async { [weak self] in
            guard let self else { return }
            // Start background metrics collection (primes before returning)
            self.monitorRenderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    func stop() {
        running = false
        monitorRenderer.stopMetrics()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    func reconnect() {
        usbQueue.async { [weak self] in
            self?.connectAndRun()
        }
    }

    /// Latest rendered frame for the on-Mac preview window (used while the LCD
    /// is disconnected). Thread-safe: render() serializes internally.
    func currentFrame() -> CGImage? {
        monitorRenderer.render()
    }

    func updateSettings(set: DisplaySet, brightness: Int, interval: Double, rotate: Bool) {
        log("[Engine] Settings updated: set=\(set.rawValue), brightness=\(brightness), interval=\(interval), rotate=\(rotate)")
        self.currentSet = set
        self.brightness = brightness
        self.interval = interval
        self.rotateDisplay = rotate
    }

    // MARK: - Private (all on usbQueue)

    private func connectAndRun() {
        guard !running else { return }

        // Ensure metrics collection is running (may have been stopped on disconnect/sleep)
        monitorRenderer.startMetrics()

        // Close existing connection
        device?.close()
        device = nil
        frameCount = 0

        postStatus(connected: false, message: "Connecting...")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch USBError.deviceNotFound {
            postStatus(connected: false, message: "Device not found")
            return
        } catch USBError.deviceBusy {
            postStatus(connected: false, message: "Device busy (Chrome?)")
            return
        } catch {
            postStatus(connected: false, message: "Error: \(error)")
            return
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            device = dev
            postStatus(connected: true, deviceInfo: info,
                       message: "Connected (\(info.width)x\(info.height))")
            runFrameLoop(device: dev, info: info)
        } catch {
            dev.close()
            postStatus(connected: false, message: "Handshake failed")
        }
    }

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        running = true
        // Metrics already collecting in background via startMetrics()

        var nextDeadline = DispatchTime.now()

        while running {
            // Night window (18:30–09:00): blank the LCD; the dashboard shows on the
            // Mac preview instead. Refresh the black frame slowly to save power.
            let night = NightSchedule.isNight

            // Adaptive frame rate: the device sustains ~19fps, but the dashboard's
            // data only changes every ~2s. Run fast (15fps) ONLY while a column is
            // animating (agent working → breathing, or done → blinking); otherwise
            // idle at the configured interval to save CPU/power on this always-on app.
            let animating = !night && (currentSet == .systemMonitor) && monitorRenderer.wantsHighFrameRate()
            let frameInterval = night ? 3.0 : (animating ? (1.0 / 15.0) : interval)
            nextDeadline = nextDeadline + .milliseconds(Int(frameInterval * 1000))

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let set = currentSet
                let bright = brightness
                let rotate = rotateDisplay

                let jpeg: Data?

                if night {
                    jpeg = DisplayEngine.blackFrame(rotate: rotate)
                } else {
                    switch set {
                    case .systemMonitor:
                        if let image = monitorRenderer.render() {
                            jpeg = JPEGEncoder.encode(image, brightness: bright, rotate: rotate)
                        } else {
                            jpeg = nil
                        }
                    }
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
                        }
                        postStatus(connected: true, deviceInfo: nil,
                                   message: "Active")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        running = false
                        self.device?.close()
                        self.device = nil
                        postStatus(connected: false, message: "Disconnected (send error)")

                        log("[Engine] Will retry connection in 5s...")
                        Thread.sleep(forTimeInterval: 5)
                        connectAndRun()
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                Thread.sleep(forTimeInterval: Double(nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.running else { return }
                log("[Hotplug] Attempting reconnect...")
                self.monitorRenderer.startMetrics()
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.running = false
            // Metrics keep collecting — the on-Mac preview window takes over
            // rendering while the LCD is away
            self.usbQueue.async { [weak self] in
                self?.device?.close()
                self?.device = nil
                self?.postStatus(connected: false, message: "Disconnected (unplugged)")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NSWorkspace.shared.notificationCenter

            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                self.usbQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.running = false
                    self.device?.close()
                    self.device = nil
                    log("[Wake] Attempting reconnect...")
                    self.connectAndRun()
                }
            }

            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.running {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    self.usbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, !self.running else { return }
                        self.connectAndRun()
                    }
                }
            }
        }
    }

    private func postStatus(
        connected: Bool, deviceInfo: DeviceInfo? = nil, message: String
    ) {
        let status = EngineStatus(
            connected: connected,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize)
        statusCallback(status)
    }
}
