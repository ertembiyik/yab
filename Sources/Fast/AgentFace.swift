import Combine
import SwiftUI
import WebKit

// An agent's tab wears a face in the slot at its end, where the close
// button, the loading ring and the speaker take turns, and the face shows
// what the agent is doing there, from what it really does: its eyes run
// along the lines while it reads, it taps when it clicks, looks down while it
// types, looks up while a page comes, and looks away while it thinks. Which
// agent it is doesn't matter to you, so every agent has the same face; its
// name, and what it is doing in words, come down from the face when the
// pointer rests on it (TabGlance).
//
// Only one thing asks for you, and only one thing is drawn solid: when the
// agent can't go on without you, the face turns into a hand. The eyes close,
// the circle becomes the palm, the hand fills with ink and waves, once as it
// lands, and a little again every few seconds, since something that keeps
// still is soon not seen. Back from you, the hand folds into the face and it
// blinks. Done, its eyes swing into a tick, held until you come to the
// tab; stuck, it looks down, likewise. Then the face goes and the tab's end
// is an ordinary tab's: quiet is all clear. A task's folder holds the tick
// while any of its tabs does (Folders, `unread`).
//
// A script is no one: its face is a robot's, the circle squared into a head
// with an antenna and a bolt at each side, its eyes the same eyes, which
// follow what the script does smoothly and never glance, blink or think,
// and between calls look ahead, dimmed. An agent taking a script's tab
// over rounds the head back into the circle and blinks.
//
// Motion is small and slow where it's constant (working), and quick only for
// the tap, which springs the way a press does on iOS: down at once, back with
// a little give (family-values-motion P6, P10).

enum FacePose: Equatable {
    case watch, read, click, type, load, think, hand, drive, done, stuck, seen
}

/// What an agent last did in which tab, for its face to show.
@MainActor
@Observable final class AgentFeed {
    static let shared = AgentFeed()

    struct Act: Equatable {
        let pose: FacePose
        let at: Date
        let count: Int
    }

    private(set) var last: [UUID: Act] = [:]
    /// Agents' tabs you took the wheel in: the agent waits until you hand
    /// them back (AgentBench refuses its actions there).
    private(set) var driving: Set<UUID> = []
    /// The one on screen, when you are driving it.
    private(set) var drivingHere: UUID?
    /// The last Stop on each page, kept for the dock after its worker leaves.
    private(set) var stopped: [UUID: String] = [:]
    /// Where the agent last clicked on each tab's page, for its pointer.
    private(set) var pointer: [UUID: AgentPoint] = [:]
    private var count = 0

    weak var browser: Browser? {
        didSet {
            watching = browser?.changes(\.activeID).sink { [weak self] _ in
                DispatchQueue.main.async { self?.update() }
            }
        }
    }
    @ObservationIgnored private var watching: AnyCancellable?
    @ObservationIgnored private var looking: [NSObjectProtocol] = []
    /// When you last clicked or typed in each page: an agent keeps its
    /// hands off the tab in front of you for a moment after.
    fileprivate(set) var touched: [UUID: Date] = [:]
    /// Tabs whose request you have answered (Agents.handBack), until the
    /// agent does something there again: the page is yours meanwhile, and
    /// a click in it takes the wheel from no one.
    private var handedOver: Set<UUID> = []

    func touchedLately(_ tab: Tab) -> Bool {
        touched[tab.id].map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    /// An agent attached through `yab mcp` stays attached for hours between
    /// calls. Its dock and its wheel are about a tab it did something in
    /// this long ago at most, and not one handed back to it since.
    nonisolated static let lingers: TimeInterval = 30

    /// How long an attached agent goes without a call before its tabs and
    /// folder stop wearing the face: longer than it thinks between calls,
    /// short enough that a finished turn doesn't read as work for hours.
    nonisolated static let rests: TimeInterval = 90

    /// An attached agent gone quiet: its tabs' ends are ordinary ones again
    /// (`settled`), with no tick, as it answered in its own terminal. Its
    /// next step anywhere brings the face back there (`did`).
    func rest(_ session: Agents.Session) {
        guard session.resting else { return }
        for tab in everyTab() where tab.worker == session.id && tab.handoff == nil && tab.permit == nil && !driving.contains(tab.id) {
            if tab.settled != session.id { tab.settled = session.id }
        }
        Folders.shared.refresh()
        session.lull &+= 1
    }

    func atWorkHere(_ tab: Tab) -> Bool {
        guard !handedOver.contains(tab.id), let act = last[tab.id] else { return false }
        return Date().timeIntervalSince(act.at) < Self.lingers
    }

    private init() {
        // Coming back to yab, or to one of its windows, is coming to the
        // tab in front of you there.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            looking.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AgentFeed.shared.lookAround() }
            })
        }
        PageView.person = { view in
            MainActor.assumeIsolated {
                let feed = AgentFeed.shared
                guard let tab = feed.browser?.tabs.first(where: { $0.builtPage === view }) else { return }
                feed.touched[tab.id] = Date()
                if !feed.handedOver.contains(tab.id) { feed.drive(tab) }
            }
        }
    }

    /// A click or a key of yours in an agent's tab while it works there,
    /// not while it is waiting on you, when that's exactly what it asked for.
    func drive(_ tab: Tab) {
        guard tab.worker != nil, tab.handoff == nil, !driving.contains(tab.id),
              let session = Agents.shared.session(tab.worker), session.state.live, !session.script,
              session.state != .attached || atWorkHere(tab)
        else { return }
        driving.insert(tab.id)
        update()
    }

    /// The person's own page input pauses the agent until they hand it back.
    func person(_ view: NSView) {
        guard let tab = browser?.tabs.first(where: { $0.builtPage === view }) else { return }
        touched[tab.id] = Date()
        if !handedOver.contains(tab.id) { drive(tab) }
    }

    /// The agent clicked at `point` (the page view's points, from its top
    /// left) in the tab showing `web`.
    func pointed(_ web: NSView, at point: CGPoint) {
        guard let tab = browser?.tabs.first(where: { $0.builtPage === web }) else { return }
        count += 1
        pointer[tab.id] = AgentPoint(at: point, count: count)
    }

    func handBack(_ tab: Tab) {
        guard driving.remove(tab.id) != nil else { return }
        update()
    }

    /// You answered what it asked in the tab: Done, Skip, a pick.
    func answered(_ tab: Tab) {
        handedOver.insert(tab.id)
        handBack(tab)
    }

    private func update() {
        // A task that has ended has nothing to hand back.
        for id in driving {
            guard let tab = browser?.tabs.first(where: { $0.id == id }),
                  let session = Agents.shared.session(tab.worker), session.state.live
            else { driving.remove(id); continue }
        }
        let here = browser?.active.flatMap { driving.contains($0.id) ? $0.id : nil }
        if here != drivingHere { drivingHere = here }
    }

    func stopped(_ tab: Tab, by session: String) {
        handBack(tab)
        pointer[tab.id] = nil
        last[tab.id] = nil
        stopped[tab.id] = session
    }

    func did(_ tab: Tab, _ pose: FacePose) {
        stopped[tab.id] = nil
        count += 1
        last[tab.id] = Act(pose: pose, at: Date(), count: count)
        // At work here again: the face again, and whatever it left before
        // is the work it is doing now.
        if tab.settled != nil { tab.settled = nil }
        if tab.unread != nil {
            reading.removeValue(forKey: tab.id)?.cancel()
            tab.unread = nil
            Folders.shared.refresh()
        }
        // Back at work in it: a look isn't, a click or keys are.
        if pose != .read { handedOver.remove(tab.id) }
        AgentTabCleanup.shared.acted(tab)
    }

    // MARK: - done, and not looked at yet

    /// A finished task's mark on a tab you haven't come to since: which
    /// task, and whether it couldn't finish.
    struct Unread: Equatable {
        let session: String
        var failed = false
    }

    /// How long the tick stays once the tab is in front of you, for the eye
    /// to see it go; and done right in front of you, for the smile.
    nonisolated static let beat: TimeInterval = 0.4
    nonisolated static let smile: TimeInterval = 1.5

    /// Tabs in front of you with something unread, read when the beat is up
    /// or when they leave the front, whichever comes first.
    @ObservationIgnored private var reading: [Tab.ID: DispatchWorkItem] = [:]

    /// A task is over: what it worked in and leaves behind is unread, but
    /// for what is in front of you, which only smiles. Stopped by you, the
    /// faces just go. Yab's own work out of sight, a routine's run and a
    /// script's tabs have nothing to come back to, nor has an agent that
    /// came on its own: it answered where it came from, and its client
    /// going away isn't a result to read.
    func ended(_ session: Agents.Session, _ state: Agents.State) {
        let agents = Agents.shared
        guard session.parent == nil, !session.script, !session.quiet, !session.sealed, session.routine == nil else { return }
        let left = everyTab().filter { tab in
            guard let owner = tab.worker ?? tab.answering, owner != Agents.script else { return false }
            return agents.root(of: owner) == session.id
        }
        guard !left.isEmpty else { return }
        for tab in left {
            tab.settled = tab.worker
            reading.removeValue(forKey: tab.id)?.cancel()
            // Behind Agents in One Row nobody opens them to read the tick,
            // and an unread tab is never cleaned up: ten done Telegram
            // checks stayed for good. Their panel says how long ago instead.
            // Nor does anybody for a run with nobody there (`yab --no-person`).
            let unseen = session.agent == .external || session.unattended || AgentRow.holds(tab)
            tab.unread = unseen ? nil : AgentFeed.ended(state).map { Unread(session: session.id, failed: $0) }
        }
        Folders.shared.refresh()
        for tab in left where tab.unread != nil && inFront(tab) { read(tab, after: Self.smile) }
    }

    /// What a task ending this way leaves on its tabs: nil for nothing,
    /// else whether it failed.
    nonisolated static func ended(_ state: Agents.State) -> Bool? {
        switch state {
        case .done: return false
        case .failed: return true
        default: return nil
        }
    }

    /// Every tab in front of you that has something unread is read, a beat
    /// later; one waiting for its beat that has left the front, at once.
    func lookAround() {
        AgentTabCleanup.shared.lookAround()
        readChats()
        guard !reading.isEmpty || everyTab().contains(where: { $0.unread != nil }) else { return }
        for tab in everyTab() where tab.unread != nil {
            if inFront(tab) {
                if reading[tab.id] == nil { read(tab, after: Self.beat) }
            } else if reading[tab.id] != nil {
                read(tab)
            }
        }
    }

    /// A chat's answer that came while you were elsewhere (ChatBusy): read
    /// as a task's end is, its dot staying the same beat for the eye.
    private func readChats() {
        for tab in everyTab() where tab.chatDone != nil && inFront(tab) && chatReading[tab.id] == nil {
            let work = DispatchWorkItem { [weak self, weak tab] in
                guard let tab else { return }
                self?.chatReading[tab.id] = nil
                tab.chatDone = nil
            }
            chatReading[tab.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.beat, execute: work)
        }
    }

    @ObservationIgnored private var chatReading: [Tab.ID: DispatchWorkItem] = [:]

    /// Looked at: the tick goes, and the folder's with the last of its task's.
    func read(_ tab: Tab, after delay: TimeInterval) {
        reading[tab.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            read(tab)
        }
        reading[tab.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func read(_ tab: Tab) {
        reading.removeValue(forKey: tab.id)?.cancel()
        guard let unread = tab.unread else { return }
        tab.unread = nil
        settle(unread.session)
    }

    /// Every tab of a folder, at once (Mark as Read).
    func read(_ tabs: [Tab]) {
        var sessions: Set<String> = []
        for tab in tabs {
            reading.removeValue(forKey: tab.id)?.cancel()
            guard let unread = tab.unread else { continue }
            tab.unread = nil
            sessions.insert(unread.session)
        }
        sessions.forEach(settle)
    }

    /// The last of a task's tabs looked at: it has nothing more to say, in
    /// Now or by its chat. Its tabs get the chosen cleanup interval from
    /// this last look (Agents.putAway).
    private func settle(_ id: String) {
        Folders.shared.refresh()
        guard !everyTab().contains(where: { $0.unread?.session == id }),
              let session = Agents.shared.session(id) else { return }
        session.looked = Date()
        if !session.read { session.read = true; Hints.shared.compose() }
        if !session.state.live { Agents.shared.putAway(session) }
    }

    /// In front of you: the tab on screen in its window (or a half of the
    /// pair there), that window the one you're in, and yab in front.
    func inFront(_ tab: Tab) -> Bool {
        guard let owner = BrowserWindows.shared.owner(of: tab.id), owner.browser.onScreen(tab.id) else { return false }
        if let here = Self.pretend { return here }
        let window = owner.window
        return NSApplication.shared.isActive && window.isVisible && window.occlusionState.contains(.visible)
            && (window.isKeyWindow || window.isMainWindow)
    }

    /// A test run's say over whether yab is in front of you: a probe on a
    /// test Mac is never the app in use (`bench ui task here|away|real`).
    static var pretend: Bool? {
        didSet { shared.lookAround() }
    }

    private func everyTab() -> [Tab] {
        let browsers = BrowserWindows.shared.browsers
        return (browsers.isEmpty ? [browser].compactMap { $0 } : browsers).flatMap(\.tabs)
    }

    /// The step a bench verb is, as a face shows it.
    static func pose(for action: String) -> FacePose {
        switch action {
        case "fill", "type", "select", "choose", "press": return .type
        case "scroll", "read", "snapshot": return .read
        case "nav", "open", "back", "forward", "reload": return .load
        default: return .click
        }
    }
}

extension Tab {
    /// The tab's end shows an agent's face: while one works here or waits
    /// on you, and after, until you have come to see what it left.
    var wearsFace: Bool {
        unread != nil || (worker != nil && (handoff != nil || worker != settled))
    }
}

/// The face at the end of an agent's tab.
struct AgentFace: View {
    var tab: Tab
    var size: CGFloat = 15
    /// The row's own ink, muted on a tab you aren't on, as its title is.
    var tint: Color = Palette.ink
    /// Its name and step in a tooltip. Not on a tab's end, where resting on
    /// the face brings the agent's card, which says more, sooner.
    var tip = true
    /// Worn by a task's folder (AgentFolders): the same eyes in a folder,
    /// its front let down when the folder is open.
    var folder = false
    var unfolded = false
    /// At rest, one picture (StillFace): in a row drawn into one picture
    /// itself, the strip's next space coming up.
    var still = false
    var weight: CGFloat? = nil
    private var agents = Agents.shared
    private var feed = AgentFeed.shared

    /// Bumped when a step the face shows has run its time, so the face is
    /// worked out again then, rather than polled.
    @State private var clock = 0

    var body: some View {
        let _ = clock
        let pose = pose(at: Date())
        let act = feed.last[tab.id]
        let script = agents.session(tab.worker)?.script == true
        Group {
            if still {
                StillFace(pose: pose, size: size, tint: tint, folder: folder, unfolded: unfolded, script: script, weight: weight)
            } else {
                Face(pose: pose, size: size, tint: tint, folder: folder, unfolded: unfolded, script: script, weight: weight)
            }
        }
            .keyTip(tip ? help : "")
            // A step shows for 2.2 seconds; then whatever comes after it.
            .task(id: act?.count) {
                guard let act else { return }
                let left = 2.2 - Date().timeIntervalSince(act.at)
                guard left > 0 else { return }
                try? await Task.sleep(for: .seconds(left + 0.05))
                if !Task.isCancelled { clock += 1 }
            }
    }

    private var help: String {
        guard let session = agents.session(tab.worker) else { return "" }
        if session.script { return session.name }
        if let ask = tab.handoff { return "\(session.name) needs you · \(ask)" }
        if feed.driving.contains(tab.id), session.state.live { return "You're driving, \(session.name) waits until you hand it back" }
        return session.now.isEmpty ? session.name : "\(session.name) · \(AgentDock.say(session.now, name: session.name))"
    }

    private func pose(at now: Date) -> FacePose {
        if tab.handoff != nil { return .hand }
        let session = agents.session(tab.worker)
        // Over, and what it left here not seen yet: the tick, or looking
        // down where it couldn't finish; seen, only the quiet face, where
        // a face is drawn at all (a tab's end has none then).
        guard let session, session.state.live else {
            guard let unread = tab.unread else { return .seen }
            return unread.failed ? .stuck : .done
        }
        if feed.driving.contains(tab.id) { return .drive }
        if tab.loading { return .load }
        if let act = feed.last[tab.id], now.timeIntervalSince(act.at) < 2.2 { return act.pose }
        guard session.busy else { return .watch }
        // Busy, but not here just now: thinking if this was the last tab it
        // touched, otherwise keeping an eye on it.
        let mine = (agents.browser?.tabs.filter { $0.worker == session.id } ?? []).compactMap { feed.last[$0.id] }.max { $0.count < $1.count }
        return mine == feed.last[tab.id] ? .think : .watch
    }
}

/// Two eyes, looking where the gaze says (−1 … 1 each way) and as open as
/// `open` says, and at `tick` 1 the two strokes of a tick instead: the left
/// eye the short stroke, the right the long one, their lower ends the corner.
/// On the 24-point grid, drawn at whatever size it is given.
struct Eyes: Shape {
    var gaze: CGPoint
    var open: CGFloat
    var tick: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(gaze.x, gaze.y), AnimatablePair(open, tick)) }
        set {
            gaze = CGPoint(x: newValue.first.first, y: newValue.first.second)
            open = newValue.second.first
            tick = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        let half = 1.25 * max(0.08, open)
        let dx = gaze.x * 2.3, dy = gaze.y * 2
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (a.x + (b.x - a.x) * tick) * k, y: rect.minY + (a.y + (b.y - a.y) * tick) * k)
        }
        // Eyes at 9.5 and 14.5, their middles at 11; the tick's corner at
        // (10.7, 15.5), its short end at (7.5, 12.3), its long end at (16.8, 9).
        let left = (top: CGPoint(x: 9.5 + dx, y: 11 + dy - half), foot: CGPoint(x: 9.5 + dx, y: 11 + dy + half))
        let right = (top: CGPoint(x: 14.5 + dx, y: 11 + dy - half), foot: CGPoint(x: 14.5 + dx, y: 11 + dy + half))
        var path = Path()
        path.move(to: mix(left.top, CGPoint(x: 7.5, y: 12.3)))
        path.addLine(to: mix(left.foot, CGPoint(x: 10.7, y: 15.5)))
        path.move(to: mix(right.foot, CGPoint(x: 10.7, y: 15.5)))
        path.addLine(to: mix(right.top, CGPoint(x: 16.8, y: 9)))
        return path
    }
}

// MARK: - the folder

/// A task's folder on the 24-point grid: as tall as the face's circle, a
/// tab at its top left, and a front that turns down on a hinge along its
/// foot when the folder opens (`t` 0 shut, 1 open). Opening, the folder
/// turns as a thing does, not as a drawing: it swings a little to one side
/// about its upright middle, seen with some perspective, and leans, so the
/// front stays square to the back and the whole reads as turned to you.
enum FolderGrid {
    /// The hand's size on a task folder's front, which carries it: small
    /// enough that its fingers stay clear of the seam, shut and let down.
    static let handScale: CGFloat = 0.42
    /// Where the eyes sit on the front, halfway between the seam and the
    /// foot inside their lines, and the foot the front turns on.
    static let eyes: CGFloat = 14.6
    static let foot: CGFloat = 20.5
    /// How far it turns, open: sideways, the front down on its hinge, and
    /// the lean, in degrees; and the eye's distance, in grid units, that
    /// sets the perspective. Tuned by eye in the folder-states concept.
    static let yaw: CGFloat = 23
    static let flap: CGFloat = 47
    static let roll: CGFloat = -8
    static let camera: CGFloat = 116
    /// Corners: the body's at its top, and the foot's, a touch rounder,
    /// which the back and the front share so the back never shows past the
    /// front there; the front's top ones round once it is let down.
    static let corner: CGFloat = 2
    static let frontFoot: CGFloat = 2.8
    static let frontTop: CGFloat = 1.6
    /// Where the front's top edge runs, below the body's: shut, a band of
    /// the back shows above it, deeper, as Arc's folders have, and the
    /// edge is a seam across; open, the back stands that much above it.
    static let lip: CGFloat = 9
    /// The seam, thinner than the outline so it reads as an edge on the
    /// body rather than a second one; it takes the outline's width as the
    /// front is let down and its edge becomes the outline's.
    static let seam: CGFloat = 1.5

    /// A point of the drawing, on the back or on the front, where it is
    /// seen with the folder as far turned and its front as far let down as
    /// `pose` says.
    static func project(_ point: CGPoint, front: Bool, pose: FolderPose) -> CGPoint {
        let radian = CGFloat.pi / 180
        let theta = flap * pose.flap * radian, phi = yaw * pose.turn * radian, rho = roll * pose.turn * radian
        var y = point.y, z: CGFloat = 0
        if front {
            let d = foot - y
            y = foot - d * cos(theta)
            z = d * sin(theta)
        }
        let x2 = 12 + (point.x - 12) * cos(phi) + z * sin(phi)
        let z2 = -(point.x - 12) * sin(phi) + z * cos(phi)
        let scale = camera / (camera - z2)
        let dx = (x2 - 12) * scale, dy = 13 + (y - 13) * scale - foot
        return CGPoint(x: 12 + dx * cos(rho) - dy * sin(rho), y: foot + dx * sin(rho) + dy * cos(rho))
    }

    /// A quarter round, walked in small steps (angles in degrees, the grid
    /// being top down).
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
        guard r > 0.01 else { return [CGPoint(x: cx, y: cy)] }
        return (0...8).map { i in
            let a = (a0 + (a1 - a0) * CGFloat(i) / 8) * .pi / 180
            return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        }
    }

    /// The back, its tab and all four sides, closed.
    static let back: [CGPoint] = {
        let r = corner
        var points = [CGPoint(x: 3, y: 20.5 - frontFoot), CGPoint(x: 3, y: 4.5 + r)]
        points += arc(3 + r, 4.5 + r, r, from: 180, to: 270)
        points += [CGPoint(x: 9.3, y: 4.5), CGPoint(x: 11.2, y: 6.5)]
        points += arc(21 - r, 6.5 + r, r, from: 270, to: 360)
        points += arc(21 - frontFoot, 20.5 - frontFoot, frontFoot, from: 0, to: 90)
        points += arc(3 + frontFoot, 20.5 - frontFoot, frontFoot, from: 90, to: 180)
        return points
    }()

    /// The front, all the way round from its top left corner: the first
    /// `edge` points are its top edge, the seam.
    static let front: [CGPoint] = {
        let t = frontTop, r = frontFoot
        var points = arc(3 + t, lip + t, t, from: 180, to: 270)
        points += arc(21 - t, lip + t, t, from: 270, to: 360)
        points += arc(21 - r, 20.5 - r, r, from: 0, to: 90)
        points += arc(3 + r, 20.5 - r, r, from: 90, to: 180)
        return points
    }()
    static let edge = 18
}

/// How far a folder is on its way open: how far it has turned, and how far
/// its front is let down, each 0 shut to 1 open. The two go one after the
/// other (FaceView.unfold), so the front is only ever let down from a folder
/// already turned, and shuts before the folder turns back.
struct FolderPose: Equatable {
    var flap: CGFloat
    var turn: CGFloat

    static let shut = FolderPose(flap: 0, turn: 0)
    static let open = FolderPose(flap: 1, turn: 1)
}

/// The back and the front in one path, as seen in `pose`: the back only
/// where the front isn't over it, so one stroke draws both with no fill and
/// no mask behind it.
struct FolderOpen: Shape {
    var pose: FolderPose

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        func place(_ q: CGPoint) -> CGPoint { CGPoint(x: rect.minX + q.x * k, y: rect.minY + q.y * k) }
        let face = FolderGrid.front.map { FolderGrid.project($0, front: true, pose: pose) }
        let back = FolderGrid.back.map { FolderGrid.project($0, front: false, pose: pose) }
        var path = Path()
        for run in FolderOpen.outside(back, of: face) where run.count > 1 {
            path.move(to: place(run[0]))
            for q in run.dropFirst() { path.addLine(to: place(q)) }
        }
        // The front's sides and foot; its top edge is the seam's.
        let sides = face[(FolderGrid.edge - 1)...] + [face[0]]
        path.move(to: place(sides.first!))
        for q in sides.dropFirst() { path.addLine(to: place(q)) }
        return path
    }

    /// The front's top edge as seen in `pose`.
    static func seam(pose: FolderPose, in rect: CGRect) -> Path {
        let k = rect.width / 24
        let edge = FolderGrid.front.prefix(FolderGrid.edge).map { FolderGrid.project($0, front: true, pose: pose) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + edge[0].x * k, y: rect.minY + edge[0].y * k))
        for q in edge.dropFirst() { path.addLine(to: CGPoint(x: rect.minX + q.x * k, y: rect.minY + q.y * k)) }
        return path
    }

    /// The two fills under the outline as seen in `pose`: the back whole,
    /// and the front, drawn over it.
    static func fills(pose: FolderPose, in rect: CGRect) -> (back: Path, front: Path) {
        let k = rect.width / 24
        func place(_ q: CGPoint) -> CGPoint { CGPoint(x: rect.minX + q.x * k, y: rect.minY + q.y * k) }
        func shape(_ points: [CGPoint]) -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: place(first))
            for q in points.dropFirst() { path.addLine(to: place(q)) }
            path.closeSubpath()
            return path
        }
        let back = FolderGrid.back.map { FolderGrid.project($0, front: false, pose: pose) }
        let front = FolderGrid.front.map { FolderGrid.project($0, front: true, pose: pose) }
        return (shape(back), shape(front))
    }

    /// The runs of `line` outside the convex outline `shape`, walked in
    /// small steps, each end found by halving where it crosses. A point on
    /// the edge counts as inside, so where back and front meet, the front
    /// alone draws it.
    static func outside(_ line: [CGPoint], of shape: [CGPoint]) -> [[CGPoint]] {
        guard shape.count > 2 else { return [line] }
        var area: CGFloat = 0
        for i in shape.indices {
            let a = shape[i], b = shape[(i + 1) % shape.count]
            area += a.x * b.y - b.x * a.y
        }
        let turn: CGFloat = area >= 0 ? 1 : -1
        func out(_ q: CGPoint) -> Bool {
            for i in shape.indices {
                let a = shape[i], b = shape[(i + 1) % shape.count]
                let length = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
                if turn * ((b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)) / length < -0.12 { return true }
            }
            return false
        }
        func mix(_ a: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u) }
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        guard let first = line.first else { return [] }
        var was = out(first)
        if was { run.append(first) }
        for (a, b) in zip(line, line.dropFirst()) {
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 0.25).rounded(.up)))
            for i in 1...steps {
                let p = mix(a, b, CGFloat(i - 1) / CGFloat(steps)), q = mix(a, b, CGFloat(i) / CGFloat(steps))
                let now = out(q)
                if now != was {
                    var low: CGFloat = 0, high: CGFloat = 1
                    for _ in 0..<10 {
                        let mid = (low + high) / 2
                        if out(mix(p, q, mid)) == was { low = mid } else { high = mid }
                    }
                    let edge = mix(p, q, (low + high) / 2)
                    if was { run.append(edge); runs.append(run); run = [] } else { run = [edge] }
                    was = now
                }
                if now { run.append(q) }
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}

// MARK: - circle to hand

/// The face's circle at 0 and the raised hand at 1, point for point, in
/// the 24-point grid the glyphs are drawn on; at `robot` 1 the circle is a
/// script's head instead, squared.
struct FaceOutline: Shape {
    var t: CGFloat
    var robot: CGFloat = 0
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = FaceOutline.circle, r = FaceOutline.head, b = FaceOutline.hand
        let k = rect.width / 24
        var path = Path()
        for i in 0..<c.count {
            let a = CGPoint(x: c[i].x + (r[i].x - c[i].x) * robot, y: c[i].y + (r[i].y - c[i].y) * robot)
            let p = CGPoint(x: rect.minX + (a.x + (b[i].x - a.x) * t) * k, y: rect.minY + (a.y + (b[i].y - a.y) * t) * k)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    static let count = 240

    /// Starting at the top and going the way the hand's outline does,
    /// leftward, so each point of the circle finds the finger above it.
    static let circle: [CGPoint] = (0..<count).map { i in
        let angle = -Double.pi / 2 - Double(i) / Double(count) * 2 * .pi
        return CGPoint(x: 12 + 9 * cos(angle), y: 12 + 9 * sin(angle))
    }

    /// A robot's head: as wide as the circle, lower, its corners rounded,
    /// room above it for the antenna. Walked from the top the circle's way.
    static let top: CGFloat = 5.5
    static let head: [CGPoint] = {
        let r: CGFloat = 4.5, l: CGFloat = 3, rt: CGFloat = 21, t = top, b: CGFloat = 21
        var points: [CGPoint] = [CGPoint(x: 12, y: t)]
        func arc(_ cx: CGFloat, _ cy: CGFloat, from: Double, to: Double) {
            for step in 0...12 {
                let a = from + (to - from) * Double(step) / 12
                points.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
        }
        arc(l + r, t + r, from: -.pi / 2, to: -.pi)
        arc(l + r, b - r, from: .pi, to: .pi / 2)
        arc(rt - r, b - r, from: .pi / 2, to: 0)
        arc(rt - r, t + r, from: 0, to: -.pi / 2)
        return resample(points, count)
    }()

    /// Glyphs' "hand.raised.fill", walked at even steps along its edge.
    static let hand: [CGPoint] = resample(SVGPath.points(handPath), count)

    private static let handPath = "M12.0673 2C11.4414 2 10.934 2.50447 10.934 3.12676V9.88732C10.934 10.1985 10.6803 10.4507 10.3674 10.4507C10.0545 10.4507 9.80077 10.1985 9.80077 9.88732V4.25352C9.80077 3.63123 9.2934 3.12676 8.66753 3.12676C8.04165 3.12676 7.53428 3.63123 7.53428 4.25352V11.1464C7.53428 11.3763 7.39386 11.5831 7.17946 11.669C6.96506 11.7549 6.71966 11.7027 6.55938 11.5371L5.21282 10.1458C4.43664 9.34385 3.10627 9.49382 2.53035 10.4482L2.5 10.4985L5.29405 17.2834C6.46887 20.1363 9.26174 22 12.3623 22C16.5805 22 20 18.6 20 14.406V6.50704C20 5.88475 19.4926 5.38028 18.8668 5.38028C18.2409 5.38028 17.7335 5.88475 17.7335 6.50704V11.0141C17.7335 11.3252 17.4798 11.5775 17.1669 11.5775C16.8539 11.5775 16.6003 11.3252 16.6003 11.0141V4.25352C16.6003 3.63123 16.0929 3.12676 15.467 3.12676C14.8411 3.12676 14.3338 3.63123 14.3338 4.25352V10.4507C14.3338 10.7619 14.0801 11.0141 13.7671 11.0141C13.4542 11.0141 13.2005 10.7619 13.2005 10.4507V3.12676C13.2005 2.50447 12.6931 2 12.0673 2Z"

    /// `count` points at equal distances along a closed outline.
    static func resample(_ points: [CGPoint], _ count: Int) -> [CGPoint] {
        guard points.count > 1 else { return Array(repeating: .zero, count: count) }
        let ring = points + [points[0]]
        var lengths: [CGFloat] = [0]
        for i in 1..<ring.count { lengths.append(lengths[i - 1] + hypot(ring[i].x - ring[i - 1].x, ring[i].y - ring[i - 1].y)) }
        let total = lengths.last!
        var out: [CGPoint] = []
        var j = 1
        for i in 0..<count {
            let at = total * CGFloat(i) / CGFloat(count)
            while j < lengths.count - 1, lengths[j] < at { j += 1 }
            let span = max(lengths[j] - lengths[j - 1], .ulpOfOne)
            let k = (at - lengths[j - 1]) / span
            out.append(CGPoint(x: ring[j - 1].x + (ring[j].x - ring[j - 1].x) * k, y: ring[j - 1].y + (ring[j].y - ring[j - 1].y) * k))
        }
        return out
    }
}

/// Just enough of SVG's path grammar for yab's own glyphs: absolute M, L,
/// H, V, C and Z, curves walked in small steps.
enum SVGPath {
    static func points(_ d: String) -> [CGPoint] {
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in d {
            if ch.isLetter { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-", !number.isEmpty, number.last != "e" { flush(); number.append(ch) }
            else if ch == ".", number.contains(".") { flush(); number = "0." }
            else { number.append(ch) }
        }
        flush()
        var out: [CGPoint] = []
        var at = CGPoint.zero
        var i = 0
        var command = "M"
        func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { command = tokens[i]; i += 1; if command == "Z" { continue } }
            switch command {
            case "M", "L": at = CGPoint(x: next(), y: next()); out.append(at)
            case "H": at.x = next(); out.append(at)
            case "V": at.y = next(); out.append(at)
            case "C":
                let c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next()), end = CGPoint(x: next(), y: next())
                for step in 1...12 {
                    let t = CGFloat(step) / 12, u = 1 - t
                    out.append(CGPoint(
                        x: u * u * u * at.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                        y: u * u * u * at.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y))
                }
                at = end
            default: i += 1
            }
        }
        return out
    }
}
