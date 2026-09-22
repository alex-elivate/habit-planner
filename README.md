# Habit Planner

[![CI](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml/badge.svg)](https://github.com/alex-elivate/habit-planner/actions/workflows/ci.yml)

An Apple habit app built around morning and evening routines, following the framework in James Clear's *Atomic Habits*.

A reminder starts the routine. The app shows one habit at a time. You mark it complete and the next one appears. You can add a new habit only once the previous one has bedded in.

Most habit apps show a checklist and let you pick items in any order. That works against the point of a routine, where the sequence is what makes the behavior automatic. Sequencing is the product here.

## Status

Phase 1 of 8 is complete: the domain layer, with 62 tests. No app targets exist yet.

## Platforms

All Apple. iPhone, Apple Watch, and Mac. A web dashboard was considered and dropped in favor of a native Mac app, which covers the same reporting need and avoids reading Apple's private CloudKit schema from outside.

## Architecture

```
HabitKit          pure Swift. Domain model, scoring, rules. No SwiftData, no UI.
Persistence       SwiftData models, container config, WatchConnectivity bridge.
HabitIntents      App Intents, shared across every platform.
HabitAI           macOS only. On-device model access behind a protocol.
```

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

## Getting started

```bash
cd HabitKit
swift test
```

The package has no dependencies and the suite runs in milliseconds. That speed is deliberate. It is what keeps open the option of dropping SwiftData later if the CloudKit pairing proves unworkable.

## Roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | HabitKit domain package | Done |
| 2 | SwiftData persistence and CloudKit schema | Next |
| 3 | iOS app and routine runner | |
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
