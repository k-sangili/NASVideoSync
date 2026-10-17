import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SyncSettings.load()
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var confirmReset = false
    @State private var location = LocationTrigger.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host", text: $settings.host)
                        .keyboardType(.URL)
                    TextField("Share", text: $settings.share)
                    TextField("Folder in share", text: $settings.baseFolder)
                    TextField("Username", text: $settings.username)
                    SecureField("Password", text: $password)
                    Button(testing ? "Testing…" : "Test Connection", action: testConnection)
                        .disabled(testing || !settings.isConfigured)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("TrueNAS (SMB)")
                } footer: {
                    Text("Away from home, connect Tailscale to reach the NAS at its LAN address.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section("What to sync") {
                    Picker("Videos", selection: syncScope) {
                        Text("Entire library").tag(false)
                        Text("Only new from now on").tag(true)
                    }
                    Toggle("Year/month subfolders", isOn: $settings.subfoldersByDate)
                    Toggle("Wi-Fi only", isOn: $settings.wifiOnly)
                }

                Section {
                    Toggle("Delete from iPhone after upload", isOn: $settings.deleteAfterUpload)
                } footer: {
                    Text("Each video is re-checked on the NAS at full size first. iOS asks you to confirm, and only while the app is open, so videos uploaded in the background are removed the next time you open NAS Sync. Deleted videos stay in Recently Deleted for 30 days. With iCloud Photos on, this also removes them from iCloud and your other devices.")
                }

                Section {
                    Toggle("When charging", isOn: $settings.chargingTriggerEnabled)
                    Toggle("When arriving home", isOn: $settings.locationTriggerEnabled)
                    if settings.locationTriggerEnabled {
                        if let lat = settings.homeLatitude, let lon = settings.homeLongitude {
                            LabeledContent("Home", value: String(format: "%.4f, %.4f", lat, lon))
                        }
                        Button("Set Home to Current Location", action: setHome)
                        if !location.hasAlwaysAccess {
                            Button("Allow Location \"Always\"") { location.requestAlwaysAccess() }
                            Text("iOS only relaunches the app on arrival with \"Always\" access. If you already chose \"While Using\", change it in Settings › NAS Sync › Location.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Autotransfer")
                } footer: {
                    Text("Charging runs are the long ones (usually overnight). Arriving home gives about 30 seconds; unfinished uploads resume next time.")
                }

                Section {
                    Button("Forget Sync History", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Re-checks every video. Files already on the NAS are recognized and not uploaded again.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .confirmationDialog("Forget sync history?", isPresented: $confirmReset) {
                Button("Forget", role: .destructive) { Task { await SyncLedger.shared.reset() } }
            }
            .onAppear {
                password = Keychain.password(for: settings.username) ?? ""
            }
        }
    }

    private var syncScope: Binding<Bool> {
        Binding(
            get: { settings.syncSince != nil },
            set: { settings.syncSince = $0 ? Calendar.current.startOfDay(for: .now) : nil })
    }

    private func persist() {
        settings.save()
        Keychain.setPassword(password, for: settings.username)
    }

    private func save() {
        persist()
        if settings.locationTriggerEnabled { location.requestAlwaysAccess() }
        BackgroundScheduler.scheduleIfEnabled()
        Task {
            await location.applySettings()
            dismiss()
        }
    }

    private func testConnection() {
        persist()
        testing = true
        testResult = nil
        let settings = settings
        Task {
            do {
                let client = try NASClient(settings: settings)
                try await client.connect()
                try await client.ensureDirectory(settings.baseFolder)
                await client.disconnect()
                testResult = "Connected. \\\\\(settings.host)\\\(settings.share) is writable."
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func setHome() {
        location.requestAlwaysAccess()
        Task {
            guard let here = await location.currentLocation() else {
                testResult = nil
                return
            }
            settings.homeLatitude = here.coordinate.latitude
            settings.homeLongitude = here.coordinate.longitude
        }
    }
}
