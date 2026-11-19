import AppKit
import Combine
import Testing
@testable import Fast

// Candidate-only APIs. Keep separate from the baseline-compatible
// ActionMenuVariantFPresentationTests; a filter cannot hide compile errors.
@MainActor @Suite(.serialized)
struct ActionMenuVariantFHoverTests {
    @Test func continuousHoverOverSameSubmenuDoesNotRepublishUnchangedSelection() {
        let (list, _) = listWithTwoSubmenus()
        defer { list.closeChild() }
        list.point(1, at: CGPoint(x: 100, y: 50))
        let originalChild = list.child
        var updates = 0
        let observation = ObservedWrites({ _ = (list.child, list.highlighted, list.lines.count, list.option, list.searching) }, told: { updates += 1 })
        for x in 101...200 { list.point(1, at: CGPoint(x: x, y: 50)) }
        withExtendedLifetime(observation) {
            #expect(updates == 0)
            #expect(list.child === originalChild)
            #expect(list.highlighted == 1)
        }
    }

    @Test func repeatedPointerLeaveDoesNotRepublishClearedSelection() {
        let (list, _) = listWithTwoSubmenus()
        list.point(2)
        list.leave()
        var updates = 0
        let observation = ObservedWrites({ _ = (list.child, list.highlighted, list.lines.count, list.option, list.searching) }, told: { updates += 1 })
        for _ in 0..<100 { list.leave() }
        withExtendedLifetime(observation) { #expect(updates == 0) }
    }

    private func listWithTwoSubmenus() -> (ActionMenuList, VariantFMenuTarget) {
        let target = VariantFMenuTarget()
        let other = VariantFMenuFixture.menu([VariantFMenuFixture.item("Other Destination", target: target)])
        let spaces = VariantFMenuFixture.menu([VariantFMenuFixture.item("Work", target: target)])
        let menu = VariantFMenuFixture.menu([
            VariantFMenuFixture.submenu("Other Group", other),
            VariantFMenuFixture.submenu("Move to Space", spaces),
            VariantFMenuFixture.item("Copy Link", target: target),
        ])
        return (ActionMenuList(menu: menu, falls: true), target)
    }

    private func queueDiagonalSwitch(_ list: ActionMenuList, left: Bool = false) {
        let origin = CGPoint(x: left ? 300 : 100, y: 50)
        let crossing = CGPoint(x: left ? 260 : 140, y: 70)
        list.point(1, at: origin)
        list.childFrame = CGRect(x: left ? 0 : 200, y: 0, width: 140, height: 180)
        list.point(0, at: crossing)
    }

    @Test func leavingHoveredRowClearsItsHighlightWithoutChoosingAnotherAction() {
        let target = VariantFMenuTarget()
        let list = ActionMenuList(menu: VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Pin", target: target),
            VariantFMenuFixture.item("Copy Link", target: target),
        ]), falls: true)
        #expect(list.highlighted == nil)
        list.point(0)
        #expect(list.highlighted == 0)
        list.leave(0)
        #expect(list.hovered == nil)
        #expect(list.highlighted == nil)
        #expect(list.spot == -1)
        list.take()
        #expect(target.received.isEmpty)
    }

    @Test func oldPointerExitDoesNotEraseTheNewKeyboardSelection() {
        let target = VariantFMenuTarget()
        let list = ActionMenuList(menu: VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Pin", target: target),
            VariantFMenuFixture.item("Copy Link", target: target, id: "copy"),
        ]), falls: true)
        list.point(0)
        list.move(1)
        // SwiftUI can deliver the old row's hover-ended after key movement.
        list.leave(0)
        #expect(list.hovered == nil)
        #expect(list.highlighted == 1)
        #expect(list.spot == 1)
        list.take()
        #expect(target.received == ["copy"])
    }

    @Test func lateExitFromPreviousRowDoesNotClearTheCurrentPointerHighlight() {
        let target = VariantFMenuTarget()
        let list = ActionMenuList(menu: VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Pin", target: target),
            VariantFMenuFixture.item("Copy Link", target: target),
        ]), falls: true)
        list.point(0)
        list.point(1)
        list.leave(0)
        #expect(list.hovered == 1)
        #expect(list.highlighted == 1)
    }

    @Test(arguments: [false, true])
    func crossingTowardOpenSubmenuGetsBoundedGraceThenSwitches(left: Bool) async throws {
        let (list, target) = listWithTwoSubmenus()
        defer { list.closeChild() }
        queueDiagonalSwitch(list, left: left)
        #expect(list.hovered == 0)
        #expect(list.childLine == 1)
        #expect(list.child?.lines.map(\.title) == ["Work"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(list.childLine == 0)
        #expect(list.child?.lines.map(\.title) == ["Other Destination"])
        #expect(target.received.isEmpty)
    }

    @Test(arguments: [false, true])
    func continuousDiagonalMotionCannotExtendGraceBeyondItsOriginalDeadline(left: Bool) async throws {
        let (list, target) = listWithTwoSubmenus()
        defer { list.closeChild() }
        queueDiagonalSwitch(list, left: left)
        #expect(list.childLine == 1)
        // Each event advances toward the child's near edge. Repeating an
        // identical point would leave the aim corridor and miss this bug.
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(80))
            let x = left ? 260 - CGFloat(step) : 140 + CGFloat(step)
            list.point(0, at: CGPoint(x: x, y: 70))
            if step >= 4 {
                // The original 250 ms deadline has passed, with more pointer
                // events still to come. It must not slide by another 250 ms.
                #expect(list.childLine == 0)
                #expect(list.child?.lines.map(\.title) == ["Other Destination"])
            }
        }
        #expect(target.received.isEmpty)
    }

    @Test func cancelingPendingHoverKeepsOriginalChildAfterOldDeadline() async throws {
        let (list, target) = listWithTwoSubmenus()
        defer { list.closeChild() }
        queueDiagonalSwitch(list)
        #expect(list.childLine == 1)
        list.cancelPendingHover()
        try await Task.sleep(for: .milliseconds(400))
        #expect(list.childLine == 1)
        #expect(list.child?.lines.map(\.title) == ["Work"])
        #expect(target.received.isEmpty)
    }

    @Test func changingQueryCannotResurrectAChildFromStaleHoverWork() async throws {
        let (list, target) = listWithTwoSubmenus()
        defer { list.closeChild() }
        queueDiagonalSwitch(list)
        #expect(list.childLine == 1)
        // The queued old index 0 is still valid after filtering, but now
        // names Move to Space. Missing cancellation would reopen it later.
        list.query = "move"
        #expect(list.lines.map(\.title) == ["Move to Space"])
        #expect(list.child == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(list.child == nil)
        #expect(list.highlighted == 0)
        #expect(target.received.isEmpty)
    }

    @Test func enteringChildCancelsParentGraceAndLetsChildReceiveReturn() async throws {
        let (list, target) = listWithTwoSubmenus()
        defer { list.closeChild() }
        queueDiagonalSwitch(list)
        let child = try #require(list.child)
        child.point(0, at: CGPoint(x: 220, y: 80))
        try await Task.sleep(for: .milliseconds(400))
        #expect(list.child === child)
        #expect(list.childLine == 1)
        #expect(list.active === child)
        list.active.take()
        #expect(target.received == ["Work"])
    }

    @Test func childRowsKeepTheirOwnImagesWithoutInheritingParentsActionSymbol() throws {
        let target = VariantFMenuTarget()
        let parentImage = NSImage(size: CGSize(width: 16, height: 16))
        let childImage = NSImage(size: CGSize(width: 16, height: 16))
        let marked = VariantFMenuFixture.item("Project", target: target)
        marked.image = childImage
        let children = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: target), marked,
        ])
        let list = ActionMenuList(menu: VariantFMenuFixture.menu([
            VariantFMenuFixture.submenu("Move to Folder", children, image: parentImage),
        ]), falls: true)
        defer { list.closeChild() }
        list.take(0)
        let child = try #require(list.child)
        #expect(child.lines[0].image == nil)
        #expect(child.lines[1].image === childImage)
        #expect(child.lines.allSatisfy { $0.image !== parentImage })
        #expect(!child.searchVisible)
        child.move(1)
        child.take()
        #expect(target.received == ["Project"])
    }

    @Test(arguments: ["Copy Link", "Close"])
    func hoveredOptionAlternativeKeepsHighlightAndOriginalDispatchAcrossSleepInsertion(title: String) throws {
        let target = VariantFMenuTarget()
        let extras = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Copy Markdown Link", target: target, id: "copy-markdown"),
            VariantFMenuFixture.item("Close and Keep", target: target, id: "close-keep"),
            VariantFMenuFixture.item("Put Tab to Sleep", target: target, id: "sleep"),
        ])
        let menu = VariantFMenuFixture.tab([
            VariantFMenuFixture.item("Pin", target: target, id: "pin"),
            VariantFMenuFixture.item("Copy Link", target: target, id: "copy"),
            .separator(),
            VariantFMenuFixture.item("Close", target: target, id: "close"),
            VariantFMenuFixture.item("Close Other Tabs", target: target, id: "close-others"),
        ], extras: extras)
        let list = ActionMenuList(menu: menu, falls: true)
        let originalIndex = try #require(list.lines.firstIndex { $0.title == title })
        let originalCount = list.lines.count
        list.point(originalIndex)
        #expect(list.highlighted == list.spot)

        list.modifiers(.option)
        let alternate = title == "Close" ? "Close and Keep" : "Copy Markdown Link"
        let optionIndex = try #require(list.lines.firstIndex { $0.title == alternate })
        #expect(list.lines.count == originalCount + 1)
        #expect(list.lines.contains { $0.title == "Put Tab to Sleep" })
        #expect(list.spot == optionIndex)
        #expect(list.hovered == optionIndex)
        #expect(list.highlighted == list.spot)
        // Sleep takes Close's former index. A late exit from that old row
        // must not remove the rebased highlight from Close and Keep.
        if optionIndex != originalIndex { list.leave(originalIndex) }
        #expect(list.highlighted == optionIndex)
        list.take()
        #expect(target.received == [title == "Close" ? "close-keep" : "copy-markdown"])

        list.modifiers([])
        let restoredIndex = try #require(list.lines.firstIndex { $0.title == title })
        #expect(list.lines.count == originalCount)
        #expect(!list.lines.contains { $0.title == "Put Tab to Sleep" })
        #expect(list.spot == restoredIndex)
        #expect(list.hovered == restoredIndex)
        #expect(list.highlighted == list.spot)
        if optionIndex != restoredIndex { list.leave(optionIndex) }
        #expect(list.highlighted == restoredIndex)
        list.take()
        #expect(target.received == (title == "Close" ? ["close-keep", "close"] : ["copy-markdown", "copy"]))
    }

    @Test func releasingOptionWhileHoveringSleepClearsSelectionInsteadOfHighlightingClose() throws {
        let target = VariantFMenuTarget()
        let list = ActionMenuList(menu: VariantFMenuFixture.tab([
            VariantFMenuFixture.item("Pin", target: target, id: "pin"),
            VariantFMenuFixture.item("Copy Link", target: target, id: "copy"),
            VariantFMenuFixture.item("Close", target: target, id: "close"),
        ], extras: VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Put Tab to Sleep", target: target, id: "sleep"),
        ])), falls: true)
        list.modifiers(.option)
        let sleepIndex = try #require(list.lines.firstIndex { $0.title == "Put Tab to Sleep" })
        let closeIndex = try #require(list.lines.firstIndex { $0.title == "Close" })
        #expect(closeIndex == sleepIndex + 1)
        list.point(sleepIndex)
        #expect(list.spot == sleepIndex)
        #expect(list.hovered == sleepIndex)
        #expect(list.highlighted == sleepIndex)

        list.modifiers([])
        // Close now occupies Sleep's former index. A stale pointer index
        // would highlight it even though the selected action disappeared.
        try #require(list.lines.indices.contains(sleepIndex))
        #expect(list.lines[sleepIndex].title == "Close")
        #expect(list.spot == -1)
        #expect(list.hovered == nil)
        #expect(list.highlighted == nil)
        list.take()
        #expect(target.received.isEmpty)
    }

    @Test(arguments: [false, true])
    func optionKeepsSecondSameNamedCompactSearchDestination(pointer: Bool) throws {
        let spaceTarget = VariantFMenuTarget()
        let folderTarget = VariantFMenuTarget()
        let spaces = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: spaceTarget, id: "space-personal"),
        ])
        let folders = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: folderTarget, id: "folder-personal"),
        ])
        let destinations = VariantFMenuFixture.menu([
            VariantFMenuFixture.submenu("Space", spaces),
            VariantFMenuFixture.submenu("Folder", folders),
        ])
        let menu = VariantFMenuFixture.tab([
            VariantFMenuFixture.submenu("Move to", destinations),
        ], extras: VariantFMenuFixture.menu([]))
        let list = ActionMenuList(menu: menu, falls: true)
        list.query = "Personal"
        #expect(list.compact)
        #expect(list.lines.map(\.title) == ["Personal", "Personal"])
        #expect(list.spot == 0)
        if pointer { list.point(1) } else { list.move(1) }
        #expect(list.spot == 1)
        #expect(list.highlighted == 1)

        list.modifiers(.option)
        #expect(list.lines.count == 2)
        #expect(list.spot == 1)
        #expect(list.highlighted == list.spot)
        let selectedWithOption = try #require(list.lines.indices.contains(list.spot) ? list.lines[list.spot] : nil)
        #expect(selectedWithOption.menu === folders)
        list.take()
        #expect(folderTarget.received == ["folder-personal"])
        #expect(spaceTarget.received.isEmpty)

        // Releasing Option must preserve the same original source as well.
        list.modifiers([])
        #expect(list.lines.count == 2)
        #expect(list.spot == 1)
        #expect(list.highlighted == list.spot)
        let selectedWithoutOption = try #require(list.lines.indices.contains(list.spot) ? list.lines[list.spot] : nil)
        #expect(selectedWithoutOption.menu === folders)
        list.take()
        #expect(folderTarget.received == ["folder-personal", "folder-personal"])
        #expect(spaceTarget.received.isEmpty)
    }

    @Test func compactSearchDeduplicatesLegacyMoveAliasesWithoutCollapsingDistinctDestinations() {
        let spaceTarget = VariantFMenuTarget()
        let folderTarget = VariantFMenuTarget()
        let legacySpaceTarget = VariantFMenuTarget()
        let legacyFolderTarget = VariantFMenuTarget()
        let spaces = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: spaceTarget, id: "visible-space"),
        ])
        let folders = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: folderTarget, id: "visible-folder"),
        ])
        let legacySpaces = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: legacySpaceTarget, id: "legacy-space"),
        ])
        let legacyFolders = VariantFMenuFixture.menu([
            VariantFMenuFixture.item("Personal", target: legacyFolderTarget, id: "legacy-folder"),
        ])
        let destinations = VariantFMenuFixture.menu([
            VariantFMenuFixture.submenu("Space", spaces),
            VariantFMenuFixture.submenu("Folder", folders),
        ])
        let extras = VariantFMenuFixture.menu([
            VariantFMenuFixture.submenu("Move to Space", legacySpaces),
            VariantFMenuFixture.submenu("Move to Folder", legacyFolders),
        ])
        let list = ActionMenuList(menu: VariantFMenuFixture.tab([
            VariantFMenuFixture.submenu("Move to", destinations),
        ], extras: extras), falls: true)
        list.query = "Personal"
        #expect(list.lines.map(\.title) == ["Personal", "Personal"])
        #expect(list.lines.first?.menu === spaces)
        #expect(list.lines.last?.menu === folders)
        list.take()
        list.move(1)
        list.take()
        #expect(spaceTarget.received == ["visible-space"])
        #expect(folderTarget.received == ["visible-folder"])
        #expect(legacySpaceTarget.received.isEmpty)
        #expect(legacyFolderTarget.received.isEmpty)
    }

    @Test func iconPickerOwnsPendingTargetBeforeTheDeferredPopoverAppears() async throws {
        // A fresh owner avoids changing the singleton used by mounted rows.
        let picker = IconPicking()
        let destination = IconPicking.Target.tab(UUID())
        #expect(!picker.isHolding)
        picker.open(destination)
        // These checks happen in the same actor turn as Change Icon's menu
        // action. The target is deferred, but the sidebar must already hold.
        #expect(picker.target == nil)
        #expect(picker.pending == destination)
        #expect(picker.isHolding)
        for _ in 0..<30 {
            if picker.target == destination, picker.pending == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(picker.target == destination)
        #expect(picker.pending == nil)
        #expect(picker.isHolding)
        picker.target = nil
        #expect(!picker.isHolding)
    }

    @Test func rightOpeningAimAcceptsTriangleCrossingButRejectsAwayAndOutside() {
        let child = CGRect(x: 200, y: 20, width: 120, height: 160)
        let origin = CGPoint(x: 100, y: 80)
        #expect(ActionMenuAim.contains(origin: origin, point: CGPoint(x: 150, y: 120), submenu: child))
        #expect(ActionMenuAim.contains(origin: origin, point: CGPoint(x: 200, y: 20), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 90, y: 80), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 150, y: 210), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 250, y: 100), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: origin, submenu: child))
    }

    @Test func leftOpeningAimUsesTheNearRightEdgeAndRejectsMotionAway() {
        let child = CGRect(x: 0, y: 20, width: 80, height: 160)
        let origin = CGPoint(x: 180, y: 80)
        #expect(ActionMenuAim.contains(origin: origin, point: CGPoint(x: 130, y: 120), submenu: child))
        #expect(ActionMenuAim.contains(origin: origin, point: CGPoint(x: 80, y: 20), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 190, y: 80), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 130, y: 210), submenu: child))
        #expect(!ActionMenuAim.contains(origin: origin, point: CGPoint(x: 60, y: 100), submenu: child))
    }

    @Test func pointerAlreadyAtChildEdgeDoesNotCreateAFalseDiagonalCorridor() {
        let child = CGRect(x: 200, y: 20, width: 120, height: 160)
        #expect(!ActionMenuAim.contains(origin: CGPoint(x: 200, y: 80), point: CGPoint(x: 201, y: 90), submenu: child))
    }
}
