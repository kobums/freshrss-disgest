import SafariServices
import SwiftUI

/// 앱 안에서 원문을 여는 Safari 화면. `http://` 링크도 그대로 열린다.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 시트로 띄울 원문 주소
struct WebLink: Identifiable {
    let url: URL
    var id: URL { url }

    /// Safari 화면은 http·https만 열 수 있다. 다른 주소는 nil.
    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        self.url = url
    }
}

extension View {
    /// 원문을 앱 안 Safari 시트로 띄운다
    func webSheet(_ link: Binding<WebLink?>) -> some View {
        sheet(item: link) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
    }
}

/// 상세의 한줄요약: 강조색 옅은 바탕에 왼쪽 띠
struct SummaryCallout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body.weight(.medium))
            .lineSpacing(5)
            .padding(.vertical, 12)
            .padding(.leading, 15)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10))
            .overlay(alignment: .leading) {
                Rectangle().fill(.tint).frame(width: 3)
            }
            .clipShape(.rect(cornerRadius: 10))
    }
}
