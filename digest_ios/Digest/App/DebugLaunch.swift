#if DEBUG
import Foundation

/// Debug 빌드 전용 실행 인자. 시뮬레이터에서 손으로 만들기 번거로운 상태를 바로 연다.
///
///     -notionToken <토큰> -notionDatabase <ID>   키체인에 넣고 연결 화면을 건너뛴다
///     -mockData YES                              표본 카드로 실행한다 (네트워크 없음)
///     -initialScreen detail|settings|connect     그 화면으로 바로 들어간다
///     -openCard 3                                `detail`로 열 카드의 순서 (0부터)
///     -filterTag AI  -filterSaved YES            필터가 걸린 상태로 시작한다 (-filterSource 도 있음)
///     -newSinceDays 3                            3일 전 이후에 온 요약을 "새로 온 요약"으로 본다
///     -searchText 쿠버네티스                      검색이 펼쳐진 상태로 시작한다
///     -scrollToDay 2026-11-07                    그 날짜 묶음이 맨 위에 오게 한다 (-scrollAnchor bottom 이면 맨 아래)
///     -expandDays YES                            몰린 날을 펼친 상태로 시작한다
///     -simulateNewCards YES                      (표본) 2초 뒤에 새 요약 2개가 도착한다
///     -connectToken <토큰> -connectDatabase <ID>  연결 화면 칸을 채운다. -connectSubmit YES 면 "연결"까지 누른다
///     -connectHelp YES                           연결 화면의 안내를 펼친다
///     -replaceToken YES / -confirmDisconnect YES 설정에서 그 시트·확인창을 띄운다
///     -resetState YES                            저장된 내용과 설정을 지우고 시작한다
///     -offline YES                               모든 요청이 "인터넷 연결 없음"으로 실패한다
enum DebugLaunch {
    private static let defaults = UserDefaults.standard

    static func flag(_ key: String) -> Bool {
        guard let value = defaults.string(forKey: key)?.lowercased() else { return false }
        return ["yes", "true", "1"].contains(value)
    }

    static func string(_ key: String) -> String? {
        defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var mockData: Bool { flag("mockData") }
    static var initialScreen: String? { string("initialScreen") }

    /// 모든 요청을 "인터넷 연결 없음"으로 끝내는 세션. 오프라인 화면 확인용.
    static let offlineSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private final class OfflineProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    /// 저장소를 만들기 전에 한 번 부른다
    static func prepare() {
        if flag("resetState") {
            Connection.clear()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: DiskStore.directory.path)) ?? [] {
                DiskStore.remove(name)
            }
            defaults.removeObject(forKey: SyncMeta.defaultsKey)
        }
        if let token = string("notionToken"), let database = string("notionDatabase").flatMap(Connection.databaseID(from:)) {
            Connection(token: token, databaseID: database).save()
        }
    }
}

/// 스크린샷 비교용 표본 카드. 실제 데이터의 길이 분포(제목 33자, 한줄요약 82자 안팎)를 따른다.
enum MockData {
    static func cards(now: Date = .now, calendar: Calendar = .current) -> [Card] {
        func at(_ daysAgo: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(byAdding: .hour, value: 4, to: day) ?? day
        }
        func dayString(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let dev = CardTag(name: "개발", color: "blue")
        let ai = CardTag(name: "AI", color: "purple")
        let infra = CardTag(name: "인프라", color: "red")
        let biz = CardTag(name: "비즈니스", color: "green")
        let career = CardTag(name: "커리어", color: "orange")
        let design = CardTag(name: "디자인", color: "pink")
        let etc = CardTag(name: "기타", color: "default")

        var index = 0
        func card(_ daysAgo: Int, published: String? = nil, _ title: String, _ source: String, _ tags: [CardTag], _ summary: String) -> Card {
            index += 1
            let created = at(daysAgo)
            return Card(
                id: "mock-\(index)",
                createdAt: created,
                editedAt: created,
                title: title,
                publishedDay: published ?? dayString(calendar.date(byAdding: .day, value: -1, to: created) ?? created),
                tags: tags,
                source: source,
                link: URL(string: "https://example.com/post/\(index)"),
                summary: summary,
                notionURL: nil
            )
        }

        var result = [
            card(0, "Spark Connect on Kubernetes #2: Operator로 만드는 Control Plane", "토스 기술 블로그， 토스 테크", [infra, dev, ai],
                 "토스증권이 Kubernetes 위에서 다수의 Spark Connect 서버를 안정적으로 운영하기 위해 두 계층의 Operator로 Control Plane을 구성하고, Blue-Green 교체 및 메모리 이슈 해결 과정을 소개한다."),
            card(0, "DEF CON CTF 2026 본선 참가기", "LY Corporation Tech Blog", [dev, ai, career],
                 "LY Corporation 보안팀이 연합팀의 일원으로 DEF CON CTF 2026 본선에 참가해 최종 3위를 달성한 경험과 기술적 세부사항을 공유한 참가기"),
            card(0, published: "2020-03-18", "[Svelte] Store", "Beomy RSS Feed", [dev, etc],
                 "Svelte의 내장 상태 관리 기능인 Store의 종류와 사용법을 설명한다."),
            card(1, "[ETC] 쿠버네티스(Kubernetes) 프로브와 무중단 배포", "Beomy RSS Feed", [dev, infra],
                 "쿠버네티스의 세 가지 프로브(startup/liveness/readiness)의 역할과 무중단 배포를 위한 올바른 설정 방법을 설명한다."),
            card(1, "Stepping into the Software 3.0 Era", "토스 기술 블로그， 토스 테크", [ai, dev, infra],
                 "Software 3.0 시대에 LLM 에이전트 설계는 기존 레이어드 아키텍처 원칙과 본질적으로 같다는 것을 Claude Code를 예시로 설명한 글"),
            card(3, "디자인 시스템을 다시 만들며 배운 것", "MUSINSA techblog — 무신사 테크 블로그 - Medium", [design, dev],
                 "무신사가 기존 디자인 시스템의 토큰 구조를 다시 설계하면서 겪은 시행착오와, 디자이너·개발자가 같은 이름으로 대화하게 만든 방법을 정리했다."),
            card(3, "QA는 어떻게 추측을 확신으로 바꾸었나", "우아한형제들 기술블로그", [dev, career, biz],
                 "배포 전 품질 판단을 감이 아닌 지표로 내리기 위해 QA 조직이 도입한 측정 체계와 그 결과를 소개한다."),
        ]
        // 피드를 새로 넣어 지난 글이 한꺼번에 들어온 날
        for n in 1...14 {
            result.append(card(5, published: "2019-\(String(format: "%02d", (n % 12) + 1))-10",
                               "뱅크샐러드 기술 블로그 지난 글 \(n)", "Banksalad RSS Feed", [dev, infra],
                               "새 피드를 넣으면서 한꺼번에 들어온 오래된 글이다. 하루 10개가 넘으면 접혀 보여야 한다."))
        }
        return result
    }

    /// 읽는 중에 도착하는 새 요약 (`-simulateNewCards`)
    static func arrivals(now: Date = .now) -> [Card] {
        (1...2).map { index in
            Card(
                id: "mock-new-\(index)",
                createdAt: now,
                editedAt: now,
                title: "방금 도착한 요약 \(index)",
                publishedDay: nil,
                tags: [CardTag(name: "개발", color: "blue")],
                source: "표본",
                link: nil,
                summary: "읽는 중에 새 요약이 오면 목록을 밀지 않고 위쪽 버튼으로 알린다.",
                notionURL: nil
            )
        }
    }

    /// 표본 본문. 세 번째 카드는 핵심이 없는 글(요약 파싱 실패분)을 흉내 낸다.
    static func bodies(for cards: [Card]) -> [String: CardBody] {
        let points = [
            "두 계층의 Operator(Apache Spark Operator + 자체 Tenant Operator)로 Control Plane을 구성해 서버 수십 대를 선언적으로 관리함",
            "Blue-Green 교체로 실행 중인 세션을 끊지 않고 서버를 바꾸는 절차를 자동화함",
            "드라이버 메모리가 계속 늘어나는 문제를 힙 덤프로 추적해 세션 캐시 누수를 찾아냄",
            "테넌트별 리소스 쿼터와 우선순위 클래스로 한 팀의 작업이 다른 팀을 밀어내지 않게 함",
            "운영 지표를 대시보드로 모아 교체 실패를 5분 안에 감지하도록 알림을 구성함",
        ]
        var result: [String: CardBody] = [:]
        for card in cards where card.id != "mock-3" {
            var blocks = [CardBody.Block(kind: .callout, text: card.summary)]
            blocks += points.map { CardBody.Block(kind: .bullet, text: $0) }
            result[card.id] = CardBody(cardEditedAt: card.editedAt, blocks: blocks)
        }
        result["mock-3"] = CardBody(cardEditedAt: cards.first { $0.id == "mock-3" }?.editedAt ?? .now,
                                    blocks: [CardBody.Block(kind: .callout, text: cards.first { $0.id == "mock-3" }?.summary ?? "")])
        return result
    }
}
#endif
