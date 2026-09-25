# Habit Planner

[![CI](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml/badge.svg)](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml)

An Apple habit app built around morning and evening routines, following the framework in James Clear's *Atomic Habits*.

A reminder starts the routine. The app shows one habit at a time. You mark it complete and the next one appears. You can add a new habit only once the previous one has bedded in.

Most habit apps show a checklist and let you pick items in any order. That works against the point of a routine, where the sequence is what makes the behavior automatic. Sequencing is the product here.

## Status

Phases 3 to 5 are built and tested on simulators: the iOS app, the watchOS app and its bridge,
and the widgets and complications, with 229 package tests. None of them has run on a physical
device yet, and the CloudKit schema has not been primed or promoted. See
[Before the first TestFlight build](#before-the-first-testflight-build).

## Platforms

All Apple. iPhone, Apple Watch, and Mac. A web dashboard was considered and dropped in favor of a native Mac app, which covers the same reporting need and avoids reading Apple's private CloudKit schema from outside.

## Architecture

```
HabitKit          pure Swift. Domain model, scoring, rules. No SwiftData, no UI.
HabitStore        SwiftData models, mapping, container config. Depends on HabitKit.
HabitIntents      App Intents, shared across every platform.
HabitAI           macOS only. On-device model access behind a protocol.
```

`HabitKit` knows nothing about `HabitStore`. The arrow points one way, which is what keeps the
domain testable with no container and preserves the exit path if SwiftData and CloudKit turn
out not to work together for this app.

Target topology is one multiplatform app target for iPhone, iPad, and Mac, plus a separate watchOS target. watchOS cannot join a multiplatform target, so that split is a constraint rather than a preference.

### Where data lives

| Device | Store | CloudKit |
|---|---|---|
| iPhone | SwiftData | Full peer |
| Mac | SwiftData | Full peer |
| Watch | SwiftData | Local only |
| Widgets | Shared App Group | Read only |

**The watch never talks to CloudKit.** Apple has an acknowledged bug (FB17685611) where SwiftData with CloudKit sync terminates the watch app 30 to 60 seconds into an extended runtime session when the iPhone is disconnected. That is the exact condition this app needs to work in, since the whole point is running a routine with your phone in another room. There is also a documented history of watch CloudKit sync degrading to hours, or working only while the watch is charging, because sync is scheduled by a system daemon with no override available to apps.

So the watch keeps a local store and bridges to the phone over WatchConnectivity. See [The watch](#the-watch). Only the iPhone and Mac write to CloudKit.

### Nothing derived is stored

There is no streak count, no `isLockedIn` flag, and no completion tally in the data model. Completions are append-only immutable events, and every score and rule decision is computed by folding that log at read time.

Lifecycle works the same way. Pausing and archiving are events in their own log rather than fields on the habit. A single mutable `pausedOn` cannot describe a pause that ended, so resuming would either replay the paused days as misses or freeze the habit forever. A log handles any number of pauses and survives last-writer-wins replication, because nothing is ever overwritten.

This is a direct consequence of the sync design. CloudKit replicates last-writer-wins, offers no unique constraints, and does not guarantee that related changes save atomically. A gate that makes an irreversible decision from stored aggregate state would misfire on that foundation, and it would misfire quietly.

The same reasoning drives event identity. A `CompletionEvent` derives its ID from its content, specifically `(habitID, dayKey, slotIndex)`, so the same completion arriving by two different sync paths collapses into one record instead of double-counting the day. Equality and hashing delegate to that ID, so a `Set` cannot disagree with it.

Completions are correctable, which matters because HealthKit can propose one and get it wrong. Undoing a tick appends a retraction rather than mutating or deleting anything, and the fold takes whichever assertion was recorded last.

That needs two clocks. `occurredAt` is when the habit was done, `recordedAt` is when somebody said so, and they come apart whenever a completion is backfilled from Health a day later. Conflicts resolve on `recordedAt`, so a correction wins. The surviving `occurredAt` is the earliest asserted, so a completion arriving twice keeps the moment it actually happened.

Because nothing derived is stored, a retraction needs no repair. The gate simply recomputes. If it had already opened and a habit was added, that habit stays and the gate closes again behind it.

## Domain rules

### Lock-in gate

A habit unlocks the right to add another when, across the trailing 28 **scheduled occurrences**:

- completion rate is at least 85 percent, and
- no two consecutive misses fall within the last 14 days

Counting occurrences rather than calendar days means a three-times-a-week habit is judged on the same terms as a daily one. Left to run, this lands somewhere in the four to ten week range.

That range is the point. Clear deliberately avoids naming a number of days. The study he cites, Lally et al. (2010), found a mean near 66 days across a range of 18 to 254. The familiar 21-day figure traces back to Maxwell Maltz's observations of plastic surgery patients and describes nothing about habits.

Only the habit that most recently joined the routine is judged. Three rules keep that from being
sidestepped:

- **A paused habit still holds the gate.** Otherwise the person could pause the newest habit, add
  another, and resume, leaving two bedding in at once. Archiving is what releases it.
- **Restoring from the archive works like adding.** It is allowed when the gate is open or the
  habit had already bedded in, and a restored habit rejoins the routine on the day it comes back.
- **A schedule change may not open a shut gate.** Nothing derived is stored, so changing a daily
  habit to three days a week re-judges every past day, and missed off-days stop counting as
  misses. That is allowed except where it would unlock the routine early.

### Never miss twice

One miss costs you the day but leaves the streak standing. Two consecutive misses end it. After a single miss the app enters a visible recovery state, because the second miss is where habits actually die.

A consequence worth knowing: alternating completion and miss keeps a streak alive indefinitely. That is intended. The streak is there to motivate, and the 85 percent gate is what actually judges consistency. Making the streak do both jobs would do both badly.

### Days are resolved once

A `DayKey` is a civil date stored as its `yyyyMMdd` integer. It is resolved in the user's time zone at the moment of completion and then stored, never recomputed from a raw `Date` later. Without this, flying east would silently add or remove a day of streak and misfire the gate.

Arithmetic on a `DayKey` is time zone free and uses integer math rather than `Calendar`, because folding a year of history per habit runs on every widget refresh. A test walks four years day by day and checks every year, month, day, and weekday against Foundation, so the hand-rolled version stays pinned to the real calendar.

### Outside signals propose, they never own

HealthKit can suggest that a walk happened or that a dose was logged, and the app still writes and owns the completion. Deriving completion from a live query would rest the gate on data that can vanish: revoking read permission returns an empty result set that is indistinguishable from never having done the habit, with no API to tell the two apart. Samples are also user-deletable, authorization is granted per medication, and iOS 26 lets someone share only a recent window of history.

So a health-backed habit degrades to an ordinary checkbox when the signal is missing, and the history already recorded is untouched. The drug, the dose and the schedule stay in Apple Health, which owns them properly.

### An unfinished day is not a miss

Today is held apart from settled history. A habit due today that has not been done yet is unfinished. Counting it as missed would break every streak each morning before breakfast.

## Persistence

`HabitStore` holds the SwiftData models and the mapping between them and HabitKit's value
types. Nothing above it ever sees a `@Model` object. Reads return domain values, which are
`Sendable`, so a model object cannot escape the actor that owns its context.

### Two stores, and only one of them syncs

The synced store holds habits, completions, lifecycle events and routine runs, and replicates
to the private CloudKit database. A second store holds one model and never leaves the device.

That second store exists for App Store guideline 5.1.3(ii), which says an app may not store
personal health information in iCloud. The only thing in it is the per-habit binding that says
what to ask HealthKit about, and for a medication habit that names a drug the person takes.

It is the only thing kept, because everything else a reconciliation might want turns out to be
derivable. A ledger of already-consumed health samples is unnecessary, since completion
identifiers are content-addressed and re-reading the same day produces the identifier that is
already there. Dose status and sample durations are unnecessary, since the app owns "done or
not done" and measures its own durations from the routine runner. A binding is also per-device
in practice, because HealthKit authorization is per-device and macOS has no HealthKit at all.

A completion the app writes after a health signal proposed it stays in the synced store. It is
the app's own record of a confirmation rather than a copy of a health sample, and that is the
line the split is drawn on.

Nothing in the framework enforces that split. An earlier version of this section claimed
SwiftData refuses to let one model type appear in two configurations. It does not. A container
built that way is accepted, and a record saved through it persists without complaint.

So the boundary is these two arrays and the tests behind them. Moving a model between them is
an App Store decision rather than a refactor, and the test that guards it has to be the kind
that would actually notice. Asserting `cloudKitContainerIdentifier == nil` does not: that
property reads `nil` for a store that does not sync and for one that syncs automatically, so
the obvious assertion stays green while the drug identifier replicates to iCloud.

### Deduplication without unique constraints

CloudKit has no unique constraints, and SwiftData rejects `@Attribute(.unique)` on a synced
model. Nothing in the storage layer can stop the same completion existing twice.

The defence runs in two places and both are needed. On write, the store collapses whatever
already carries the same content-addressed identifier. On read, the fold runs the domain's own
resolution over whatever it finds, because a write today cannot stop a peer's row arriving
tomorrow.

Both call into HabitKit rather than reimplementing the rule. Two copies of a subtle precedence
rule that have to agree forever will stop agreeing.

The rule itself has to survive being applied one record at a time. A store does not fold a set,
it folds the incoming assertion into the single row it already holds, so folding incrementally
has to give the same answer as folding everything at once. That is why the survivor is a merge
of two pairs rather than a choice between records. Status, source and `recordedAt` describe the
assertion and come from the one made last. `occurredAt` and the time zone describe the doing and
come from the earliest asserted.

Returning the earliest record whole is the obvious shortcut and it is wrong, because it carries
that record's `recordedAt` along with its `occurredAt` and winds the survivor's clock backwards.
In memory nobody notices, since nothing reads `recordedAt` after a fold. A store notices: it
resolves the next conflict against the result, so a stale retraction beats a newer completion
and the day flips to not done. Two devices receiving the same records in a different order
reached different answers and then fought over the row.

### Habits and their events are not related records

They are joined by a plain identifier instead. CloudKit does not guarantee that related
changes save atomically, so a completion can arrive before the habit it belongs to. As a flat
record that is merely early. As a relationship it would be an orphan.

A routine run and its steps are the exception and do use a relationship, because they are
written together in one save on one device and a step means nothing without its run.

### Every completion says who asserted it

A record carries whether the person ticked it or a signal proposed it. `Habit.completionSource`
cannot answer that question, because it is a mutable expectation about the habit rather than a
fact about the record, so flipping a habit to automatic would retroactively relabel every
completion ticked by hand.

The field is here now because a column added after the schema freezes leaves every record
written before it permanently unattributable. Nothing scores it, and the lock-in gate may never
read it.

### An outside signal may only fill a blank

A bounded reconciliation on launch re-reads a trailing window of HealthKit, so it repeatedly
meets days that already have an answer. It is allowed to write only where nothing has been
asserted at all.

Guarding on "no assertion" rather than "no completion" is the whole point. A retraction is an
assertion, and it is exactly the one that must survive. Without that rule a backfill arrives
with a fresh timestamp, beats the retraction on recency, and a habit the person deliberately
un-ticked ticks itself again every morning with no way to stop it.

### The watch downgrade lives in the factory

A request to sync is downgraded to a local store on watchOS by the container factory, so no
call site can opt out of it by accident. The platform is a parameter rather than a compilation
condition, which means the rule is exercised by the test suite on every run instead of only in
a build nobody runs tests against.

### The schema freezes on promotion

SwiftData has no `initializeCloudKitSchema()`. That call belongs to
`NSPersistentCloudKitContainer`, and the instruction does not carry over however often it is
repeated. SwiftData creates record types and fields lazily in the development environment as
records are saved, which has a consequence worth stating plainly.

A field exists in the schema only once a record carrying a non-nil value for it has been saved.
An optional the development build never populates is simply absent, and promoting in that state
makes it permanently absent from production, because a promoted schema accepts additions but
never renames or removals.

So `primeCloudKitSchema()` writes one record of every synced type with every field populated,
then deletes them. The deletions sync. The schema they created does not go away. Run it once
from a development build, confirm every type and field in the CloudKit dashboard, and only then
promote.

Guarding that is harder than it looks. The first attempt read its own source file and checked
that eight field names appeared somewhere in it, which passed when a field was genuinely
missing. Reflection is no help either, because a model's stored values live in its backing data
and `Mirror` reports them as absent whatever they were set to. What works is deriving the list
of optional columns from SwiftData's own schema at runtime and comparing it to an explicit
expected list. Adding an optional to a synced model then fails that comparison immediately,
which forces whoever added it to go and populate it.

Every model also carries a `schemaVersion` and a spare `payloadJSON`, because the cheapest time
to add an escape hatch is before the thing it protects is immutable.

## The app

`App/HabitPlanner.xcodeproj` holds the iOS target and its UI tests. The project uses
folder-synchronized groups, so adding a Swift file under `App/HabitPlanner/` needs no project
edit. Identifiers live in one place, `AppIdentifiers.swift`.

### The runner

A routine shows one habit at a time. Done records a completion and moves on. Skip records
nothing, so once the day settles it reads as a miss, and until then the habit can still be
ticked from the list. Back returns to the step just passed and retracts it if it was done.

Whether a step was done or skipped is not stored on the run. The completion log already
answers it, and a second copy would be one more thing that could disagree after a correction.

Completions land on the run's day, so an evening routine that runs past midnight still counts
for the evening it began. Closing mid-routine and reopening resumes at the first step not yet
passed.

### Reminders

Reminders are planned per day from each habit's schedule, 14 days ahead, and replanned every
time the app opens or a habit changes. A day with nothing due gets no reminder, and today's
drops out once the routine is finished. Reminder times are a per-device preference and live in
`UserDefaults`, not in the synced schema.

### Apple Health

A habit can be linked to a workout type or to one medication. When that habit comes up in the
runner, the app queries Health in the foreground and offers to count it. The person confirms.
On launch, a backfill proposes completions for settled days the app was never opened, capped at
seven days and never earlier than the day the link was made. It goes through `propose`, so a
day somebody un-ticked stays un-ticked.

The link itself, which for a medication names a drug, is stored only in the local health store.

## The watch

`App/HabitPlannerWatch/` is a watchOS app embedded in the iOS app. It runs routines and nothing
else. Habits are added, edited and gated on the phone.

### A replica, not a summary

The watch holds every record the phone holds, apart from Health bindings, and folds them with
the same HabitKit code. The alternative was for the phone to send a computed score and streak,
which is derived state computed on another device at another moment. The watch would show it
confidently long after it stopped being true.

### Two files, one in each direction

The phone sends a `WatchSnapshot` with every habit, completion, lifecycle event and recent run.
The watch sends a `WatchReport` with every completion and run from a window of recent days.
Both travel by `transferFile`, which queues and waits out the phone being in another room.

The plan had been `updateApplicationContext` and `transferUserInfo`. Both have undocumented
size limits, and a snapshot of every completion outgrows them within a year of daily use.
Files have no such limit. Each side cancels any transfer still waiting before it queues the
next, because the new file contains everything the old one did.

### Merging, never replacing

Neither side ever swaps its store for what arrives. It merges, through the same rules CloudKit
delivery already goes through: completions fold on `recordedAt`, lifecycle keeps the later
decision. So a snapshot built before the phone heard about a tick on the watch cannot erase
that tick, and a tick the phone has since undone arrives back as undone.

Runs merge by `RoutineRun.merged(with:)`, which keeps the earliest start and the latest end of
every step. A late copy with a step still open can therefore never reopen one the other device
closed. The cost is that an undo in the runner does not carry across to the other device's
copy of the run. The retraction it wrote does, so the habit still reads as not done everywhere.

Merging something the store already knows writes nothing. On the phone every rewritten row is a
CloudKit upload, and a report arrives after every step of a watch routine.

### Nothing the watch writes is lost on the way

The watch writes its store first and builds the report from it afterwards. The window reaches
back to yesterday, to every day with a report still waiting, and to the earliest write the
phone has not yet confirmed receiving. That last one covers the app being killed between a tick
and its report.

On the phone, a report is moved into an inbox on disk before it is read, and deleted only once
merged. One from a newer watch app waits there until the phone updates. One that can never be
read is moved aside rather than deleted.

### Demo data never crosses

Neither app activates the bridge in the in-memory debug mode. Demo habits sent to a watch would
sit in its replica for good, and anything sent back would reach CloudKit.

### Reminders

The watch schedules none of its own. The phone's reminder is forwarded to the wrist when the
phone is locked, and tapping it opens the watch runner on that routine.

## Widgets and complications

One widget, "Routine", in every family each platform supports. The iPhone gets home screen
sizes small, medium and large, and lock screen circular, rectangular and inline. The watch gets
circular, rectangular, inline and corner complications. Each shows the routine's next habit,
today's progress, how close the newest habit is to bedding in, and the habit planned for when
it does.

### A widget folds the store, it does not read a summary

The widget extension opens the shared store read only and folds it with the same HabitKit code
the app uses, through `Glance`. The app never writes anything for a widget to read. A summary
written after each reload would be derived state, and it would be wrong in exactly the cases
that matter: a change delivered by CloudKit while the app is closed, or midnight arriving with
nobody there to rewrite it.

The widget opens the synced store only. The health store is outside the App Group on purpose,
and a widget has no use for a binding. It still has to open that store with the app's whole
model, health binding included. A store file records the hashes of the model that created it,
and opening it with the synced models alone reads as a different model. Core Data then tries a
migration, which a read-only store cannot run, so the open fails.

The timeline has three entries at most: now, noon and midnight. Those are the only moments the
answer can change without a record changing. Everything else is the app asking for a reload,
and it asks only when the fold has actually changed, because reloads requested from the
background count against a daily budget.

Morning is featured until noon and evening after it. A finished morning hands over to the
evening, and a routine with nothing due gives way to one that has something. An unfinished
morning never comes back in the evening while the evening still has work, because by then it
has been missed.

### Tapping opens the runner

Widgets are read only in this phase. A tap opens the app on the runner for the routine shown,
through a `habitplanner://run/<routine>` link that carries nothing else. Ticking a habit from
the widget itself needs App Intents, which is Phase 6.

### The planned habit

A routine can hold one planned habit, the one it will add once its newest habit beds in. The
widget shows it as something to work towards, and adding a habit starts from it.

It is the smallest record that does the job: the routine, which is its identity, the title,
and `recordedAt` to decide between two devices that both wrote. A plan is cleared by writing
an empty title, never by deleting the row, which keeps the watch snapshot's promise that a
newer snapshot is always a superset of an older one. The lock-in gate never reads it.

### The watch store moved into the App Group

The complication runs in its own process and can only reach the watch's store through the
watch's App Group container. The same group identifier names a separate container on each
device, so nothing crosses between phone and watch this way. No Phase 4 build ever ran on a
real watch, so there was no old store to move.

## Getting started

```bash
cd HabitKit
swift test
```

That runs both package targets. The package has no dependencies and the suite runs in milliseconds. That speed is deliberate. It is what keeps open the option of dropping SwiftData later if the CloudKit pairing proves unworkable.

To run the app with sample data and no iCloud, enable the `-InMemoryStore` and `-SeedDemoData`
arguments in the scheme (debug builds only). The UI tests use the same arguments:

```bash
cd App
xcodebuild test -project HabitPlanner.xcodeproj -scheme HabitPlanner -destination 'platform=iOS Simulator,name=iPhone 17'
```

The watch app has its own scheme and UI tests, which run on any watch simulator:

```bash
xcodebuild test -project HabitPlanner.xcodeproj -scheme HabitPlannerWatch -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)'
```

`-LocalStore` (debug only) opens a persistent phone store that does not sync but does bridge
to the watch, for when an unsigned build cannot open the syncing one. It is only useful on
devices, for the reason in step 8 below. Widgets never see it, since it sits outside the App
Group.

`WidgetCheck` puts the widget on a simulator's home screen, checks what it shows and that a tap
opens the runner, and keeps screenshots in the result bundle. It runs the real syncing build and
edits the home screen, so it is skipped unless asked for:

```bash
TEST_RUNNER_HABIT_WIDGET_CHECK=1 xcodebuild test -project HabitPlanner.xcodeproj -scheme HabitPlanner -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HabitPlannerUITests/WidgetCheck
```

### Before the first TestFlight build

These steps touch the Apple Developer account and cannot be undone, so they are manual.

1. **Capabilities.** The App ID already has iCloud and App Groups. The first signed device build
   from Xcode will ask to add HealthKit and Push Notifications to it. Push is how CloudKit
   delivers changes from other devices.
2. **Prime the schema.** Run a Debug build on a device signed into iCloud. Open Settings,
   Developer, Prime CloudKit schema.
3. **Check the dashboard.** In the CloudKit console, development environment of
   `iCloud.org.trusler.habitplanner`, confirm the record types `CD_StoredHabit`,
   `CD_StoredCompletionEvent`, `CD_StoredLifecycleEvent`, `CD_StoredRoutineRun`,
   `CD_StoredRoutineStep` and `CD_StoredPlannedHabit` exist with every field. There must be no record type for the health
   binding.
4. **Promote** the schema to production. After this, fields can be added and never renamed or
   removed.
5. **Verify sync from a Release archive** on two devices. A Debug run is not evidence.
6. **Watch App ID.** The first signed build registers `org.trusler.habitplanner.watchkitapp`
   through automatic signing. It needs the App Group `group.org.trusler.habitplanner`, so the
   complication can read its store, and nothing else: no iCloud and no HealthKit.
7. **Widget App IDs.** `org.trusler.habitplanner.widgets` and
   `org.trusler.habitplanner.watchkitapp.widgets` each need the same App Group and nothing
   else. Then check on each device that the widget and the complication show your habits, not
   "Open the app".
8. **Verify the watch bridge on real hardware.** Run a routine on the watch with the phone in
   another room, then bring it back and check the ticks arrive on the phone and in iCloud.
   This cannot be done on simulators: the watchOS Simulator does not support `transferFile`,
   so both sides report a transfer delivered and the receiving app never hears of it. The
   bridge logs to the `org.trusler.habitplanner` subsystem, category `bridge`, on both
   devices.

## Roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | HabitKit domain package | Done |
| 2 | SwiftData persistence and CloudKit schema | Done |
| 3 | iOS app and routine runner | Built, awaiting device checks |
| 4 | watchOS app and sync bridge | Built, awaiting device checks |
| 5 | Widgets and watch complication | Built, awaiting device checks |
| 6 | App Intents, Siri, Shortcuts | |
| 7 | macOS app and reporting | |
| 8 | Lock-in ceremony and charts | |

Deferred past v1: Foundation Models summaries (Mac only), Live Activities (iPhone-initiated only, since ActivityKit has no watchOS platform), and HealthKit auto-completion.

### A note on Apple Intelligence

On-device AI runs on the Mac and nowhere else in this project. Apple Watch does not run Apple Intelligence on-device on any model, and its AI features require a paired capable iPhone. `SystemLanguageModel` has no watchOS availability at all.

The layer that does reach every device is App Intents, which predates Apple Intelligence and needs none of it. Voice-started routines, Shortcuts automation, interactive widgets, and the watch Action button all run on it. That is Phase 6, and it is the more valuable of the two.

## References

- Clear, James. *Atomic Habits*. Avery, 2018.
- Lally, P., van Jaarsveld, C. H. M., Potts, H. W. W., and Wardle, J. "How are habits formed: Modelling habit formation in the real world." *European Journal of Social Psychology*, 2010.
- [TN3163: Understanding CloudKit synchronization](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
