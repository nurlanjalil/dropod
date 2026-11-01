import AppKit

/// Spots two quick taps in the trackpad's top-right corner from raw touch frames.
struct CornerTapDetector {
    struct Touch {
        var id: Int32
        var x: Float
        var y: Float
    }

    private struct Contact {
        var start: Double
        var startX: Float
        var startY: Float
        var x: Float
        var y: Float
        var alone: Bool
    }

    private static let cornerSize: Float = 0.15
    private static let maxMovement: Float = 0.04
    private static let maxTapLength = 0.25
    private static let maxPause = 0.35

    private var contacts: [Int32: Contact] = [:]
    private var lastTapEnd: Double?

    /// Takes every touch on the trackpad right now; true when this frame finishes a double tap.
    mutating func update(_ touches: [Touch], at time: Double) -> Bool {
        var fired = false
        let alone = touches.count == 1
        for touch in touches {
            if var contact = contacts[touch.id] {
                contact.x = touch.x
                contact.y = touch.y
                contact.alone = contact.alone && alone
                contacts[touch.id] = contact
            } else {
                contacts[touch.id] = Contact(start: time, startX: touch.x, startY: touch.y,
                                             x: touch.x, y: touch.y, alone: alone)
            }
        }
        let current = Set(touches.map(\.id))
        for (id, contact) in contacts where !current.contains(id) {
            contacts[id] = nil
            guard Self.isCornerTap(contact, endedAt: time) else {
                lastTapEnd = nil
                continue
            }
            if let lastTapEnd, contact.start - lastTapEnd <= Self.maxPause {
                fired = true
                self.lastTapEnd = nil
            } else {
                lastTapEnd = time
            }
        }
        return fired
    }

    private static func isCornerTap(_ contact: Contact, endedAt time: Double) -> Bool {
        let edge = 1 - cornerSize
        return contact.alone && time - contact.start <= maxTapLength
            && contact.startX >= edge && contact.startY >= edge && contact.x >= edge && contact.y >= edge
            && abs(contact.x - contact.startX) <= maxMovement && abs(contact.y - contact.startY) <= maxMovement
    }
}

/// Watches the trackpad through Apple's private MultitouchSupport framework, the only way to
/// see where fingers land system-wide. It is loaded at runtime, so if a macOS update removes
/// it the option just disappears. Touches are only observed: a tap still reaches macOS as usual.
final class TrackpadCorner {
    static let shared = TrackpadCorner()

    /// Runs on the main thread.
    var onDoubleTap: (() -> Void)?

    private typealias Frame = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    private struct API {
        let create: @convention(c) () -> UnsafeMutableRawPointer?
        let register: @convention(c) (UnsafeMutableRawPointer?, Frame) -> Void
        let unregister: @convention(c) (UnsafeMutableRawPointer?, Frame) -> Void
        let start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer?) -> Void
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void

        init?() {
            guard let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
                  let create = dlsym(framework, "MTDeviceCreateDefault"),
                  let register = dlsym(framework, "MTRegisterContactFrameCallback"),
                  let unregister = dlsym(framework, "MTUnregisterContactFrameCallback"),
                  let start = dlsym(framework, "MTDeviceStart"),
                  let stop = dlsym(framework, "MTDeviceStop"),
                  let release = dlsym(framework, "MTDeviceRelease")
            else { return nil }
            self.create = unsafeBitCast(create, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
            self.register = unsafeBitCast(register, to: (@convention(c) (UnsafeMutableRawPointer?, Frame) -> Void).self)
            self.unregister = unsafeBitCast(unregister, to: (@convention(c) (UnsafeMutableRawPointer?, Frame) -> Void).self)
            self.start = unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self)
            self.stop = unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
            self.release = unsafeBitCast(release, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
        }
    }

    // The framework's touch record: 96 bytes, with the id at 16 and the position (0–1) at 32.
    private static let touchSize = 96
    private static let frame: Frame = { _, data, count, time, _ in
        guard let data else { return 0 }
        let touches = (0..<Int(count)).map { index -> CornerTapDetector.Touch in
            let touch = data + index * touchSize
            return .init(id: touch.load(fromByteOffset: 16, as: Int32.self),
                         x: touch.load(fromByteOffset: 32, as: Float.self),
                         y: touch.load(fromByteOffset: 36, as: Float.self))
        }
        if detector.update(touches, at: time) {
            DispatchQueue.main.async { TrackpadCorner.shared.onDoubleTap?() }
        }
        return 0
    }
    /// Only touched from the framework's callback thread.
    private static var detector = CornerTapDetector()

    private let api = API()
    private var device: UnsafeMutableRawPointer?
    private var wakeObserver: NSObjectProtocol?

    /// False on Macs without a trackpad, or if macOS no longer has the framework.
    private(set) lazy var isAvailable: Bool = {
        guard let api, let device = api.create() else { return false }
        api.release(device)
        return true
    }()

    func start() {
        guard device == nil, let api, let device = api.create() else { return }
        api.register(device, Self.frame)
        guard api.start(device, 0) == 0 else {
            api.unregister(device, Self.frame)
            api.release(device)
            return
        }
        self.device = device
        // The device can stop delivering touches across sleep, so start it fresh on wake.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.restart()
                }
        }
    }

    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        stopDevice()
    }

    private func restart() {
        stopDevice()
        start()
    }

    private func stopDevice() {
        guard let api, let device else { return }
        api.unregister(device, Self.frame)
        api.stop(device)
        api.release(device)
        self.device = nil
    }
}
