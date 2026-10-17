import SwiftUI

struct ContentView: View {
    @State private var engine = SyncEngine.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var settings = SyncSettings.load()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("Logo")
                            .resizable()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NAS Sync").font(.headline)
                            Text("Videos → TrueNAS").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    statusRow
                    if engine.isRunning {
                        Button("Stop", role: .destructive) { engine.cancel() }
                    } else {
                        Button {
                            engine.syncFromForeground()
                        } label: {
                            Label("Sync Now", systemImage: "arrow.up.circle.fill")
                        }
                        .disabled(!settings.isConfigured)
                    }
                }

                Section("Library") {
                    LabeledContent("Waiting to sync", value: engine.pendingCount.map(String.init) ?? "–")
                    LabeledContent("On the NAS", value: "\(engine.syncedCount)")
                    if settings.deleteAfterUpload && engine.awaitingDeletion > 0 {
                        LabeledContent("Synced, still on iPhone", value: "\(engine.awaitingDeletion)")
                        Button {
                            Task { await engine.removeSyncedFromPhone(force: true) }
                        } label: {
                            Label(engine.isDeleting ? "Verifying on NAS…" : "Remove from iPhone", systemImage: "trash")
                        }
                        .disabled(engine.isDeleting || engine.isRunning)
                    }
                    LabeledContent("Destination", value: destination)
                }

                Section("Last run") {
                    if let lastRun = engine.lastRun {
                        LabeledContent("When", value: lastRun.formatted(date: .abbreviated, time: .shortened))
                        if let trigger = engine.lastTrigger {
                            LabeledContent("Trigger", value: trigger.rawValue)
                        }
                    }
                    Text(engine.lastSummary ?? "Never synced")
                        .foregroundStyle(.secondary)
                }

                Section("Autotransfer") {
                    triggerRow("When charging", on: settings.chargingTriggerEnabled, icon: "bolt.fill")
                    triggerRow("When arriving home", on: settings.locationTriggerEnabled, icon: "house.fill")
                    Text("Add a Shortcuts automation with the \"Transfer New Videos to NAS\" action to also run on joining your Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NAS Sync")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings, onDismiss: reload) {
                SettingsView()
            }
            .task {
                if !settings.isConfigured { showSettings = true }
                _ = await VideoLibrary.requestAccess()
                await engine.refreshCounts()
            }
            .refreshable { await engine.refreshCounts() }
            .onChange(of: scenePhase) { _, phase in
                // Background uploads can't delete; finish that the next time the app is opened.
                if phase == .active {
                    Task {
                        await engine.refreshCounts()
                        await engine.removeSyncedFromPhone()
                    }
                }
            }
        }
    }

    private var destination: String {
        let folder = settings.baseFolder.isEmpty ? "" : "/\(settings.baseFolder)"
        return "\\\\\(settings.host)\\\(settings.share)\(folder)"
    }

    @ViewBuilder
    private var statusRow: some View {
        switch engine.phase {
        case .idle:
            Label(engine.isRunning ? "Starting…" : "Idle", systemImage: "checkmark.circle")
        case .preparing:
            HStack { ProgressView(); Text("Checking library…") }
        case .exporting(let name):
            HStack { ProgressView(); Text("Preparing \(name)…") }
        case .uploading(let name, let fraction):
            VStack(alignment: .leading) {
                Text("Uploading \(name)")
                ProgressView(value: fraction)
            }
        }
    }

    private func triggerRow(_ title: String, on: Bool, icon: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(on ? "On" : "Off").foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func reload() {
        settings = SyncSettings.load()
        Task { await engine.refreshCounts() }
    }
}
