# State and observation

How the window's state is kept so that a change redraws only the views
that draw it, how to add state, and how to follow it from AppKit. Written
for the move of Preferences, Browser and Tab from `ObservableObject` to the
Observation framework (`@Observable`, macOS 14 and later; the package
targets 15.4), October 2026.

## Why

With `ObservableObject` the unit of change is the object. Every
`@Published` write sends `objectWillChange`, and every view holding the
object with `@ObservedObject` or `@EnvironmentObject` runs its body again,
whatever it reads. Browser held 81 published values, Preferences 68, and
Browser forwarded every preference change as its own, so:

- toggling a setting nothing in the window draws re-ran the window, the
  column's rows, the strip's pills, the space capsule and the page's
  overlays (Codex measured the strip's pills alone: 26 bodies for a
  preference change, 2 once each pill kept only the glyph it draws,
  e1e18845);
- a tab's title or its loading flag re-ran every view holding that tab,
  whatever part of it they draw;
- a hover flag, a drag's progress or a chat width written at frame rate
  re-ran everything else that holds Browser.

With `@Observable` the unit is the property: SwiftUI records which
properties a body read while it ran, and only a change to one of those
runs it again. The same is true for AppKit code that reads inside
`withObservationTracking`. So the work is not to split the objects into
many small ones, but to make each view read only what it draws.

## What changed

| Class | Before | Now |
|---|---|---|
| `Preferences` (Prefs.swift) | `ObservableObject`, 68 `@Published` | `@Observable`; every setting tracked on its own |
| `Browser` (Browser.swift) | `ObservableObject`, 81 `@Published`, every preference change forwarded | `@Observable`; the 81 tracked, plain values `@ObservationIgnored`; preferences no longer forwarded |
| `Tab` (Tab.swift) | `ObservableObject`, 58 `@Published` | `@Observable`; the 58 tracked, and the plain values views draw (asleep, visits, a call's start, hushed, touched...) |

Nothing about persistence moved. Every setting keeps its name, its
UserDefaults key, its `didSet` that writes it, and its place in sync
(`SyncShapes`, `Preferences.adopt`), `native_apply` (NativeActions.swift)
and the Settings index. The objects and their property names are the
same, so no call site that reads or writes them changed.

The conformance to `ObservableObject` is gone from these three and from
every other model, with every `objectWillChange` broadcast. The few
changes views read from outside the object, which the broadcast once
covered, are observed state now: `Density.current` lives in an observed
holder, so a body drawing a size from it depends on it; the Mac's display
options are `DisplayOptions.shared` (Prefs.swift); a bookmark icon
arriving moves a tracked revision on Favicons that its readers read; a
dev server's choice is kept in an observed store (`DevSites`); and Mail's
look and place carry a tracked revision read with them (MailSpace.swift).

## Inventory

Readers are files that read the value (`grep` of `prefs.NAME`,
`browser.NAME`, October 10, 2026), most first. The groups are by who reads
and how often the value changes; they are the "small models" a view
should think in, and the boundary along which a group can later become an
object of its own if it needs to (see "When a separate object pays").

### Preferences

| Group | Settings | Changes | Main readers |
|---|---|---|---|
| Layout of the tabs | `sidebar`, `sideShut`, `stripShut`, `sideFlank`, `sideWidth`, `density` | ⌘S, ⇧⌘S, the column's edge dragged (`sideWidth`, every frame of a drag) | App 25, Browser, Query, Lights, Side 17, Peek, SpacePager |
| Tabs | `glyph`, `sleepsTabs`, `tidyAfter`, `pinsEverySpace`, `usesSpaces`, `usesLiveFolders` | Settings | Side, TabBar, Keep, SpaceFoot, Spaces, LiveFolders |
| Window look | `look`, `backdrop`, `swatch`, `backdropTransparency`, `backdropColor`, `backdropColors`, `grain`, `lookShift`, `lookSite`, `lookDrawings`, `lookDrawingsStrength`, `lookMode`, `lookGlass` | the look card, every frame of its sliders | LookCard, App, SpacePager, Spaces, WelcomeStage, SettingsWindow |
| Bars | `addressBar`, `fullURL`, `bookmarkBar`, `bookmarkStyle` | Settings, ⇧⌘B | Query, App, AddressBar, Browser |
| Pages | `pageZoom`, `pageFonts`, `shielded`, `extensionsInPrivate`, `diaryText`, `peeks` | Settings | PageAppearance, NativeControl, SiteControls |
| Passwords and forms | `passkeys`, `savesPasswords`, `fillsPasswords`, `codesFromMail`, `codesFromTexts`, `savesCards`, `fillsCards`, `fillsForms`, `draftsForms`, `provesToFill` | Settings | SettingsCorePages, WalletKeep, MailCodes |
| Search | `engine`, `engineCustom`, `searchSuggest`, `siteLearn`, `siteRecent` | Settings | SearchSettings, Browser |
| Agents | `agentsRemember`, `agentsAsking`, `askOpens`, `agentsMessages`, `bench` | Settings | AgentSettings, MemorySettings, the agent bench |
| Mail | `usesMail`, `mailAnimations` | Settings | MailSettings, NativeControl |
| Player and floating | `showsPlayer`, `floatsOnLeave`, `floatsAway` | Settings, the island's menu | PlayerBand, Tune, Browser |
| Small windows and quitting | `smallLinks`, `smallKey`, `warnsOnQuit` | Settings | SmallWindowSettings, Links |
| Developers | `devSide`, `offerDevMode` | the dev sheet's side | DevMode, DevTools, App |
| Downloads | `downloads`, `asksWhereToSave` | Settings | Places, Browser |
| First launch | `welcomed` | once | WelcomeStage |

### Browser

| Group | Values | Changes | Main readers |
|---|---|---|---|
| The row | `tabs`, `activeID`, `pairs`, `stagePair`, `gathered`, `stages` | a tab opened, closed, picked, paired | Browser, TabBar 36, Side 19, NativeControl, AgentFolders, App |
| Spaces | `spaces`, `spaceID`, `spaceStep`, `parked` | a space switched or edited | SpaceSettings, SpaceFoot, Side, LiveFolders, SpaceTray |
| Shape in motion | `turning`, `folding`, `stripMoving`, `stripDown`, `splitting`, `splitHeld`, `wide`, `windowFloor`, `sidePull`, `stillLights` | ⇧⌘S, ⌘S, split view, for the length of a motion | App, Browser, Lights, Peek |
| Window chrome | `fullScreen`, `menuDown`, `menuOut`, `titleLights` | the pointer at the window's top, full screen | Lights, SpacePager, Welcome |
| The field | `editing`, `asked`, `under`, `refusals`, `finding`, `suggesting`, `lit`, `walletList`, `walletLit`, `codeList`, `codeLit`, `walletChosen`, `walletBoxEmpty`, `fileSelected` | ⌘T, ⌘L, every key typed into it, a sign-in box focused | Browser, Omnibox, App, PageContent, Accounts |
| Writing a tab's name | `editingPin`, `editingTab`, `editingHome`, `tabDraft` | a double-click on a tab | Browser, TabBar, Side |
| Bookmarks bar | `shelving`, `shelfUp`, `shelfLeaving`, `shelfHeading` | ⇧⌘B | App |
| Chat column | `chatOpen`, `chatMoving`, `chatWidth`, `chatSizing`, `chatPinned`, `chatShown`, `chatHistory`, `chatArchive`, `chatFresh`, `chatFocus`, `chatDraft`, `chatNext`, `modelPicker`, `chatDropShown`, `chatTabOver` | the chat column, every frame of its edge dragged | ChatColumn, ChatComposer, App, SplitDeck |
| Developer sheet | `devOpen`, `devPicking`, `devDetached`, `devPane`, `devPanels`, `devRoomWidth`, `issueFilter`, `devDrawer`, `devMoving`, `devSizing` | the sheet, its edge dragged | DevShell, DevTools, DevMode, App |
| Clearing the line | `dusting`, `dustFolded`, `dustingRows`, `dustFoldedRows`, `ghosts` | Clear on the kept line | Side, ExtensionShims |
| Panels | `tuning`, `welcoming`, `veiling`, `floating` | Settings, the welcome, hiding parts of a page, a video out | SettingsCorePages, WelcomeStage, App |
| Counts that say "it happened" | `backs`, `forwards`, `reloads`, `copies` | each press | TabBar, AddressBar, SiteControls |

The plain values Browser keeps beside these (about a hundred: the peek's
tab, geometry the column reports from layout such as `rowsClip`, `pinsTop`,
`nameTop`, `keptLine`, closures, watchers, caches like `activeFound`) were
never published, and stay outside observation (`@ObservationIgnored`): a
write to one redraws nothing, as before. Three were drawn by views that
counted on some other change to redraw them, and are observed now:
`parked` (the capsule's sound), `stages` (which pages the window shows)
and `fileSelected` (the field's ticks).

### Tab

All 58 published values are observed one by one: a retitle redraws the
title's readers, `loading` the ring's and the load bar's, `icon` the mark's.
Of the plain values, those a view draws are observed too: `pending` (so
`asleep`), `visits`, `touched`, `everywhere`, `homeTitle`, `callStarted`,
`hushed`, `hushedAt`, `stale`, `draft`, `stuckDraft`, `deaf`, `deafAsked`,
`pictureInPicture`, `uploading`, `answering`, `began`, `chosen`, the
agent's `allowed`, `refused`, `declined`, `approved`, `tune`, `skipsAds`,
`popup`. The rest (the web view built on first use, closures, KVO watches,
the focused box's state, scroll depth) stay outside it.

## When a separate object pays

Per-property tracking makes splitting unnecessary for invalidation. It
still pays to give a value an object of its own when:

- it changes at frame rate and one view draws it, and that view should not
  also be handed the whole Browser: SplitPreview, StripPeek, SidePeek,
  HeadPeek and DrawnRows already are such objects;
- AppKit draws it, and the AppKit side wants a small surface to follow
  (the column being rewritten on Core Animation reads the row, the spaces
  and the layout group above; it can follow exactly those with
  `ObservationLoop` and needs no new type);
- several windows share it (Preferences is still one per window, each a
  copy kept in step by the `didSet`s that walk `BrowserWindows`; one shared
  object would be simpler, but every setting's write path and sync's
  `adopt` would change with it, so it is left for its own step).

The groups above are the candidates, in this order if one is ever made:
the field (`FieldState`: written on every key typed), the chat column
(`ChatState`), the developer sheet (`DevState`), the shape in motion
(`MotionState`). Each would keep its property names, so readers change
from `browser.chatOpen` to `browser.chat.chatOpen` and nothing else.

## Rules

For all state, checked by `./design-check` on every added line:

1. New shared state is a `@MainActor @Observable final class`, never an
   `ObservableObject`.
2. A view takes the object as a plain `let` (or `@Bindable var` when it
   needs `$object.value` bindings, `@Environment(Type.self)` when it comes
   from the environment). No `@ObservedObject`, no `@EnvironmentObject`.
3. Read only what you draw. A body that reads `browser.tabs` to count them
   depends on every change to the row; read a value computed for you, or
   hand the child the one value it needs.
4. An `Equatable` row (TabPill, SideRow, PagedSpace) gets its inputs as
   values in `init`, which runs in the parent's body, and reads nothing of
   Browser in its own body: `==` cannot stop a body that depends on an
   observed property directly.
5. Observation tells of every write, equal or not: a value written at
   frame rate or from layout is written only when it changed, and a value
   written from layout that no body should depend on is
   `@ObservationIgnored` (geometry reports, caches written while drawing,
   closures, watchers). A body that reads an ignored value must also read
   the observed value it changes with.
6. A change is told in the property's `willSet`, before it holds the new
   value. SwiftUI reads a turn later; code told synchronously must not read
   the property, it gets the new value handed to it (`changes(\.name)`),
   or waits a turn (`ObservationLoop` does).
7. `withAnimation` and `withTransaction` work as before; now each view
   takes the transaction of the change it depends on, not the last change
   anywhere in the object. `Browser.quietly {}` still puts several writes
   into one transaction.
8. There is no "every view, redraw". A value views draw that Observation
   can't see (a static, a cache, a plain class, a store on disk) is made
   observed: an `@Observable` holder for it, or a tracked
   `private(set) var revision` bumped where it changes and read where it
   is read.

## Following state from Combine and AppKit

- `object.changes(\.name)` (Observed.swift) is what `object.$name` was: the
  value now and each new value, sent in `willSet`. Every formerly
  published property sends to it; `relay.any` fires for any of them, as
  `objectWillChange` did, for code that watched the whole object
  (ChatColumn's follow, Settings' navigation).
- `ObservationLoop { ... }` runs a closure now and again a run-loop turn
  after anything it read changes, several changes in one turn running it
  once. Keep the loop as long as the view lives; `cancel()` or let it go to
  stop. An AppKit view of the column would be:

  ```swift
  loop = ObservationLoop { [weak self, browser] in
      self?.lay(tabs: browser.tabs, active: browser.activeID, width: browser.prefs.sideWidth)
  }
  ```

- For a synchronous answer inside the change's own transaction (a layer
  that must move in the same commit), use `changes(\.name)`, which hands
  over the new value before SwiftUI draws.

## Measuring

`evals/perf/bodies.py` counts SwiftUI bodies per everyday change. A farm
job's own copy of the sources gets a `BodyMeter.tick` in every body
(`evals/perf/instrument_bodies.py`; never committed), the app is built and
a world of three spaces of 24 tabs is made, then each change is made three
times with the column and three times with the strip, and the medians of
each view's count are kept:

```sh
./farm exec --display --estimate 1800 -- bash evals/perf/bodies_job.sh NAME
```

Results go to `bodies-NAME/bodies.md` and `bodies.json` in the job's
evidence folder (`./farm where JOB`). The bench verb behind it is
`./bench bodies` (BodyMeter.swift): `reset`, `read`, and the changes
`pref-quiet`, `pref-glyph`, `title`, `reload`, `type`. Counts are bodies
run, not frames drawn; compare two builds on the same Mac in the same
hour.

### Before and after, October 10, 2026

Main, both builds the same optimized development build, the same hour:
before is main at 141b896b with the meter (job 7548238f8a6148bd), after
is the move to Observation on top (job 6232fdc6a1a74102). Bodies run per
change, median of three; the answers are in
[evidence](evidence/state-observation-2026-10-10/).

| Layout | Change | Before | After | Change | Views that ran most, before → after |
|---|---|---|---|---|---|
| column | pref-quiet | 56 | 0 | −100% | KeptLine 6→0, Worn 5→0, Toned 5→0 |
| column | pref-glyph | 124 | 416 | +235% | TabEnd 16→102, SideRow 16→102, IconPickerHang 16→102 |
| column | title | 52 | 14 | −73% | Ink 6→6, Toned 5→0, Kick 4→0 |
| column | reload | 335 | 63 | −81% | Toned 35→0, Kick 28→2, LiveWordsView 14→0 |
| column | select | 99 | 102 | +3% | Ink 6→6, KeptLine 6→6, Kick 4→4 |
| column | space | 101 | 105 | +4% | KeptLine 6→6, Kick 4→4, Shaded 4→4 |
| column | type | 44 | 44 | 0% | Row 18→18, FieldMark 13→13, Omnibox 6→6 |
| column | settings open, pref-quiet | 63 | 2 | −97% | KeptLine 6→0, Toned 5→0, Worn 5→0 |
| strip | pref-quiet | 42 | 2 | −95% | Kick 3→0, SettingsRow 2→1, Toned 2→0 |
| strip | pref-glyph | 142 | 101 | −29% | TabMark 24→24, IconPickerHang 24→24, TabPill 24→24 |
| strip | title | 36 | 7 | −81% | Ink 3→3, Kick 3→0, Toned 2→0 |
| strip | reload | 241 | 40 | −83% | Kick 21→2, Toned 14→0, Shaded 14→0 |
| strip | select | 103 | 91 | −12% | Shaded 4→4, Worn 4→4, Toned 4→4 |
| strip | space | 371 | 356 | −4% | TabPill 48→48, IconPickerHang 48→48, TabMark 48→48 |
| strip | type | 44 | 44 | 0% | Row 18→18, FieldMark 13→13, FieldFoot 6→6 |
| strip | settings open, pref-quiet | 42 | 2 | −95% | Kick 3→0, Shaded 2→0, Worn 2→0 |

Nothing touched runs no body either way. What the numbers say:

- A setting the window doesn't draw runs nothing now (Settings' own row
  and sidebar, 2, when it is open), and a page's title or a reload runs
  the title's and the ring's views instead of everything holding the tab.
- Picking a tab, switching spaces and typing in ⌘T are unchanged: what
  runs there reads `activeID`, the row or the field's query and does
  change. These are the next work, view by view (rule 3), with the field's
  `Query` still an `ObservableObject`.
- The column's glyph change runs more, because it is right now: the column
  hands each row its glyph from the row list's body (SideRow's init), and
  the lists of the other spaces kept for a swipe (PagedSpace, Equatable on
  the row alone) never heard the change before, so a swipe after it showed
  the old marks until the next redraw. Now those lists hear it too: about
  four bodies per row, once, on a setting changed by hand. The column's
  rewrite on Core Animation replaces these views.
