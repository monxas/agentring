import SwiftUI
import AgentRingCore

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var qr = ""
    @State private var scanner = false
    @State private var draft = ""
    @State private var replyTo: Message?
    @State private var confirmUnpair = false
    var body: some View {
        NavigationStack {
            Group {
                if let credentials = state.credentials {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Circle().fill(state.connected ? .green : .orange).frame(width: 7, height: 7)
                            Text(state.connected ? (state.agentOnline ? "Agent online" : "Agent offline") : "Reconnecting…")
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary).padding()
                        CallControls(manager: state.calls, state: state)
                        ScrollViewReader { proxy in
                            List(state.messages) { message in
                                VStack(alignment: message.from == "agent" ? .leading : .trailing, spacing: 6) {
                                    Text(message.from == "agent" ? credentials.agent_name : "You")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.text).textSelection(.enabled)
                                    Text(Date(timeIntervalSince1970: message.created_at / 1000), style: .time)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: message.from == "agent" ? .leading : .trailing)
                                .padding(.vertical, 6).id(message.id)
                                .onAppear { Task { await state.read(message) } }
                                .contextMenu { Button("Reply") { replyTo = message } }
                            }
                            .listStyle(.plain)
                            .overlay { if state.messages.isEmpty { Text("Messages from your agents will appear here.").foregroundStyle(.secondary).padding() } }
                            .onChange(of: state.messages.count) { _ in if let last = state.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                            .refreshable { do { try await state.refresh() } catch { state.error = error.localizedDescription } }
                        }
                        if let replyTo {
                            HStack { Text("Replying to: \(replyTo.text)").lineLimit(1).font(.caption); Spacer(); Button("Cancel") { self.replyTo = nil } }.padding(.horizontal)
                        }
                        HStack(alignment: .bottom) {
                            TextField("Message your agent", text: $draft, axis: .vertical).lineLimit(1...5)
                                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            Button { let text = draft; let id = replyTo?.msg_id; state.run { try await state.send(text, replyTo: id); draft = ""; replyTo = nil } }
                                label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 4000 || state.busy)
                        }.padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Text(credentials.relayURL)
                                Text(state.pushStatus)
                                Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                                Button("Unpair iPhone", role: .destructive) { confirmUnpair = true }.disabled(state.calls.isBusy)
                            } label: { Image(systemName: "gearshape") }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Image(systemName: "phone.connection.fill").font(.system(size: 52)).foregroundStyle(.tint).padding(.top, 35)
                            Text("Your agents.\nOne call away.").font(.largeTitle.bold())
                            Text("Run ‘agentring pair’ on your computer, then scan its QR code to connect this iPhone.").foregroundStyle(.secondary)
                            Button { scanner = true } label: { Label("Scan pairing QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent)
                            Text("Or paste the QR payload").font(.headline)
                            TextEditor(text: $qr).font(.system(.caption, design: .monospaced)).frame(height: 120)
                                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            Button("Pair iPhone") { pair(qr) }.buttonStyle(.bordered).disabled(qr.isEmpty || state.busy)
                            Text("Microphone and notification access enable voice calls and messages. Incoming calls use the iPhone’s call screen.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(24)
                    }
                }
            }
            .navigationTitle("agentring")
            .sheet(isPresented: $scanner) { QRScanner { value in scanner = false; qr = value; pair(value) } }
            .alert("agentring", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
                Button("OK") { state.error = nil }
            } message: { Text(state.error ?? "") }
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { state.run { try await state.unpair() } }
            }
            .overlay { if state.busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
    }
    private func pair(_ value: String) { state.run { try await state.pair(value) } }
}

private struct CallControls: View {
    @ObservedObject var manager: CallManager
    @ObservedObject var state: AppState
    @State private var speaker = false
    var body: some View {
        HStack {
            if manager.isBusy {
                Label(manager.label, systemImage: "waveform").font(.subheadline).lineLimit(1)
                Spacer()
                Button { state.run { try await manager.toggleMute() } } label: { Image(systemName: manager.muted ? "mic.slash.fill" : "mic.fill") }.accessibilityLabel("Mute microphone")
                Button { do { try manager.speaker(!speaker); speaker.toggle() } catch { state.error = error.localizedDescription } } label: { Image(systemName: speaker ? "speaker.wave.3.fill" : "speaker") }.accessibilityLabel("Speaker")
                Button { state.run { try await manager.end() } } label: { Image(systemName: "phone.down.fill").foregroundStyle(.red) }.accessibilityLabel("Hang up")
            } else {
                Button { state.run { try await manager.startOutgoing() } } label: { Label("Call agent", systemImage: "phone.fill").frame(maxWidth: .infinity) }
                    .disabled(!state.agentOnline || state.busy)
            }
        }.buttonStyle(.bordered).padding(.horizontal).padding(.bottom, 10)
    }
}
