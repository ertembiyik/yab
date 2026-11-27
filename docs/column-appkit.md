# The column on AppKit and Core Animation

The column (the tabs down the side: pins, the space's name, kept tabs and
folders, the line, New tab, today's tabs, the foot) has been one SwiftUI
tree, `SideBar` in `Side.swift`, hosted in one `NSHostingView`
(`ColumnView`, `Peek.swift`). This page is the plan and the record of
moving its rows, and then each space's whole page, onto AppKit views and
Core Animation layers, the way Arc and Safari draw theirs.

## Why

Measured before this work (docs/evidence/space-switch-2026-10-10.md,
"Second cut" and "Handover"), on renderer-2 with 30 tabs a space:

- A change of space holds the main thread 65 to 95 ms. About 45 ms of it is
  SwiftUI laying out and drawing the kept pages of rows again: no row is
  made and only two row bodies run, but every kept row is still a node of
  the column's one graph, and the switch's writes (the space, its color,
  the tab in front) invalidate that graph. The pins, the space's name, the
  address plate and the foot are about 5 ms each; the band's picture 8 to
  17 ms (now taken ahead); the commit about 9 ms; the rest of the window
  about 20 ms.
- Keeping fewer pages makes it worse (one page 120 ms, two 130), so the
  cost is not the number of pages but their being in the column's graph.
- The row of spaces that slides is a picture of the column plus a SwiftUI
  host per neighboring space (`PagedSpace`): the picture has had to leave
  out the column's ground, its frost, its shadows and its head; each of
  those has been a bug (0.0.8's empty card, 0.0.13's held row, the
  overlap Ganidhu filmed on 0.0.19).

Target: a change of space (key, ⌃1 to ⌃9, the foot's dots, two fingers)
holds the main thread 16 to 25 ms and drops no more than one frame, at 30
and at 150 tabs a space; a 500-tab column scrolls at the display's rate
with no main-thread work but reusing cells; a tab's title, mark or loading
changing redraws its own row only.

## Design

As Arc and Safari do it: each space is a page of its own, kept alive, and
a change of space slides those pages; the rows in a page are reusable
cells, only as many as are in sight.

### Pieces

- **`ColumnKit`** (`ColumnKit.swift`): the switch, on by default since
  the evals below held; the setting `column.appkit` false or
  `YAB_COLUMN=swiftui` gives the SwiftUI column back for a release.
  Off, the column is exactly the SwiftUI one; on, `SideBar` leaves its
  rows' place empty and the AppKit pages stand in it. Read once, when a
  window's column is made.
- **`ColumnPages`** (`ColumnPages.swift`): an `NSView` laid where
  SideBar's rows were (an `NSViewRepresentable` in SideBar's own place for
  them, so SwiftUI keeps its order: the head, the pins and the name over
  it, as before), as tall as the column. It holds one `ColumnPage` per
  space visited lately, side by side, a column wide each, in one clip
  whose `sublayerTransform` is the row of spaces: the space on screen at
  0, the others hidden until a change of space shows them.
- **`ColumnPage`**: one space's rows in an `NSScrollView` of its own
  (its own scroll offset, kept when the space is left), the document a
  flipped view laid out by `ColumnLayout`, cells only for what is in
  sight. The ends' dimming and blur (`ColumnEnds`) are a gradient mask
  layer and the same `EdgeBlurView` the SwiftUI column uses; the thread
  (`ColumnThread`) is the scroller.
- **`ColumnLayout`** (`ColumnLayout.swift`): the rows as the column lays
  them, a flat list of items (a tab, two tabs side by side, a folder's row,
  an empty folder and its hint, a task folder's "N more", the line, New
  tab) with their y and depth. A pure function of the tabs, the folders
  (`Folders`, the same places, chains and heads SwiftUI's `baseSlots`
  read), the pairs, the tab in front and New tab's light. Unit-tested
  against the SwiftUI column's own arithmetic (`Folders.slots`).
- **`ColumnCell`** (`ColumnCells.swift`): a reusable cell. Its content is
  the row the SwiftUI column draws, the same view (`SideRow`, `PairRow`,
  `NestRow`, `FolderRow`, `FolderMore`, `KeptLine`, `EmptyNestHint`, New
  tab's `Quiet`) in a small `NSHostingView` of its own with no sizing of
  its own (`sizingOptions = []`, a fixed frame), so the column looks
  pixel for pixel as it did: every mark, the title's fade, the end's
  cross, faces, timers, the speaker, the dev port, a call's dot. Each
  cell is a graph of its own: a row's tab changing redraws that row
  alone, as the row already watches only its tab. A cell is rebound
  (`rootView` set) only when what it shows changes (`ColumnItem.Look`,
  the same fields as `TabCell.Look`); a scroll reuses cells that went out
  of sight for those coming in.
- **What a row says about where it is.** Inside SwiftUI the rows told the
  window where they stand in `.global`, the column's host's space, which
  is the window's. In a cell's own host `.global` is the cell. So in
  AppKit mode the rows don't say it (`ColumnKit.hosted` in the
  environment) and the page does, from its layout, on every layout and
  scroll: `Browser.keySky` (a page's question, a card coming out of a
  tab), `Browser.drawnRows` (Clear's dust), `Glance.folderFrames` (a
  folder's preview), `Browser.keptLine`, `rowsClip`.
- **The pager** (`SpacePager`): with ColumnKit on, a change of space no
  longer pictures the band or makes `PagedSpace` hosts: the pages are the
  live `ColumnPage`s themselves. Keys, menu, the tray and the dots slide
  the clip on the same spring (`SpacePaging`, stiffness 987, damping
  62.8); two fingers set its transform each move, half the fingers' way,
  Arc's give past the ends; the landing spring starts at the fingers'
  speed. `SpacePaging`'s rules, `SpacePager.grab(_:by:)` and `parting`
  (59d83e5d) are kept as they are: only what is moved changes.
- **The space's color** stays Core Animation's (`SpaceWash`,
  `CardGround`), turned on the row's spring as now. A page keeps its own
  space's tone (the colors its rows' ink is worked out from), as kept rows
  already do, so neither leaving a space nor coming back redraws a row.
- **Pins and the space's name** (step 4) move into the page too: the pins
  grid as cells laid by the same `pinGeometry` arithmetic, `PinSquare` in
  each; `SpaceName` in a cell over the rows. Pins every space shares stand
  still in a layer of their own over the sliding clip, as Arc's
  Favorites do (`SpacePager.hold` today).
- **Drags** (`ColumnDrag.swift`, step 3): one AppKit tracker over the
  page (an `NSPanGestureRecognizer` with `delaysPrimaryMouseButtonEvents`
  off, so a click is still the row's), driving the same arithmetic the
  SwiftUI column drives: `Folders.landing`, `nestLanding`, `slots`,
  `SideBar.deep`, the dwell that makes a folder of two rows, the spring
  that opens a shut folder under the hand, the herd of picked rows, a row
  carried up into the pins or a pin down into the rows, `TearOff` past the
  window's edge, `SplitDeck` over the pages, `SpaceDrop` over the foot.
  The rows stepping aside are the cells' layers moved on `Motion.settle`'s
  spring by Core Animation, not SwiftUI passes. Links and files dropped on
  the column are the page's `registerForDraggedTypes`, handed to
  `Browser.take` as SwiftUI's `onDrop` did.
- **Keyboard and VoiceOver**: the cells' SwiftUI rows keep their own
  accessibility (labels, traits, actions); the page is an
  `NSAccessibilityElement` list in row order so VoiceOver walks the rows
  as one list, scrolled in sight as it goes.

### What stays SwiftUI, for now

The head (the lights, back, forward, reload, the address plate), the foot
(the spaces' dots or emoji, the plus menu, downloads, the island) and the
column's ground. They are in SideBar, which still watches the browser;
measured at about 5 ms each per switch. Cutting them to narrow observable
models is step 5, shared with the work splitting `Browser` and
`Preferences` into small `@Observable` models: the column reads them
through narrow interfaces (`ColumnSource`) so either source works.

## Data flow

- The browser's `tabs`, `activeID`, `pairs`, `spaceID`, `parked`,
  `editingTab`, `newTabLit`, picked tabs; Folders' `version`; the
  preferences' density, glyph, side width; the column's tone (read in
  SwiftUI by a probe view inside `Worn`, as `ChorusInk` reads it, handed
  to the pages) come in through `ColumnSource`, one Combine sink each,
  coalesced to one layout per run-loop turn.
- A change of anything a row shows: the page lays out (`ColumnLayout`,
  O(rows), no views), diffs the items by id, moves cells that stayed (on
  `Motion.room`/`Motion.leave` springs as the SwiftUI column's count
  animations did), rebinds cells whose look changed, and makes or reuses
  cells for items that came into sight.
- A change of space: the page of the new space is shown (made once, then
  kept; five at most, the oldest dropped, as `KeptRows.most`), and the
  clip slides. Its rows were laid as the space last stood and are laid
  again only if what they show changed while away (a tab of it closed by
  sync, a folder renamed); nothing in SwiftUI's column graph is touched by
  the rows.

## What replaces what

| SwiftUI column | AppKit column |
|---|---|
| `SideBar.rowPages`, `KeptRows`, `KeptPage`, `KeptStill` | `ColumnPages`, one `ColumnPage` per space |
| `rowsScroll`, `ScrollViewReader`, `ScrollView`, content margins | `NSScrollView`, `contentInsets` top `lead`, bottom `footRoom` |
| `loose(_:)`, `LazyVStack`, `baseSlots`, `looseSlots`, `FolderRowPlace` | `ColumnLayout` + cell recycler |
| `TabCell` | `ColumnCell` with `ColumnItem.Look` |
| `ColumnFade` mask, `ColumnBlur` overlay, `ColumnScrolled` | gradient mask layer, `EdgeBlurView`, the scroll view's bounds |
| `PagedSpace`, `PagedSpaceRoot`, `PagerStage` pictures, `ColumnView.picture` | the live pages, slid in their clip |
| `reorder`, `pinReorder`, `nestReorder`, `herd`, `carry` @State | `ColumnDrag` |
| `.onDrop(of: [.url, .text])` | the page's dragging destination |
| `DrawnRow`, rows' `keySky.lay`, `NestRow`'s folder frames | reported by the page from its layout |

## Migration, step by step

Each step lands as its own commits, the old column untouched while
ColumnKit is off:

1. **This page, the switch, the layout.** `ColumnKit`, `ColumnLayout`
   with tests against `Folders.slots`.
2. **Rows in AppKit pages.** `ColumnPages`, `ColumnPage`, cells, scroll,
   ends, frames reported, per-space pages kept; SpacePager unchanged
   (its picture of the band includes the pages' layers).
3. **Drags.** Reorder, into and out of folders and nested folders, a
   folder carried whole, the dwell, the spring, picked rows together,
   pin and unpin, out of the window, over the pages, to another space by
   the foot and the edge, links and files dropped, context menus and
   rename (the rows' own), keyboard and VoiceOver.
4. **The pager on live pages, pins and the name in the page.** No
   picture, no PagedSpace; shared pins standing still.
5. **The head and the foot off the browser's whole object.**
6. **Proof, then the default.** A/B against the SwiftUI column: hold per
   switch, hitches, scroll frame times, cells redrawn, memory; overlap.py,
   stops.py, many.py, drags.py and the new drop eval; every state pictured
   beside the old column. ColumnKit is the default now; the SwiftUI rows
   stay behind the switch for a release, then go.

## Status

Steps 1 to 4 have landed behind the switch; the head and the foot stay
SwiftUI (step 5 is not done: measured below, they are a small share of
what is left). Numbers and pictures in
[docs/evidence/column-appkit-2026-10-11.md](evidence/column-appkit-2026-10-11.md).

- **Look**: `evals/column-appkit/look.py` pictures fourteen states on both
  columns, the same build and world (light, dark, Comfortable, Compact,
  the column on the right, glass, see-through off, scrolled, New tab lit,
  folders shut, another space, the card): every one within 0.0044 of the
  SwiftUI column in the worst row-tall strip, the rest a site's mark that
  loaded in one world and not the other.
- **Drags**: `evals/column-appkit/drops.py` runs every kind on both
  columns; the AppKit column passes every take the SwiftUI one does.
- **A change of space**: a key holds the main thread about half as long
  (96 to 44 ms with 30 tabs a space, 102 to 56 with 150, main); a let-go
  81 to 44; the row sets off in 8 to 10 ms. What remains is mostly the
  window outside the column: the same switch with the tabs on top, no
  column at all, holds 85 to 120 ms. Leaving the head out saves about
  5 ms, the foot about 6, the plate nothing (many.py `CUTS=`).
- **Scrolling 500 tabs**: see the evidence page.

### Using it

The AppKit column is the default. The SwiftUI column stays for a release:
`defaults write <bundle id> column.appkit -bool false`, or
`YAB_COLUMN=swiftui` in the environment (`YAB_COLUMN=appkit` the other
way), which wins over the setting. Read when a window's column is made. Every eval in
`evals/column-appkit/` and `many.py COLUMN_AB=1` run both columns on the
one build; `scripts/runs/column_kit.sh` builds the tree and runs the ones
named in `EVALS` (look, drops, scroll, many, cuts, overlap, stops).

### Where things are

| File | What |
|---|---|
| `ColumnKit.swift` | the switch, `columnHosted`, the bench's counters |
| `ColumnLayout.swift` | the rows, pins and name laid as SideBar lays them; a parked space's |
| `ColumnPages.swift` | the pages of the spaces, the row of spaces sliding, the ends' layers |
| `ColumnPage.swift` | one space's page: scroll view, cells, head, the overlay, where rows are said to be |
| `ColumnCells.swift` | a cell: the SwiftUI row in its own host, rebinding, coming and going |
| `ColumnDrag.swift` | the press (a local monitor) and every drag, ported from SideBar |
| `ColumnMotion.swift` | Motion's curves as Core Animation's |

Bench: `columnkit` (pages, cells, binds, row bodies, the hand; `reset`,
`scroll`), `colwheel` (a wheel over the rows), `droptarget`, `rowframes`
(with pins and the capsule), `pace column-scroll`, `drag` with `down`/`up`.
