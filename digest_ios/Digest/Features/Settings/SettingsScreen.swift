import SwiftUI

/// 설정: Notion 동기화 상태, 연결 바꾸기·끊기, 버전
struct SettingsScreen: View {
    @Environment(AppState.self) private var app

    @State private var confirmsDisconnect = false
    @State private var showsTokenSheet = false

    var body: some View {
        let store = app.cards
        let isSyncing = store.state == .syncing

        List {
            Section {
                LabeledContent("데이터베이스", value: store.meta.databaseTitle.isEmpty ? "—" : store.meta.databaseTitle)
                LabeledContent("요약", value: "\(store.cards.count)개")
                LabeledContent("핵심 받은 수") {
                    HStack(spacing: 8) {
                        if app.bodies.isPrefetching {
                            ProgressView().controlSize(.small)
                        }
                        Text("\(app.bodies.count(in: store.cards))/\(store.cards.count)")
                            .monospacedDigit()
                    }
                }
                LabeledContent("마지막 동기화", value: lastSyncText)
                action("지금 동기화", systemImage: "arrow.clockwise", isBusy: isSyncing) {
                    Task { await app.refresh() }
                }
                action("전체 다시 받기", systemImage: "arrow.triangle.2.circlepath", isBusy: isSyncing) {
                    Task { await app.refresh(full: true) }
                }
            } header: {
                Text("Notion")
            } footer: {
                if case .failed(let error) = store.state {
                    Label(error.userMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("앱을 열 때 바뀐 요약만 받고, 일주일에 한 번 전체를 대조해 Notion에서 지운 글을 반영합니다.")
                }
            }

            Section("연결") {
                action("토큰 바꾸기", systemImage: "key") {
                    showsTokenSheet = true
                }
                action("연결 끊기", systemImage: "xmark.circle", isDestructive: true) {
                    confirmsDisconnect = true
                }
                // 확인창이 이 줄에서 나오게 여기에 붙인다
                .confirmationDialog("연결을 끊을까요?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                    Button("연결 끊기", role: .destructive) { app.disconnect() }
                } message: {
                    Text("토큰과 이 기기에 받아 둔 요약, 저장 표시를 지웁니다. Notion의 글은 그대로 있습니다.")
                }
            }

            Section("정보") {
                LabeledContent("저장한 글", value: "\(app.saved.count)개")
                LabeledContent("버전", value: version)
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsTokenSheet) {
            ConnectView(mode: .replaceToken)
        }
        #if DEBUG
        .task {
            if DebugLaunch.flag("confirmDisconnect") { confirmsDisconnect = true }
            if DebugLaunch.flag("replaceToken") { showsTokenSheet = true }
        }
        #endif
    }

    /// 누르는 줄. 기본 스타일은 줄 전체를 강조색으로 칠하므로 직접 그린다.
    private func action(_ title: String, systemImage: String, isBusy: Bool = false, isDestructive: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
        .disabled(isBusy)
    }

    private var lastSyncText: String {
        guard let last = app.cards.meta.lastSyncAt else { return "아직 없음" }
        let style = Date.FormatStyle(locale: Locale(identifier: "ko_KR")).month().day().hour(.twoDigits(amPM: .omitted)).minute()
        return last.formatted(style)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
