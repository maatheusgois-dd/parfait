# Calendar integration — implementation plan (2026-07-14)

> Status: PLAN — backend matching exists; this doc adds **upcoming-events surfaces**
> (menu bar + main-window Home) and finishes the recording-time pipeline.
> Reference UX: menu-bar agenda + "Coming up" home screen (common pattern in meeting-note apps).

## What we're building

Parfait already matches the **current** calendar event when recording starts (title +
attendees). The gap: calendar is only used at record time — users can't **see their
schedule** in the app beforehand. This plan adds that.

### UX patterns to adopt

| Surface | Reference pattern | Parfait (this plan) |
|---|---|---|
| Menu bar popover | "Tomorrow" (or today) event list with times | Compact upcoming agenda above Recent |
| Main window home | "Coming up" card, events grouped by date | New **Home** detail view with agenda card |
| Below agenda | Past meetings grouped by day | Recent recordings grouped by day on Home |
| Tap event | Start / open note | **Record** — starts recording with event metadata pre-filled |
| Recording match | Title + attendees from invite | Keep + harden (conference-url correlation) |

### Parfait-specific choices

- No email / follow-up-draft integration — out of scope.
- No shared-workspace sidebar — keep Parfait's **Ask your meetings** + **Meetings**.
- Bright Parfait palette (`Theme`), airy cards.
- Mic-based meeting detection unchanged; calendar does not auto-record without user action
  (except explicit **Record** on an event).

## Where we are today

| Area | Status |
|---|---|
| `CalendarMatcher.currentEvent()` | In-progress event → title + attendees at record start |
| `Meeting.calendarEventTitle`, `attendees` | Persisted; flow to templates, MCP, rename UI |
| Settings / onboarding calendar toggle | Exists; permission UX incomplete |
| Menu bar `MenuBarView` | Recording + **Recent** (past meetings only) — **no upcoming events** |
| Main window `MainWindowView` | Sidebar meetings list; no Home / Coming up — **no upcoming events** |

## Architecture

```
 EventKit (read-only, full access)
        │
        ▼
 CalendarStore (@MainActor, owned by AppState)
   ├─ refreshAgenda()          → upcoming days + events
   ├─ currentEvent(...)        → in-progress match (recording hook)
   └─ EKEventStoreChanged      → debounced refresh
        │
        ├──────────────────┬────────────────────┬─────────────────────
        ▼                  ▼                    ▼
  MenuBarView         ComingUpView         startRecording(...)
  upcoming section    agenda card +          pre-fill from tapped
  (compact)           recent-by-day          event OR currentEvent()
```

### A. Calendar module (`Sources/Parfait/Calendar/`)

Move `CalendarMatcher` here; split **I/O** from **pure logic**.

```swift
struct CalendarEventSummary: Sendable, Identifiable, Equatable {
    var id: String              // EKEvent.eventIdentifier
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var attendees: [String]
    var conferenceURL: URL?
    var calendarTitle: String? // source calendar name, for optional subtitle
}

struct CalendarAgendaDay: Sendable, Identifiable, Equatable {
    var id: String              // yyyy-MM-dd
    var date: Date              // start of day
    var label: String           // "Today", "Tomorrow", or "15 July Wed"
    var events: [CalendarEventSummary]
}

enum CalendarEventSelector { /* pure selection for in-progress match */ }
enum ConferenceURLParser { /* zoom / meet / teams from location+notes+url */ }
enum AttendeeExtractor { /* name > mailto, skip self, de-dupe */ }
```

**`CalendarStore`** (new, `@MainActor`):

```swift
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var agenda: [CalendarAgendaDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    func refreshAgenda(now: Date = .now, horizonDays: Int = 3) async
    func currentEvent(at: Date, sourceApp: String?) async -> CalendarEventSummary?
    static func requestAccess() async -> Bool
    static var isAuthorized: Bool
    static var isDenied: Bool
}
```

**Agenda query** (`upcomingEvents`):

- Window: `startOfToday` through `endOfDay(today + horizonDays - 1)` (default **3 days**:
  today + tomorrow + day after).
- Drop all-day events.
- Sort by `start` ascending within each day.
- Group into `CalendarAgendaDay` buckets by local calendar day.
- Labels: **Today**, **Tomorrow**, else `DateFormatter` → `"15 July Wed"`.
- Run `events(matching:)` on `Task.detached`; publish on main actor.
- Refresh triggers: app bootstrap, `NSApplication.didBecomeActive`, calendar access granted,
  `EKEventStoreChanged` (debounce 2 s).

**In-progress match** (`currentEvent`): reuse `CalendarEventSelector` from the prior plan
(conference-url + shortest-duration heuristics). `AppState.startRecording` calls this when
no explicit event was passed.

### B. Recording from an event

New overload:

```swift
// AppState
func startRecording(
    sourceApp: String? = nil,
    calendarEvent: CalendarEventSummary? = nil
) async
```

When `calendarEvent` is set (user tapped **Record** on an agenda row):

- Set `meeting.title`, `calendarEventTitle`, `attendees`, `calendarEventID`,
  `calendarEventStart`, `calendarEventEnd` from the summary — **no re-query**.
- Skip `currentEvent()` lookup.

When `calendarEvent` is nil (menu-bar "Start recording", mic detection):

- Keep today's behavior: `currentEvent(at:sourceApp:)` when `useCalendar && authorized`.

Extend `Meeting` (`Store/Models.swift`):

```swift
var calendarEventID: String?
var calendarEventStart: Date?
var calendarEventEnd: Date?
```

### C. Menu bar — upcoming section (`MenuBarView`)

Insert between the recording/detection block and **Recent**:

```
┌─ Parfait ─────────────────────┐
│ [recording card / start btn]    │
│                                 │
│ Coming up                       │  ← section header (11pt secondary)
│ Weekly 1:1 with Alex            │
│   4:45 PM – 5:00 PM             │
│ Engineering standup             │
│   2:30 PM – 2:45 PM             │
│ … (max 5 rows, scroll if more)  │
│                                 │
│ Recent                          │
│ …                               │
│ ─────────────────────────────── │
│ Open Parfait          [power]   │
└─────────────────────────────────┘
```

Behavior:

- Hidden when `!useCalendar || !authorized` (no empty state nag — calendar is optional).
- Each row: title (12pt medium) + time range (10pt secondary). Optional location
  line when present, truncated.
- **Click row** → `startRecording(calendarEvent:)` (disabled while already recording).
- **In-progress event** gets a mint left accent bar and shows "Now" instead of start
  time when `start <= now < end`.
- Popover width stays 320; agenda area `maxHeight: 160` with `ScrollView` if needed.
- If today has no remaining events, show next day header (e.g. **Tomorrow**).

### D. Main window — Home / Coming up (`ComingUpView`)

New default detail when the app opens.

**Sidebar** (`MainWindowView`):

```swift
enum SidebarItem: Hashable {
    case home          // NEW — default selection
    case library
    case meeting(UUID)
}

Section {
    Label("Coming up", systemImage: "calendar")
        .tag(SidebarItem.home)
    Label("Ask your meetings", systemImage: "bubble.left.and.text.bubble.right")
        .tag(SidebarItem.library)
}
Section("Meetings") { … }
```

**Detail** — `ComingUpView`:

```
┌─ Coming up ──────────────────────────────── [◀ ▶] ─┐
│  ┌─ card ─────────────────────────────────────────┐  │
│  │ 14 July Tue                                    │  │
│  │   No more events today                         │  │
│  │ 15 July Wed                                    │  │
│  │ │ Company all-hands              11:00–11:40  │  │
│  │ │ Lunch                          12:30–1:30   │  │
│  │ │ Engineering standup            2:30–2:45   │  │
│  │ │ Weekly 1:1 with Alex           4:45–5:00   │  │  [Record]
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  Today                                               │
│  ┌ Product sync ────────────────── 3:30 PM ────────┐  │  → opens meeting
│  └ Leadership review ──────────── 1:00 PM ─────────┘  │
│  Mon, Jun 8                                          │
│  └ Team social ─────────────────── 2:00 PM ───────────┘  │
└──────────────────────────────────────────────────────┘
```

**Agenda card** (top):

- `.cardStyle()` container; section headers per `CalendarAgendaDay`.
- Event row: colored leading bar (`Theme.raspberry` / `Theme.honey` / `Theme.blueberry`
  cycling by index), title, time range, optional location.
- **Record** button on hover (or trailing on wide windows) — calls
  `startRecording(calendarEvent:)`. Disabled if already recording or event is in the past.
- **Chevrons** shift `horizonDays` window forward/back by 1 day (state:
  `@State var agendaOffsetDays = 0`); refresh query with offset. Disabled when offset = 0
  for back chevron.
- Empty states: "No more events today" under today's header when today's future events are
  exhausted; "No upcoming events" when agenda is empty and calendar is authorized.
- Unauthorized: airy empty state — "Grant calendar access in Settings to see your schedule"
  with button → Settings.

**Recent recordings** (below agenda card):

- Reuse `app.store.meetings`, grouped by local day (`MeetingDayGrouper` — pure helper).
- Section headers: **Today**, **Yesterday**, else `"EEE, MMM d"` (e.g. "Mon, Jun 8").
- Row: title, attendee/subtitle line (`attendees.prefix(2).joined` or `sourceApp`),
  time on the right.
- Tap → `selection = .meeting(id)` (existing behavior).
- Show last **14 days** or **20 meetings**, whichever is smaller — keep the home scannable.

**Default selection**: `SidebarItem.home` on first open; `adoptPendingSelection()` still
wins when `openMeetingID` is set.

### E. Recording-time pipeline (finish + harden)

Everything from the prior plan, unchanged in spirit:

1. `CalendarEventSelector` + conference-url correlation with `sourceApp`.
2. Permission UX in Settings → Permissions (Grant / Open Settings / status dot).
3. Meeting detail "From calendar · …" source line when `calendarEventID != nil`
   (e.g. "From calendar · Weekly 1:1 · 4:45–5:00 PM").
4. Overflow **Match calendar event…** when unmatched.
5. `maxSpeakers = attendees.count` in `ProcessingPipeline` (already shipped).

### F. Link recordings ↔ calendar events (optional polish)

On Home recent rows, if `meeting.calendarEventID` matches an agenda event still in the
horizon window, show a small calendar icon on the meeting row. On agenda rows, if a
**ready** meeting exists with the same `calendarEventID`, show **View notes** instead of
**Record** (opens that meeting). Lookup: `app.store.meetings.first { $0.calendarEventID == event.id }`.

## Implementation order

| Phase | Work | Files |
|---|---|---|
| **1 — Core** | `CalendarEventSummary`, parsers, selector, tests | `Calendar/`, `CalendarMatcherTests` |
| **2 — Store** | `CalendarStore`, agenda query, `EKEventStoreChanged` | `Calendar/CalendarStore.swift`, `AppState` |
| **3 — Model** | `calendarEventID/Start/End` on `Meeting`, archive round-trip | `Models.swift`, `MeetingArchive` |
| **4 — Record** | `startRecording(calendarEvent:)`, wire metadata | `AppState.swift` |
| **5 — Menu bar** | Upcoming section in `MenuBarView` | `MenuBarView.swift` |
| **6 — Home** | `ComingUpView`, `MeetingDayGrouper`, sidebar Home item | `ComingUpView.swift`, `MainWindowView.swift` |
| **7 — Polish** | Permissions UX, meeting detail source line, re-match, event↔meeting link | `SettingsView`, `MeetingDetailView` |
| **8 — Docs** | `TESTING.md`, README one-liner | `docs/` |

## Testing

### Unit (`CalendarMatcherTests.swift`)

- `CalendarEventSelector.select` — in-progress, back-to-back, hold vs meeting, conference URL.
- `AttendeeExtractor` — name, mailto, skip self, de-dupe.
- `ConferenceURLParser` — Zoom, Meet, Teams samples.
- `MeetingDayGrouper` — today/yesterday labels, sort order.
- `CalendarAgendaDay.label(for:now:)` — Today, Tomorrow, formatted date.

### Manual (`docs/TESTING.md`)

```markdown
## Calendar — upcoming events UI

### Menu bar
- [ ] Popover shows "Coming up" with today's/tomorrow's events and times
- [ ] Click an event → recording starts with event title (no placeholder)
- [ ] In-progress event shows "Now" accent; Record disabled while already recording
- [ ] With calendar off or denied → upcoming section hidden (no broken empty state)

### Home (Coming up)
- [ ] Sidebar "Coming up" is default on fresh open
- [ ] Agenda card lists events by day; chevrons shift to next/previous days
- [ ] Record on a future event pre-fills title + attendees
- [ ] Recent recordings grouped under Today / Yesterday / date headers
- [ ] Tap a recent row → opens meeting detail
- [ ] Event with existing notes shows "View notes" instead of Record

### Recording match (existing)
- [ ] Auto-detected Zoom call during scheduled event → title from calendar
- [ ] Attendee chips + rename suggestions in transcript
- [ ] Denied calendar → Settings shows Open Settings
```

## Cost, performance, risk

- **Refresh rate:** one EventKit query per debounced change + foreground — not per render.
  Agenda horizon is 3 days; typical <100 events, <50 ms.
- **Menu bar height:** cap visible rows + scroll so popover doesn't overflow small screens.
- **Stale agenda:** acceptable for minutes; `EKEventStoreChanged` covers most edits.
  User can switch away and back (foreground refresh) for instant update.
- **Timezone / all-day:** all-day events excluded; timed events use `Calendar.current`.
- **Privacy:** read-only; no calendar writes. Agenda stays in memory, not written to disk.

## Decisions — resolved

1. **Default home** → Coming up, not first meeting.
2. **Auto-record from calendar** → no. User taps Record or uses mic detection.
3. **Horizon** → 3 days in menu bar; Home card uses same store with chevron offset.
4. **Gmail / email follow-ups** → out of scope.
5. **Which calendars** → all calendars v1; per-calendar filter v1.1.

## Out of scope (later)

- Gmail / email draft follow-ups.
- Write meeting notes back to the calendar event.
- Calendar-only detection without user action ("event started, auto-record").
- Shared calendars permission edge cases beyond full-access read.
- iOS / iCloud calendar webhooks.

## Definition of done

Calendar integration is **complete** when:

1. Menu bar popover lists upcoming events with times; tap starts a named recording.
2. Main window **Coming up** is the default home — agenda card + recent meetings by day.
3. Recording still auto-matches in-progress events on mic-detected starts.
4. Permission denied is recoverable; calendar-off hides surfaces cleanly.
5. Unit tests cover selection, grouping, and parsers; manual checklist passes.
