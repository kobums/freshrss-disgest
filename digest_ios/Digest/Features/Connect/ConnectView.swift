import SwiftUI

/// Notion을 연결하는 화면. 처음 한 번 뜨고, 설정의 "토큰 바꾸기"에서도 시트로 쓴다.
struct ConnectView: View {
    enum Mode {
        case first
        case replaceToken
    }

    var mode: Mode = .first

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var database = ""
    @State private var isConnecting = false
    @State private var failure: ConnectFailure?
    @State private var showsHelp = false
    @FocusState private var focus: Field?

    private enum Field {
        case token
        case database
    }

    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .first {
                    // 제목은 목록 첫 줄. 타임라인 제목과 같은 높이·같은 왼쪽 시작점에 둔다.
                    Section {
                        ScreenTitle(title: "Notion 연결")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } footer: {
                        Text("요약이 쌓이는 Notion 데이터베이스를 읽어 옵니다. 토큰은 이 기기의 키체인에만 저장됩니다.")
                            .font(.subheadline)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
                    }
                }

                Section {
                    field("통합 토큰", text: $token) {
                        SecureField("ntn_…", text: $token)
                            .focused($focus, equals: .token)
                            .submitLabel(.next)
                            .onSubmit { focus = .database }
                    }
                    field("데이터베이스", text: $database) {
                        TextField("주소 또는 ID", text: $database)
                            .keyboardType(.URL)
                            .focused($focus, equals: .database)
                            .submitLabel(.go)
                            .onSubmit { submit() }
                    }
                } footer: {
                    if let failure {
                        Label(failure.message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }
                }

                Section {
                    DisclosureGroup("토큰은 어디서 만드나요?", isExpanded: $showsHelp) {
                        step(1, "notion.so/profile/integrations 에서 내부 통합을 만듭니다. 권한은 '콘텐츠 읽기'만 있으면 됩니다.")
                        step(2, "통합의 '내부 통합 시크릿'을 복사해 위 칸에 붙여 넣습니다. ntn_ 으로 시작합니다.")
                        step(3, "Notion에서 요약 DB를 열고 ··· → 연결에서 그 통합을 추가합니다. DB의 링크를 복사해 아래 칸에 붙여 넣습니다.")
                        Text("요약을 올리는 파이프라인의 토큰을 그대로 써도 됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode == .first ? "" : "토큰 바꾸기")
            // 큰 제목 자리를 비워 두지 않는다
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConnectChrome(isRoot: mode == .first))
            .toolbar {
                if mode == .replaceToken {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기", systemImage: "xmark") { dismiss() }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        submit()
                    } label: {
                        if isConnecting {
                            ProgressView()
                        } else {
                            Text("연결")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            .interactiveDismissDisabled(isConnecting)
            .task { prepare() }
        }
    }

    /// 이름 → 입력 칸 → 붙여넣기 버튼
    private func field(_ title: String, text: Binding<String>, @ViewBuilder input: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                input()
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            // 시스템 붙여넣기 버튼은 "붙여넣기 허용" 확인창을 띄우지 않는다
            PasteButton(payloadType: String.self) { strings in
                text.wrappedValue = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                failure = nil
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .tint(.accentColor)
        }
        .padding(.vertical, 2)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)단계. \(text)")
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isConnecting = true
        failure = nil
        Task {
            failure = await app.connect(token: token, databaseInput: database)
            isConnecting = false
            if failure == nil, mode == .replaceToken { dismiss() }
        }
    }

    private func prepare() {
        // 토큰만 바꿀 때는 지금 DB를 채워 둔다
        if mode == .replaceToken, database.isEmpty, let current = app.connection?.databaseID {
            database = current
        }
        #if DEBUG
        if let value = DebugLaunch.string("connectToken") { token = value }
        if let value = DebugLaunch.string("connectDatabase") { database = value }
        if DebugLaunch.flag("connectHelp") { showsHelp = true }
        if DebugLaunch.flag("connectSubmit") { submit() }
        #endif
    }
}

/// 처음 뜨는 연결 화면은 첫 화면 규칙(바 숨김, 제목 위 여백 없음)을 따르고, 시트로 뜰 때는 바를 둔다
private struct ConnectChrome: ViewModifier {
    let isRoot: Bool

    func body(content: Content) -> some View {
        if isRoot {
            content
                // 폼의 기본 위쪽 여백을 없애 제목이 타임라인 제목과 같은 높이에서 시작하게 한다.
                // 0으로 두어도 6pt쯤 남아서 그만큼 더 당긴다.
                .contentMargins(.top, -6, for: .scrollContent)
                .rootWithoutNavigationBar()
        } else {
            content
        }
    }
}
