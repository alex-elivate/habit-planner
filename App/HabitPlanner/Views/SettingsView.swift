import CloudKit
import HabitKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReminderSettings.self) private var reminders
    @Environment(PhoneBridge.self) private var bridge: PhoneBridge?
    @Environment(\.dismiss) private var dismiss

    @State private var notificationsDenied = false
    @State private var iCloud: String?

    var body: some View {
        Form {
            Section {
                ForEach(RoutineSlot.allCases) { routine in
                    ReminderRow(routine: routine, denied: $notificationsDenied)
                }
            } header: {
                Text("Reminders")
            } footer: {
                if notificationsDenied {
                    Text("Notifications are off for Habit Planner. Turn them on in the Settings app.")
                        .foregroundStyle(.red)
                } else {
                    Text("Only on days something in the routine is due. Tapping one starts the routine.")
                }
            }

            Section("Sync") {
                LabeledContent("Storage", value: model.mode.syncs ? "iCloud" : "This device only (debug)")
                if model.mode.syncs {
                    LabeledContent("iCloud account", value: iCloud ?? "Checking…")
                }
                if let problem = bridge?.problem {
                    Label(problem, systemImage: "applewatch.slash")
                        .foregroundStyle(.red)
                }
            }

            Section {
                ExportRow()
            } header: {
                Text("Your data")
            } footer: {
                Text("A copy of every habit and completion, as a JSON file and a spreadsheet. Keep it somewhere outside iCloud, such as Files on this phone or another device.")
            }

            if !model.unreadable.isEmpty {
                Section {
                    ForEach(model.unreadable, id: \.self) { error in
                        Text(error.description).font(.caption.monospaced())
                    }
                } header: {
                    Text("Records this version cannot read")
                } footer: {
                    Text("They are left untouched. Updating the app on this device usually resolves it.")
                }
            }

            #if DEBUG
            DeveloperSection()
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = settings.authorizationStatus == .denied
            if model.mode.syncs { iCloud = await accountStatus() }
        }
        .onChange(of: RoutineSlot.allCases.map { "\(reminders.isEnabled($0))\(reminders.minutes(for: $0))" }) {
            Task { await ReminderScheduler.reschedule(model: model, settings: reminders) }
        }
    }

    private func accountStatus() async -> String {
        do {
            switch try await CKContainer(identifier: AppIdentifiers.cloudKitContainer).accountStatus() {
            case .available: return "Signed in"
            case .noAccount: return "Not signed in. Nothing will sync."
            case .restricted: return "Restricted"
            case .temporarilyUnavailable: return "Temporarily unavailable"
            case .couldNotDetermine: return "Unknown"
            @unknown default: return "Unknown"
            }
        } catch {
            return error.localizedDescription
        }
    }
}

/// Made when Settings opens, so the share sheet has files ready, and made again after every
/// load, since Health, iCloud or the watch can change the store while Settings is up, and
/// midnight changes the file's date.
private struct ExportRow: View {
    @Environment(AppModel.self) private var model
    @State private var files: [URL]?
    @State private var failure: String?

    var body: some View {
        // One row, so the task runs once. A Group would hand it to each child.
        VStack(alignment: .leading, spacing: 8) {
            row
        }
        .task(id: model.loads) { await prepare() }
    }

    @ViewBuilder private var row: some View {
        if let files {
            ShareLink(items: files) {
                Label("Export your data", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("export")
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Try again") { Task { await prepare() } }
        } else {
            Label("Preparing your data", systemImage: "square.and.arrow.up")
                .foregroundStyle(.secondary)
        }
    }

    private func prepare() async {
        do {
            files = try await model.exportFiles().write()
            failure = nil
        } catch {
            files = nil
            failure = "Your data could not be exported. \(error.localizedDescription)"
        }
    }
}

private struct ReminderRow: View {
    @Environment(ReminderSettings.self) private var reminders
    let routine: RoutineSlot
    @Binding var denied: Bool

    var body: some View {
        Toggle(isOn: enabled) {
            Label(routine.title, systemImage: routine.symbol)
        }
        if reminders.isEnabled(routine) {
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { reminders.isEnabled(routine) },
            set: { on in
                guard on else { reminders.setEnabled(false, for: routine); return }
                Task {
                    let granted = await ReminderScheduler.requestPermission()
                    denied = !granted
                    reminders.setEnabled(granted, for: routine)
                }
            }
        )
    }

    /// Minutes after midnight, shown as a time today.
    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: .now)
                    .addingTimeInterval(TimeInterval(reminders.minutes(for: routine) * 60))
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                reminders.setMinutes((parts.hour ?? 0) * 60 + (parts.minute ?? 0), for: routine)
            }
        )
    }
}

#if DEBUG
/// Schema priming, reachable only from a debug build.
///
/// Must run once, signed into iCloud, before the CloudKit schema is promoted to production.
/// See `CloudKitSchemaPriming` in HabitStore for why SwiftData needs this.
private struct DeveloperSection: View {
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var confirming = false

    var body: some View {
        Section {
            Button("Prime CloudKit schema") { confirming = true }
                .disabled(!model.mode.syncs)
            if let result {
                Text(result).font(.caption.monospaced())
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Writes and deletes one record of every synced type in the development environment. Then check every field in the CloudKit dashboard before promoting.")
        }
        .confirmationDialog("Prime the development schema?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Prime") {
                Task {
                    do {
                        let types = try await model.primeCloudKitSchema()
                        result = "Saved and removed: " + types.joined(separator: ", ")
                    } catch {
                        result = "Failed: \(error)"
                    }
                }
            }
        }
    }
}
#endif
