import AppKit

/// Notices when something is being dragged anywhere on screen, and turns a shake
/// (or a held ⇧) during that drag into "open a shelf here".
///
/// Needs no permissions: watching mouse-down is allowed without Accessibility, and
/// while the button is held the pointer is polled. A real content drag is recognised
/// by the drag pasteboard changing; moving a window or selecting text doesn't change it.
final class DragWatcher {
    static let shared = DragWatcher()

    /// Asked to open a shelf at the pointer, at most once per drag.
    var onOpenRequest: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private(set) var isDragging = false
    /// The drag began in a Dropod window (items being dragged out of Dropod). Those never
    /// open Dropod again: it's already right there.
    private(set) var startedInDropod = false

    private var monitors: [Any] = []
    private var timer: Timer?
    private var startChangeCount = 0
    private var openedThisDrag = false
    private var shiftArmed = false
    private var shake = ShakeDetector()

    func start() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown(inDropod: false)
        }) { monitors.append(monitor) }
        // Drags that start in Dropod itself, such as dragging items out of a tab.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.mouseDown(inDropod: true)
            return event
        }) { monitors.append(monitor) }
    }

    /// A shelf was opened another way during this drag (the shortcut), so a shake won't open a second one.
    func markOpened() { openedThisDrag = true }

    private func mouseDown(inDropod: Bool) {
        startedInDropod = inDropod
        timer?.invalidate()
        startChangeCount = NSPasteboard(name: .drag).changeCount
        isDragging = false
        openedThisDrag = false
        let poll = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer?.invalidate()
            timer = nil
            if isDragging {
                isDragging = false
                onDragEnded?()
            }
            return
        }

        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        if !isDragging {
            guard NSPasteboard(name: .drag).changeCount != startChangeCount else { return }
            isDragging = true
            shake.reset()
            // ⇧ already down when the drag began (a ⇧-click selection) doesn't count.
            shiftArmed = !shiftHeld
        }
        guard !openedThisDrag, !startedInDropod else { return }

        let point = NSEvent.mouseLocation
        let shaken = shake.feed(x: point.x, time: ProcessInfo.processInfo.systemUptime) && Settings.shakeToOpen
        if !shiftHeld { shiftArmed = true }
        let shifted = Settings.shiftToOpen && shiftArmed && shiftHeld
        if shaken || shifted {
            openedThisDrag = true
            onOpenRequest?(point)
        }
    }
}

/// Recognises a quick left-right-left shake of the pointer.
struct ShakeDetector {
    /// How far the pointer must travel back before a change of direction counts.
    static let minTravel: CGFloat = 28
    static let reversalsNeeded = 3
    /// All reversals must happen within this many seconds.
    static let window: TimeInterval = 0.8

    private var origin: CGFloat?
    private var direction: CGFloat = 0
    private var extreme: CGFloat = 0
    private var reversals: [TimeInterval] = []

    mutating func reset() {
        origin = nil
        direction = 0
        reversals = []
    }

    /// Feeds the pointer's x position; returns true when a shake is complete.
    mutating func feed(x: CGFloat, time: TimeInterval) -> Bool {
        guard let start = origin else {
            origin = x
            extreme = x
            return false
        }
        if direction == 0 {
            if abs(x - start) > 8 {
                direction = x > start ? 1 : -1
                extreme = x
            }
            return false
        }
        // Still moving the same way: remember how far it got.
        if (x - extreme) * direction > 0 {
            extreme = x
            return false
        }
        guard abs(x - extreme) >= Self.minTravel else { return false }
        direction = -direction
        extreme = x
        reversals.append(time)
        reversals.removeAll { time - $0 > Self.window }
        return reversals.count >= Self.reversalsNeeded
    }
}
