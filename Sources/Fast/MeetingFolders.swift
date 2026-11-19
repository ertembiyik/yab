import SwiftUI

// Settings › Tabs › "Group tabs for meetings", as Dia's "Automatically group
// tabs for meetings" (docs/link-folders.md). Read from Dia 1.53's code, not
// filmed: no Dia on the farm is signed in to a calendar. Dia makes a
// meeting's group when the meeting is joined from its calendar, names it
// for the event and counts the time left in its header. Yab: Join (the
// reminder, the pinned calendar, ⌃⌘J) puts the call's tab in a folder of
// today's named for the meeting, which stays with only the call in it
// until the meeting ends and says the minutes left on its row; what you
// ⌘-click from the call goes in too (Research.gatherSearch).

extension Browser {
    func meetingFolder(_ tab: Tab, for meeting: Meeting) {
        guard tab.pin == nil, !tab.kept, !tab.bench, tab.nest == nil else { return }
        let nest = nests.first { $0.meeting == meeting.id } ?? {
            let made = Nest(name: meeting.title.isEmpty ? "Meeting" : meeting.title)
            made.fleeting = true
            made.meeting = meeting.id
            made.meetingEnd = meeting.end
            made.born = Date()
            return made
        }()
        ColumnMotion.next(.folder)
        tab.nest = nest
        folderBook.refresh()
        writeSession()
    }
}

/// A meeting's folder's row while it is on: "12m left", as the header of
/// Dia's meeting group counts it.
struct MeetingLeftWords: View {
    var nest: Nest
    @Environment(\.tone) private var tone

    var body: some View {
        if let end = nest.meetingEnd, end > Date() {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let words = MeetingLeftWords.words(until: end, now: context.date) {
                    Text(words)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint(on: tone))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    nonisolated static func words(until end: Date, now: Date) -> String? {
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}
