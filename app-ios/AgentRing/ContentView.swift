import SwiftUI
import AgentRingCore

private enum RingStyle {
    static let accent = Color(red: 0.12, green: 0.44, blue: 0.34)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var calls: CallManager
    @State private var selectedTab = 0
    @State private var showCall = false
    @State private var scanner = false
    @State private var manualPairing = false
    @State private var qr = ""
    @State private var confirmUnpair = false

    init(state: AppState) { self.state = state; calls = state.calls }

    var body: some View {
        Group {
            if state.credentials != nil {
                TabView(selection: $selectedTab) {
                    conversation.tabItem { Label("Conversación", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                    history.tabItem { Label("Llamadas", systemImage: "phone") }.tag(1)
                    settings.tabItem { Label("Ajustes", systemImage: "gearshape") }.tag(2)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if calls.isBusy {
                        Button { showCall = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "phone.fill")
                                Text(calls.connectedAt == nil ? "Conectando con Leina…" : "Llamada en curso").font(.subheadline.weight(.semibold))
                                Spacer()
                                if let date = calls.connectedAt { Text(date, style: .timer).monospacedDigit() }
                                Image(systemName: "chevron.down").font(.caption.weight(.bold))
                            }.padding(.horizontal, 20).padding(.vertical, 11).foregroundStyle(.white)
                                .background(RingStyle.accent)
                        }.buttonStyle(.plain).accessibilityHint("Abrir controles de llamada")
                    }
                }
            } else { onboarding }
        }
        .tint(RingStyle.accent)
        .sheet(isPresented: $showCall) {
            ActiveCallView(manager: calls, state: state).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .onChange(of: calls.isBusy) { active in if active { showCall = true } else { showCall = false } }
        .sheet(isPresented: $scanner) {
            NavigationStack {
                QRScanner { value in scanner = false; qr = value; pair(value) }
                    .ignoresSafeArea(edges: .bottom).navigationTitle("Escanear código").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { scanner = false } } }
            }
        }
        .sheet(isPresented: $manualPairing) { pairingForm }
        .alert("No se ha podido completar", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("Aceptar") { state.error = nil }
        } message: { Text(state.error ?? "") }
        .confirmationDialog("¿Desvincular este iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Desvincular iPhone", role: .destructive) { state.run { try await state.unpair() } }
        } message: { Text("Necesitarás un nuevo código para volver a conectar. Tus mensajes permanecerán en el servidor.") }
    }

    private var conversation: some View {
        NavigationStack {
            ConversationView(state: state, calls: calls, openCall: { showCall = true })
                .navigationTitle("Leina")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { startCall() } label: { Image(systemName: "phone").font(.body.weight(.semibold)) }
                            .accessibilityLabel("Llamar a Leina").disabled(!state.agentOnline || calls.isBusy || state.busy)
                    }
                }
        }
    }

    private var history: some View {
        NavigationStack {
            List {
                Section {
                    Button { startCall() } label: {
                        HStack(spacing: 15) {
                            Image(systemName: "phone.fill").font(.title3).frame(width: 44, height: 44)
                                .foregroundStyle(.white).background(RingStyle.accent, in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Llamar a Leina").font(.headline).foregroundStyle(.primary)
                                Text(state.agentOnline ? "Habla con tu asistente" : "El asistente está desconectado")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(RingStyle.accent)
                        }.padding(.vertical, 5)
                    }.disabled(!state.agentOnline || calls.isBusy || state.busy)
                }
                Section("Recientes") {
                    if state.callHistory.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "phone.badge.waveform").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Aquí empieza la conversación").font(.headline)
                            Text("Tus llamadas con Leina aparecerán aquí.").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35).listRowBackground(Color.clear)
                    }
                    ForEach(state.callHistory) { call in CallHistoryRow(call: call) }
                }
            }.listStyle(.insetGrouped).navigationTitle("Llamadas")
                .refreshable { await refresh() }
        }
    }

    private var settings: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        LeinaMark(size: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Leina").font(.title3.weight(.semibold))
                            ConnectionStatus(connected: state.connected, online: state.agentOnline)
                        }
                    }.padding(.vertical, 8)
                }
                Section("Conexión") {
                    LabeledContent("Servidor", value: URL(string: state.credentials?.relayURL ?? "")?.host ?? "—")
                    LabeledContent("Dispositivo", value: UIDevice.current.name)
                    HStack { Text("Asistente"); Spacer(); Text(state.agentOnline ? "Disponible" : "Desconectado").foregroundStyle(.secondary) }
                }
                Section {
                    Label("Llamadas y notificaciones", systemImage: "bell.badge")
                    Text(state.pushStatus).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Abrir ajustes del iPhone") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: { Text("Permite el micrófono y las notificaciones para hablar con Leina y recibir sus llamadas.") }
                Section {
                    Label("Credenciales en el Llavero", systemImage: "lock.shield")
                    Text("La conexión está vinculada a este iPhone. No compartas tu código de enlace.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Desvincular iPhone", role: .destructive) { confirmUnpair = true }.disabled(calls.isBusy || state.busy)
                }
                Section {
                    HStack { Text("AgentRing"); Spacer(); Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")").foregroundStyle(.secondary) }
                }
            }.listStyle(.insetGrouped).navigationTitle("Ajustes")
        }
    }

    private var onboarding: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack { Text("AGENTRING").font(.caption.weight(.bold)).tracking(3); Spacer(); Image(systemName: "lock.shield").foregroundStyle(.secondary) }
                    LeinaMark(size: 100).padding(.top, 35)
                    Text("Una voz.\nSiempre cerca.").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                    Text("Habla con tu asistente, recibe sus llamadas y mantén la conversación contigo.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 18) {
                        onboardingStep("1", title: "Genera tu enlace", text: "Ejecuta agentring pair en tu ordenador.")
                        onboardingStep("2", title: "Conecta este iPhone", text: "Escanea el código QR y permite el micrófono y las notificaciones.")
                    }.padding(.vertical, 8)
                    Button { scanner = true } label: {
                        Label("Escanear código QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(state.busy)
                    Button("Introducir código manualmente") { manualPairing = true }.frame(maxWidth: .infinity)
                    Text("Tu servidor. Tu asistente. Tu conversación.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(28)
            }.background(RingStyle.background)
        }
    }

    private var pairingForm: some View {
        NavigationStack {
            Form {
                Section { TextEditor(text: $qr).font(.system(.body, design: .monospaced)).frame(minHeight: 160).autocorrectionDisabled().textInputAutocapitalization(.never) }
                    header: { Text("Código de enlace") } footer: { Text("Pega el contenido completo del código QR generado en tu ordenador.") }
                Section {
                    Button { pair(qr) } label: { HStack { Text("Conectar iPhone"); Spacer(); if state.busy { ProgressView() } } }
                        .disabled(qr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy)
                }
            }.navigationTitle("Conectar iPhone").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { manualPairing = false } } }
        }
    }
    private func onboardingStep(_ number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.subheadline.weight(.semibold)).frame(width: 28, height: 28).background(RingStyle.accent.opacity(0.12), in: Circle()).foregroundStyle(RingStyle.accent)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func pair(_ value: String) { state.run { try await state.pair(value); manualPairing = false } }
    private func startCall() { UIImpactFeedbackGenerator(style: .light).impactOccurred(); state.run { try await calls.startOutgoing() } }
    private func refresh() async { do { try await state.refresh() } catch { state.error = error.localizedDescription } }
}

private struct ConversationView: View {
    @ObservedObject var state: AppState
    @ObservedObject var calls: CallManager
    let openCall: () -> Void
    @State private var draft = ""
    @State private var replyTo: Message?
    @FocusState private var composing: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    VStack(spacing: 10) {
                        LeinaMark(size: 72)
                        Text("Tu asistente, al otro lado").font(.headline)
                        ConnectionStatus(connected: state.connected, online: state.agentOnline)
                    }.frame(maxWidth: .infinity).padding(.top, 15).padding(.bottom, 14)
                    if state.messages.isEmpty {
                        VStack(spacing: 9) {
                            Text("Empecemos a hablar").font(.title3.weight(.semibold))
                            Text("Llama a Leina o envía un mensaje.\nSus mensajes y tus respuestas aparecerán aquí.")
                                .multilineTextAlignment(.center).font(.subheadline).foregroundStyle(.secondary)
                            Button { state.run { try await calls.startOutgoing() } } label: {
                                Label("Llamar a Leina", systemImage: "phone.fill").padding(.horizontal, 15).padding(.vertical, 6)
                            }.buttonStyle(.borderedProminent).padding(.top, 8).disabled(!state.agentOnline || calls.isBusy || state.busy)
                        }.padding(.vertical, 35)
                    }
                    ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(date(message), inSameDayAs: date(state.messages[index - 1])) {
                            Text(date(message).formatted(date: .abbreviated, time: .omitted)).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                        MessageBubble(message: message).id(message.id)
                            .onAppear { Task { await state.read(message) } }
                            .contextMenu {
                                Button { replyTo = message; composing = true } label: { Label("Responder", systemImage: "arrowshape.turn.up.left") }
                                Button { UIPasteboard.general.string = message.text } label: { Label("Copiar", systemImage: "doc.on.doc") }
                            }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }.background(RingStyle.background)
                .scrollDismissesKeyboard(.interactively)
                .refreshable { do { try await state.refresh() } catch { state.error = error.localizedDescription } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.messages.count) { _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }
    private func date(_ message: Message) -> Date { Date(timeIntervalSince1970: message.created_at / 1000) }
    private var composer: some View {
        VStack(spacing: 8) {
            if let replyTo {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(RingStyle.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Responder a \(replyTo.from == "agent" ? "Leina" : "tu mensaje")").font(.caption.weight(.semibold))
                        Text(replyTo.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 32, height: 32) }.accessibilityLabel("Cancelar respuesta")
                }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Mensaje a Leina", text: $draft, axis: .vertical).lineLimit(1...5).focused($composing)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RingStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                    .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.08)) }
                    .accessibilityLabel("Mensaje a Leina")
                Button { send() } label: {
                    if state.busy { ProgressView().tint(.white).frame(width: 44, height: 44) }
                    else { Image(systemName: "arrow.up").font(.headline.weight(.bold)).frame(width: 44, height: 44) }
                }.foregroundStyle(.white).background(canSend ? RingStyle.accent : Color.secondary.opacity(0.3), in: Circle())
                    .disabled(!canSend).accessibilityLabel("Enviar mensaje")
            }
            if draft.count > 3800 { Text("\(draft.count) / 4000").font(.caption2).foregroundStyle(draft.count > 4000 ? .red : .secondary).frame(maxWidth: .infinity, alignment: .trailing) }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10).background(.bar)
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 4000 && !state.busy }
    private func send() {
        let text = draft; let replyID = replyTo?.msg_id
        state.run { try await state.send(text, replyTo: replyID); draft = ""; replyTo = nil; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}

private struct MessageBubble: View {
    let message: Message
    private var own: Bool { message.from != "agent" }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if own { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(Date(timeIntervalSince1970: message.created_at / 1000), style: .time)
                    if own { Image(systemName: message.read_at == nil ? "checkmark" : "checkmark.circle.fill") }
                }.font(.caption2).foregroundStyle(own ? Color.white.opacity(0.75) : Color.secondary)
            }.padding(.horizontal, 15).padding(.vertical, 12)
                .foregroundStyle(own ? Color.white : Color.primary)
                .background(own ? RingStyle.accent : RingStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            if !own { Spacer(minLength: 36) }
        }.accessibilityElement(children: .combine)
    }
}

private struct CallHistoryRow: View {
    let call: RelayCall
    private var missed: Bool { call.state == "missed" || call.state == "declined" || (call.answered_at == nil && call.state == "ended") }
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: call.direction == "user_to_agent" ? "phone.arrow.up.right" : "phone.arrow.down.left")
                .font(.body).foregroundStyle(missed ? Color.red : RingStyle.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(call.direction == "user_to_agent" ? "Leina" : call.agent_name).font(.body.weight(.semibold)).foregroundStyle(missed ? Color.red : Color.primary)
                Text(missed ? "Sin respuesta" : (call.direction == "user_to_agent" ? "Saliente" : "Entrante")).font(.caption).foregroundStyle(.secondary)
                if let reason = call.reason, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let created = call.created_at {
                Text(Date(timeIntervalSince1970: created / 1000), format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}

private struct ConnectionStatus: View {
    let connected: Bool
    let online: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connected && online ? RingStyle.accent : Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(!connected ? "Reconectando…" : (online ? "Disponible para hablar" : "Asistente desconectado"))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

private struct LeinaMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RingStyle.accent.opacity(0.08))
            Circle().strokeBorder(RingStyle.accent.opacity(0.14), lineWidth: 1).padding(size * 0.12)
            Image(systemName: "waveform").font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(RingStyle.accent)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct ActiveCallView: View {
    @ObservedObject var manager: CallManager
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Label("AgentRing", systemImage: "lock.fill").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Minimizar llamada")
            }
            Spacer(minLength: 16)
            LeinaMark(size: 150)
            VStack(spacing: 9) {
                Text("Leina").font(.largeTitle.weight(.semibold))
                if let date = manager.connectedAt { Text(date, style: .timer).font(.title3.monospacedDigit()).foregroundStyle(.secondary) }
                else { Text("Conectando…").font(.title3).foregroundStyle(.secondary) }
                if manager.muted { Label("Micrófono silenciado", systemImage: "mic.slash.fill").font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 30)
            HStack(alignment: .top, spacing: 35) {
                control("Silenciar", icon: manager.muted ? "mic.slash.fill" : "mic.fill", selected: manager.muted) { state.run { try await manager.toggleMute() } }
                control("Altavoz", icon: "speaker.wave.2.fill", selected: manager.speakerEnabled) { do { try manager.speaker(!manager.speakerEnabled) } catch { state.error = error.localizedDescription } }
            }
            Button { state.run { try await manager.end() } } label: {
                Image(systemName: "phone.down.fill").font(.title2).foregroundStyle(.white).frame(width: 76, height: 76).background(Color.red, in: Circle())
            }.accessibilityLabel("Finalizar llamada").padding(.top, 20)
            Text("Finalizar").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 15)
        }.padding(28).frame(maxWidth: .infinity).background(RingStyle.background)
            .onChange(of: manager.isBusy) { if !$0 { dismiss() } }
    }
    private func control(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(width: 68, height: 68)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? RingStyle.accent : RingStyle.surface, in: Circle())
                Text(title).font(.caption).foregroundStyle(.primary)
            }
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
