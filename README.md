# Habit Planner

[![CI](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml/badge.svg)](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml)

An Apple habit app built around morning and evening routines, following the framework in James Clear's *Atomic Habits*.

A reminder starts the routine. The app shows one habit at a time. You mark it complete and the next one appears. You can add a new habit only once the previous one has bedded in.

Most habit apps show a checklist and let you pick items in any order. That works against the point of a routine, where the sequence is what makes the behavior automatic. Sequencing is the product here.

## Status

Phases 1 and 2 of 8 are complete: the domain layer and the persistence layer, with 100 tests.
No app targets exist yet.

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

So the watch keeps a local store and bridges to the phone over WatchConnectivity. Completions go up through `transferUserInfo`, which queues and survives being out of range. Routine definitions and the current score come down through `updateApplicationContext`. Only the iPhone and Mac write to CloudKit.

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

SwiftData will not let one model type appear in two configurations, so the boundary is
enforced by the framework rather than by review.

### Deduplication without unique constraints

CloudKit has no unique constraints, and SwiftData rejects `@Attribute(.unique)` on a synced
model. Nothing in the storage layer can stop the same completion existing twice.

The defence runs in two places and both are needed. On write, the store collapses whatever
already carries the same content-addressed identifier. On read, the fold runs the domain's own
resolution over whatever it finds, because a write today cannot stop a peer's row arriving
tomorrow.

Both call into HabitKit rather than reimplementing the rule. Two copies of a subtle precedence
rule that have to agree forever will stop agreeing.

### Habits and their events are not related records

They are joined by a plain identifier instead. CloudKit does not guarantee that related
changes save atomically, so a completion can arrive before the habit it belongs to. As a flat
record that is merely early. As a relationship it would be an orphan.

A routine run and its steps are the exception and do use a relationship, because they are
written together in one save on one device and a step means nothing without its run.

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

Every model also carries a `schemaVersion` and a spare `payloadJSON`, because the cheapest time
to add an escape hatch is before the thing it protects is immutable.

## Getting started

```bash
cd HabitKit
swift test
```

That runs both targets. The package has no dependencies and the suite runs in milliseconds. That speed is deliberate. It is what keeps open the option of dropping SwiftData later if the CloudKit pairing proves unworkable.

## Roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | HabitKit domain package | Done |
| 2 | SwiftData persistence and CloudKit schema | Done |
| 3 | iOS app and routine runner | Next |
| 4 | watchOS app and sync bridge | |
| 5 | Widgets and watch complication | |
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
