import SwiftUI

/// 첫 화면의 큰 제목 줄. 내비게이션 바를 숨기고 본문·목록의 첫 줄에 둔다.
/// 오른쪽 위에 둘 것이 있으면 바를 살리지 않고 이 줄의 오른쪽에 둔다.
struct ScreenTitle<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension ScreenTitle where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// 첫 화면: 빈 내비게이션 바를 숨기고, 스크롤한 내용이 상태 표시줄 밑에서 흐려지게 한다.
    /// 스크롤 뷰(List·Form)에 바로 붙인다.
    func rootWithoutNavigationBar() -> some View {
        modifier(RootWithoutNavigationBar())
    }
}

private struct RootWithoutNavigationBar: ViewModifier {
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 제목을 상태 표시줄 바로 밑에 붙이므로, 맨 위에 멈춰 있을 때는 흐림이 제목 윗부분을 덮는다.
            // 스크롤을 시작한 뒤에만 켠다.
            .scrollEdgeEffectHidden(!isScrolled, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 2
            } action: { _, scrolled in
                isScrolled = scrolled
            }
    }
}
