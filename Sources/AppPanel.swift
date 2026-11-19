import AppKit
import AVFoundation
import SwiftUI

private enum PanelSection: String, CaseIterable {
    case record = "Record"
    case meetings = "Meetings"
    case history = "History"
    case usage = "Usage"
    case settings = "Settings"
}

struct AppPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var meetings: MeetingController
    @State private var slackTokenDraft = ""
    @State private var section: PanelSection = .record
    @State private var apiKeyDraft = ""
    @State private var billingKeyDraft = ""
    @State private var selectedItem: HistoryItem?

    var body: some View {
        VStack(spacing: 16) {
            header
            Picker("Section", selection: $section) {
                ForEach(PanelSection.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                sectionContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .padding(20)
        .frame(width: 400, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $selectedItem) { item in
            HistoryDetailView(item: item)
                .environmentObject(state)
                .environmentObject(meetings)
        }
        .onAppear { state.refreshFunctionKeyMonitor() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.40, green: 0.37, blue: 0.96))
                .frame(width: 38, height: 38)
                .background(Color(red: 0.93, green: 0.93, blue: 1.0), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalVoice").font(.headline)
                Text("Speech to text, ready when you are")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(state.isRecording ? Color.red : state.isTranscribing || state.isStartingRecording ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(state.isRecording ? "LIVE" : state.isTranscribing ? "WORKING" : state.isStartingRecording ? "STARTING" : "READY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(state.isRecording ? Color.red : state.isTranscribing || state.isStartingRecording ? Color.orange : Color.secondary)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .record: recordSection
        case .meetings: meetingsSection
        case .history: historySection
        case .usage: usageSection
        case .settings: settingsSection
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.30, green: 0.29, blue: 0.82), Color(red: 0.48, green: 0.38, blue: 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: state.isRecording ? "waveform" : "waveform.and.mic")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(state.isRecording ? "Listening to you…" : state.isTranscribing ? "Finishing your transcript…" : state.isStartingRecording ? "Starting microphone…" : "Speak naturally.\nGet clean text.")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if state.isRecording {
                        RecordingWaveform(level: state.audioLevel)
                            .frame(height: 20)
                    }
                    HStack(spacing: 10) {
                        Button(action: state.toggleRecording) {
                            Label(state.isRecording ? "Stop and copy" : state.isTranscribing ? "Transcribing…" : state.isStartingRecording ? "Starting…" : "Start recording", systemImage: state.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.24, green: 0.24, blue: 0.56))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 10)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isTranscribing || state.isStartingRecording)
                        .accessibilityHint(state.isRecording ? "Stops recording and transcribes your speech" : "Starts recording from your microphone")
                        Spacer(minLength: 0)
                        if state.functionKeyEnabled {
                            Text(state.functionKeyLastDetectedAt == nil ? "Fn listener on" : "Fn detected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.88))
                        } else {
                            Button("Enable Fn shortcut") { state.enableFunctionKey() }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(22)
            }
            .frame(height: 225)

            if !state.apiKeyConfigured {
                Button { section = .settings } label: {
                    Label("Add your Deepgram API key to get started", systemImage: "key.horizontal")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(red: 0.34, green: 0.32, blue: 0.84))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(red: 0.94, green: 0.94, blue: 1.0), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("RECENT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View all") { section = .history }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }

            if state.entries.isEmpty {
                Text("Your recordings and transcripts will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.entries.prefix(3)) { item in
                        HistoryRow(item: item) { selectedItem = item }
                        if item.id != state.entries.prefix(3).last?.id { Divider().padding(.leading, 46) }
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your recordings")
                .font(.title3.weight(.semibold))
            Text("Audio and transcripts are stored on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recordings yet").font(.subheadline.weight(.medium))
                    Text("Press Fn or start a recording to begin.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.entries) { item in
                        HistoryRow(item: item) { selectedItem = item }
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage & cost")
                .font(.title3.weight(.semibold))
            Text("Local estimates include successful recordings with a saved duration. Older recordings are not counted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                usageMetric("This month", seconds: state.trackedMonthSeconds, count: state.trackedMonthEntries.count)
                usageMetric("Tracked total", seconds: state.trackedUsageSeconds, count: state.trackedUsageEntries.count)
            }

            settingCard(title: "LocalVoice estimate", subtitle: "Nova-3 Multilingual pre-recorded rate: $0.0052/min (PAYG list price).", icon: "chart.line.uptrend.xyaxis") {
                Text("This month: \(estimatedCost(state.trackedMonthSeconds)) · total tracked: \(estimatedCost(state.trackedUsageSeconds))")
                    .font(.subheadline.weight(.semibold))
                Text("Your plan, credits, rounding, and Deepgram price changes can make the actual charge different.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("View Deepgram pricing", destination: URL(string: "https://deepgram.com/pricing")!)
                    .font(.caption)
            }

            settingCard(title: "Deepgram project balances", subtitle: "Refresh to check balances reported by Deepgram.", icon: "creditcard") {
                Button(state.isRefreshingBalances ? "Refreshing…" : "Refresh balances") {
                    state.refreshDeepgramBalances()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isRefreshingBalances || (!state.apiKeyConfigured && !state.billingKeyConfigured))

                Button("Set billing key in Settings") { section = .settings }
                    .font(.caption)
                    .buttonStyle(.plain)

                if let refreshedAt = state.balancesUpdatedAt {
                    Text("Updated \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !state.deepgramBalances.isEmpty {
                    ForEach(state.deepgramBalances) { balance in
                        HStack {
                            Text(balance.projectName).lineLimit(1)
                            Spacer()
                            Text("\(balance.amount.formatted()) \(balance.units)")
                                .fontWeight(.medium)
                        }
                        .font(.caption)
                    }
                }
                if let message = state.balanceMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The lookup needs project:read and billing:read. Deepgram’s Admin role includes these scopes. Balances are reported as outstanding, not guaranteed remaining credit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func usageMetric(_ title: String, seconds: TimeInterval, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatDuration(seconds)).font(.title3.weight(.semibold).monospacedDigit())
            Text("\(count) transcriptions").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func estimatedCost(_ seconds: TimeInterval) -> String {
        String(format: "$%.4f", seconds / 60 * DeepgramClient.nova3MultilingualRatePerMinute)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remaining) : String(format: "%d:%02d", minutes, remaining)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingCard(title: "Deepgram", subtitle: state.apiKeyConfigured ? "API key is ready" : "Add your API key to transcribe speech.", icon: "key.horizontal") {
                SecureField("Paste your Deepgram API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Deepgram API key")
                Button("Save API key") {
                    if state.saveAPIKey(apiKeyDraft) { apiKeyDraft = "" }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(state.apiKeyMessage ?? "Save stores the key in macOS Keychain; it stays hidden afterward.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            settingCard(title: "Deepgram billing key (optional)", subtitle: state.billingKeyConfigured ? "Separate billing key is saved" : "Keep billing access separate from your speech key.", icon: "creditcard") {
                SecureField("Paste a Deepgram billing API key", text: $billingKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Deepgram billing API key")
                Button("Save billing key") {
                    if state.saveBillingAPIKey(billingKeyDraft) { billingKeyDraft = "" }
                }
                .buttonStyle(.borderedProminent)
                .disabled(billingKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(state.billingKeyMessage ?? "Use a key with project:read and billing:read. Deepgram’s Admin role includes both. This key is only used when you refresh balances.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingCard(title: "Function key", subtitle: state.functionKeyEnabled ? "Listener is active; confirm it catches Fn on your Mac." : "Use Fn from any app to toggle recording.", icon: "keyboard") {
                Button(state.functionKeyEnabled ? "Retry Fn listener" : "Enable Fn shortcut") { state.enableFunctionKey() }
                    .buttonStyle(.borderedProminent)
                Button("Open Input Monitoring settings") { state.openInputMonitoringSettings() }
                    .font(.caption)
                    .buttonStyle(.plain)
                Text(state.functionKeyLastDetectedAt.map { "Last detected: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? (state.functionKeyEnabled ? "No Fn press detected yet. Press Fn once to confirm the shortcut." : "The listener has not started yet."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If LocalVoice is missing from Input Monitoring, click +, choose ~/Applications/LocalVoice.app, then switch it on. If Fn starts Dictation, change the Globe key action in Keyboard Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingCard(title: "Automatic paste", subtitle: state.autoPasteEnabled ? "Paste after successful transcriptions." : "Copy only; enable to paste into the focused app.", icon: "doc.on.clipboard") {
                Toggle("Auto-paste transcripts", isOn: Binding(
                    get: { state.autoPasteEnabled },
                    set: { state.setAutoPasteEnabled($0) }
                ))
                Text("Sends ⌘V without pressing Return. Requires macOS event-synthesis access; this is separate from Fn monitoring.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            meetingsSettingsCard

            settingCard(title: "Recognition", subtitle: "Deepgram Nova-3 with smart formatting and punctuation.", icon: "text.alignleft") {
                Text("Multilingual mode supports English and Hindi speech, including switching between them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Recordings stay local. Audio is sent to Deepgram only when transcribed.", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.13, blue: 0.24), Color(red: 0.86, green: 0.25, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: meetings.isRecording ? "record.circle" : "person.2.wave.2")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(meetings.isRecording ? (meetings.currentTitle ?? "Recording meeting") : meetings.isStarting ? "Starting…" : meetings.isProcessing ? "Transcribing meeting…" : "Record a meeting")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if meetings.isRecording {
                        Text("\(meetings.formatElapsed(meetings.elapsed)) · \(meetings.capturingSystemAudio ? "you + others" : "mic only")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Button(action: meetings.toggleManual) {
                        Label(meetings.isRecording ? "Stop and transcribe" : "Start meeting recording", systemImage: meetings.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.12, blue: 0.20))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(meetings.isStarting)
                }
                .padding(20)
            }
            .frame(height: 190)

            if let message = meetings.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if !meetings.settings.enabled {
                Button { section = .settings } label: {
                    Label("Turn on Meetings in Settings for calendar prompts and Slack", systemImage: "gearshape")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            settingCard(title: "Permissions", subtitle: "Meetings needs these once on each Mac.", icon: "lock.shield") {
                permissionRow("Calendar", granted: meetings.calendarAccess, action: meetings.requestCalendarAccess)
                permissionRow("Screen & System Audio Recording", granted: meetings.screenCaptureAccess, action: meetings.requestScreenCaptureAccess)
                Text("Screen & System Audio Recording lets LocalVoice hear the other participants. No video is saved. After allowing it, quit and reopen LocalVoice.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if meetings.settings.enabled {
                HStack {
                    Text("NEXT 36 HOURS").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { meetings.refreshAgenda() }.font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                if meetings.upcoming.isEmpty {
                    Text(meetings.calendarAccess ? "No meetings in your calendars." : "Allow Calendar access to see upcoming meetings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(meetings.upcoming.prefix(6)) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Text(event.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .frame(width: 62, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title).font(.subheadline).lineLimit(1)
                                    Text(event.account.isEmpty ? event.calendar : "\(event.calendar) · \(event.account)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if let synced = meetings.lastAgendaSync {
                    Text("Agenda synced to Slack \(synced.formatted(date: .omitted, time: .shortened)).").font(.caption2).foregroundStyle(.tertiary)
                }
                if let error = meetings.agendaSyncError {
                    Text("Agenda sync: \(error)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(name).font(.caption)
            Spacer()
            if !granted { Button("Allow", action: action).controlSize(.small) }
        }
    }

    private var meetingsSettingsCard: some View {
        settingCard(title: "Meetings", subtitle: meetings.settings.enabled ? "Calendar prompts, recording and Slack upload are on." : "Record meetings and send transcripts to Slack.", icon: "person.2.wave.2") {
            Toggle("Enable Meetings", isOn: $meetings.settings.enabled)

            Text("Slack bot token").font(.caption.weight(.semibold))
            SecureField(meetings.slackTokenConfigured ? "Saved in Keychain — paste to replace" : "xoxb-… (Helm app bot token)", text: $slackTokenDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Slack bot token")
            HStack {
                Button("Save token") { if meetings.saveSlackToken(slackTokenDraft) { slackTokenDraft = "" } }
                    .disabled(slackTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if meetings.slackTokenConfigured {
                    Button("Remove", role: .destructive) { meetings.removeSlackToken() }
                }
            }

            labeledField("Meetings channel ID (#meetings)", text: $meetings.settings.meetingsChannelID, prompt: "C0123ABCD")
            labeledField("Sync channel ID (#meetings-sync)", text: $meetings.settings.syncChannelID, prompt: "C0456EFGH")

            Picker("This Mac", selection: Binding(get: { meetings.settings.deviceType }, set: { meetings.setDeviceType($0) })) {
                Text("Personal").tag(MeetingDeviceType.personal)
                Text("Company").tag(MeetingDeviceType.company)
            }
            .pickerStyle(.segmented)
            labeledField("Device label", text: $meetings.settings.deviceLabel, prompt: meetings.settings.deviceType.defaultLabel)

            Stepper("Reminder \(meetings.settings.reminderLeadMinutes) min before", value: $meetings.settings.reminderLeadMinutes, in: 0...60)
                .font(.caption)

            Button(meetings.isTestingConnection ? "Testing…" : "Test connection") { meetings.testConnection() }
                .buttonStyle(.borderedProminent)
                .disabled(meetings.isTestingConnection || !meetings.slackTokenConfigured)
            Text(meetings.connectionMessage ?? "Test checks the token and posts this Mac’s agenda to the sync channel. Invite @Helm to both channels first.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func settingCard<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(state.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Label("Saved on this Mac", systemImage: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { state.stopForQuit(); NSApp.terminate(nil) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                Image(systemName: item.state == "Failed" ? "exclamationmark.circle" : item.isMeeting ? "person.2.wave.2" : "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.state == "Failed" ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.meeting.map { "Meeting · \($0.title) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))" } ?? item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.transcript.isEmpty ? (item.errorMessage ?? item.state) : item.transcript)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(item.transcript.isEmpty ? Color.secondary : Color.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open recording from \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .help("Open transcript and recording")
    }
}

private struct RecordingWaveform: View {
    let level: Double
    private let heights: [CGFloat] = [7, 12, 17, 10, 15, 8, 18, 11, 6]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 3, height: heights[index] * max(0.25, level))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Recording audio level")
    }
}

private struct HistoryDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var meetings: MeetingController
    @Environment(\.dismiss) private var dismiss
    let item: HistoryItem
    /// Live copy, so meeting status updates (Slack upload) show while the sheet is open.
    private var current: HistoryItem { state.entries.first { $0.id == item.id } ?? item }
    @State private var player: AVAudioPlayer?
    @State private var playbackTime = 0.0
    @State private var isPlaying = false
    @State private var playbackTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let meeting = current.meeting {
                        Label(meeting.title, systemImage: "person.2.wave.2").font(.headline)
                        Text("\(meeting.source.rawValue.capitalized) meeting · \(meeting.hasSystemAudio ? "you + others" : "mic only")\(meeting.slackStatus.map { " · " + $0 } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.createdAt.formatted(date: .complete, time: .shortened))
                        .font(item.isMeeting ? .caption : .headline)
                    Text(item.state == "Failed" ? (item.errorMessage ?? "Transcription failed") : item.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close recording details")
            }

            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play recording", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!FileManager.default.fileExists(atPath: item.audioURL.path))
                Slider(value: Binding(get: { playbackTime }, set: { value in
                    playbackTime = value
                    player?.currentTime = value
                }), in: 0...max(player?.duration ?? 0, 0.1))
                Text(formatTime(playbackTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button { state.copy(item) } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                    .disabled(item.transcript.isEmpty)
                Button { state.revealRecording(item) } label: { Label("Show audio in Finder", systemImage: "folder") }
                    .buttonStyle(.bordered)
                    .disabled(!FileManager.default.fileExists(atPath: item.audioURL.path))
                Spacer(minLength: 0)
                if let meeting = current.meeting, current.state == "Ready", meeting.jsonFilename != nil, meeting.slackPosted != true {
                    Button { meetings.retryUpload(current) } label: { Label("Send to Slack", systemImage: "paperplane") }
                        .buttonStyle(.bordered)
                }
                if item.state == "Failed" {
                    Button { state.retry(item) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(!state.apiKeyConfigured)
                }
                if item.state != "Recording" && item.state != "Transcribing" {
                    Button(role: .destructive) {
                        state.delete(item)
                        dismiss()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Delete recording and transcript")
                }
            }

            Divider()
            Text("Transcript").font(.subheadline.weight(.semibold))
            ScrollView {
                Text(item.transcript.isEmpty ? (item.errorMessage ?? "Transcript will appear here when ready.") : item.transcript)
                    .font(.body)
                    .foregroundStyle(item.transcript.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onDisappear {
            playbackTimer?.invalidate()
            player?.stop()
        }
    }

    private func togglePlayback() {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: item.audioURL)
            player?.prepareToPlay()
        }
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            playbackTimer?.invalidate()
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
            isPlaying = true
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                playbackTime = player.currentTime
                if !player.isPlaying {
                    isPlaying = false
                    playbackTimer?.invalidate()
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}
