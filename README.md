# FreshRSS(새로 들어온 글) → Claude 요약 → Notion → 읽기 요약 앱

매일 새벽, **지난 실행 뒤에 새로 들어온 글 전부**를 FreshRSS에서 가져와 Claude Code(`claude -p`, 구독)로
요약해 Notion **"Reeder 읽기 요약"** DB에 쌓는다. 읽음 여부는 따지지 않는다 — Reeder에서 먼저 읽은 글도
요약된다. (11월 9일 04시에 돌았으면 11월 10일 04시에는 그 사이에 들어온 글 전부가 대상)
처리한 글은 FreshRSS에서 **읽음 처리**해 Reeder를 비운다.
쌓인 요약은 iOS 앱 **"읽기 요약"**(`digest_ios/`)으로 폰에서 읽는다.
→ Reeder는 비워지고, 요약본이 읽는 화면이 된다.

```
매일 04:00 (서버 cron → docker run)
   └─ kobums/freshrss-digest 컨테이너 (summarize_unread.py)
        ├─ FreshRSS: 지난 실행(커서) 뒤에 들어온 글 전부 가져오기 (읽은 글 포함)
        ├─ 발행된 지 MAX_AGE_DAYS일이 넘은 글은 요약하지 않음
        ├─ claude -p: 한국어 요약 (구독 → API 과금 없음, 한 번에 MAX_ITEMS개까지)
        ├─ Notion: 카드 추가
        ├─ FreshRSS: 읽음 처리 (Reeder 비우기, MARK_READ=0이면 안 함)
        └─ /data: 커서 저장 (어디까지 처리했는지)

iPhone "읽기 요약" 앱 (digest_ios/)
   └─ Notion API를 읽기 전용으로 직접 호출 (서버 없음, 파이프라인과 독립)
        ├─ 요약 카드를 받아 기기에 저장 → 오프라인에서도 읽기
        └─ 날짜별 타임라인 · 상세(핵심) · 원문 보기 · 필터 · 검색
```

이 저장소에는 두 가지가 들어 있다.

| | 무엇 | 어디서 돈다 | 설명 |
| --- | --- | --- | --- |
| 파이프라인 | 요약해서 Notion에 쌓기 | 서버 (Docker + cron) | 아래 1~10 |
| 앱 | 쌓인 요약 읽기 | iPhone | [읽기 요약 앱](#읽기-요약-앱-ios) |

## 구성 파일
- `summarize_unread.py` — 파이프라인 메인 (표준 라이브러리만, 요약은 `claude -p` 호출)
- `tests/test_summarize.py` — 대상 선정·커서·재시도 단위 테스트 (`python3 -m unittest discover -s tests`)
- `Dockerfile` / `.dockerignore` — 배포 이미지 (`kobums/freshrss-digest`). 앱과 문서는 이미지에서 제외
- `Makefile` — 이미지 빌드·푸시 (`make release`)
- `docker-compose.yml` — 서버에 올릴 FreshRSS (요약 컨테이너와 별개)
- `crontab.example` — 새벽 4시 `docker run` 등록 예시
- `run.sh` — Docker 없이 호스트에서 직접 실행(테스트용)
- `nginx-rss.conf.example` / `.env.example`
- `digest_ios/` — iOS 앱 "읽기 요약" (SwiftUI, Xcode 프로젝트 + 단위 테스트)
- `docs/PRD.md` — 앱 기획서 (DB 실측 조사, 데이터·동기화 결정, 화면별 UI/UX, 구현 결과)

---

## 1~5. FreshRSS + Reeder 연결
1. `docker compose up -d` 로 FreshRSS 기동, `https://rss.gowoobro.com` 설치 마법사.
2. nginx + SSL (`nginx-rss.conf.example`, certbot).
3. Reeder/기존 서비스의 OPML 을 FreshRSS 로 가져오기.
4. FreshRSS `설정 > 인증`에서 **API 접근 허용**, `프로필`에서 **API 비밀번호** 설정.
5. Reeder Classic 계정 추가 → Google Reader API → `https://rss.gowoobro.com/api/greader.php`
   + 사용자명/API 비밀번호.

## 6. Claude Code 인증 토큰 (요약 엔진)
요약은 컨테이너 안의 `claude -p`가 **구독**으로 처리한다 (토큰당 API 과금 없음).
컨테이너는 `.env`의 `CLAUDE_CODE_OAUTH_TOKEN`으로 인증하므로, 토큰을 먼저 발급한다.
```bash
claude setup-token          # 출력된 sk-ant-oat01-... 토큰을 .env 에 붙여넣기
```
- 서버에 Claude Code가 없어도 됨 — **맥에서 발급한 토큰을 서버 `.env`에 넣어도** 동작한다.
- 요약 모델을 가볍게 하려면 `.env`의 `CLAUDE_MODEL` 지정 (사용량 절감).

## 7. .env 채우기
```bash
cp .env.example .env   # 값 입력
```
- `CLAUDE_CODE_OAUTH_TOKEN`: 위 `claude setup-token` 결과.
- `FRESHRSS_API_PASSWORD`: 로그인 비번이 아니라 **프로필 > 인증의 API 비밀번호**.
- `NOTION_TOKEN`: `notion.so/my-integrations`에서 통합 생성 후 Internal Integration Token.
  그리고 **"Reeder 읽기 요약" DB를 그 통합과 연결**(··· → Connections).
- `NOTION_DB_ID`는 이미 채워져 있음.
- ⚠️ `.env`는 절대 커밋·이미지 포함 금지 (`.gitignore`로 차단됨). 비밀값은 `.env`에만.

## 8. 이미지 빌드 & Docker Hub 푸시
맥(arm64)에서 빌드해 서버(amd64)에서 돌리므로 **멀티아키 빌드**를 쓴다.
```bash
make login              # Docker Hub 로그인 (1회)
make buildx-init        # 멀티아키 빌더 생성 (1회)
make TAG=v1.0.0 release  # amd64+arm64 빌드 → kobums/freshrss-digest 푸시
```
- 빌드 컨텍스트에서 `.env`는 `.dockerignore`로 제외되므로 **토큰이 이미지에 박히지 않는다.**
- `make build`(로컬 단일 아키) / `make push`(빌드+푸시) 도 있음. `make help`로 전체 확인.

## 9. 테스트 (상태 변경 없이)
처음엔 `DRY_RUN=1`로 무엇이 처리될지만 본다. 요약도, 노션 적재도, 읽음 처리도, 커서 저장도 하지 않는다.
```bash
docker run --rm --env-file .env -e DRY_RUN=1 \
  -v "$PWD/digest-data:/data" kobums/freshrss-digest:latest
```
`… 뒤에 들어온 글 N개 중 처리할 글 M개` 아래에 글마다 `📝 요약`/`⏭ 오래됨`, 들어온 시각, 읽음 여부가 찍힌다.
목록이 맞으면 `-e DRY_RUN=1`을 빼고 실행한다 → `✅ 제목` 로그가 뜨고 노션에 카드가 생긴다.
(Docker 없이 호스트에서 보려면 `DRY_RUN=1 ./run.sh`. 처음 실행은 최근 24시간을 보며 `LOOKBACK_HOURS`로 바꾼다.)

## 10. 매일 4시 자동화 (서버 cron)
```bash
crontab -e
# crontab.example 의 docker run 줄을 경로/사용자만 바꿔 추가:
# 0 4 * * * cd /home/youruser/freshrss-digest && /usr/bin/docker run --rm \
#   --env-file .env -v /home/youruser/freshrss-digest/digest-data:/data \
#   kobums/freshrss-digest:latest >> .../digest.log 2>&1
```
- Claude Code의 인세션 `/schedule`이나 클라우드 Routine은 당신 서버의 `.env`/FreshRSS에
  접근하지 못할 수 있다. 무인 4시 실행은 **서버 cron**이 가장 안정적이다.

---

## 읽기 요약 앱 (iOS)

Notion DB에 쌓인 요약을 폰에서 읽는 앱이다. 앱이 Notion API를 **읽기 전용**으로 직접 호출하므로
서버를 따로 두지 않고, 파이프라인을 고치지 않아도 지금까지 쌓인 카드가 그대로 보인다.
왜 이렇게 만들었는지와 화면 설계는 [`docs/PRD.md`](docs/PRD.md)에 있다.

### 할 수 있는 것
- **타임라인**: 요약이 만들어진 날짜별로 묶어 보여 준다. 한줄요약은 자르지 않는다.
  하루에 10개가 넘게 몰린 날은 5개만 보이고 "나머지 N개 보기"로 접힌다.
- **상세**: 한줄요약과 핵심(불릿), 원문 보기(앱 안 Safari), 이전·다음 글, 공유·요약 복사.
- **찾기**: 왼쪽 아래 필터(저장한 글만·태그·출처), 오른쪽 아래 검색(제목·요약·출처·태그·핵심).
- **저장**: 나중에 원문을 읽을 글을 표시해 둔다. 이 기기에만 저장된다.
- **오프라인**: 받은 카드와 핵심을 기기에 저장해 두므로 네트워크가 없어도 읽힌다.
- **동기화**: 앱을 열 때 바뀐 카드만 받고, 일주일에 한 번 전체를 대조해 Notion에서 지운 글을 반영한다.

### 요구 사항
- Xcode 26 이상, iOS 26 이상 (iPhone 전용, 세로 고정). 외부 SDK 없음.
- Notion 통합 토큰과 DB. 파이프라인의 `NOTION_TOKEN`·`NOTION_DB_ID`를 그대로 써도 된다.
  DB에는 아래 [노션 DB](#동작-메모)의 속성 6개가 있어야 하고, 앱은 연결할 때 이를 확인한다.

### 빌드와 설치
```bash
cd digest_ios
xcrun devicectl list devices                     # 연결된 iPhone의 UDID 확인

# 빌드 (서명 팀은 project.pbxproj의 DEVELOPMENT_TEAM을 자기 것으로 바꾼다)
xcodebuild -project Digest.xcodeproj -scheme Digest -configuration Debug \
  -destination "id=<UDID>" -derivedDataPath build -allowProvisioningUpdates build

# 설치
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/Digest.app
```

### 연결
처음 실행하면 연결 화면이 뜬다. **통합 토큰**과 **데이터베이스**(Notion 주소를 통째로 붙여도 됨)를
넣고 "연결"을 누른다. 토큰은 **기기의 키체인에만** 저장되고 저장소·앱 번들에는 들어가지 않는다.

폰에서 붙여넣기가 번거로우면 Debug 빌드를 실행 인자와 함께 한 번 실행한다(키체인에 저장됨).
```bash
set -a; . ./.env; set +a     # 저장소 루트에서. 토큰을 화면에 찍지 않는다
xcrun devicectl device process launch --device <UDID> com.gowoobro.digest -- \
  -notionToken "$NOTION_TOKEN" -notionDatabase "$NOTION_DB_ID"
```

토큰을 바꾸거나 연결을 끊는 것은 앱의 설정(제목 줄 오른쪽 톱니바퀴)에서 한다.

### 테스트
```bash
cd digest_ios
xcodebuild -project Digest.xcodeproj -scheme Digest \
  -destination "id=<시뮬레이터 UDID>" -derivedDataPath build test
```
Notion 응답을 카드로 바꾸는 부분, 날짜 묶기·접기, 필터·검색, 연결 확인을 단위 테스트한다(31개).

### Debug 전용 실행 인자
시뮬레이터에서 손으로 만들기 번거로운 상태를 바로 연다. 모두 `#if DEBUG` 안에 있어 Release에는 없다.

| 인자 | 동작 |
| --- | --- |
| `-notionToken <토큰>` `-notionDatabase <ID>` | 키체인에 넣고 연결 화면을 건너뛴다 |
| `-mockData YES` | 코드에 든 표본 카드로 실행한다 (네트워크 없음) |
| `-initialScreen detail` / `settings` / `connect` | 그 화면으로 바로 들어간다 |
| `-filterTag AI` `-searchText 쿠버네티스` | 필터·검색이 걸린 상태로 시작한다 |
| `-offline YES` | 모든 요청이 "인터넷 연결 없음"으로 실패한다 |
| `-resetState YES` | 저장된 내용과 연결을 지우고 시작한다 |

전체 목록은 `digest_ios/Digest/App/DebugLaunch.swift` 맨 위와 `docs/PRD.md` 6장에 있다.

### 앱 아이콘
기본·다크·틴티드 세 가지를 스크립트로 만든다 (Pillow 필요).
```bash
python3 digest_ios/tools/make_icon.py
```

---

## 동작 메모
- **무엇을 요약하나**: 지난 실행 뒤에 FreshRSS에 **들어온** 글 전부. 읽음 여부는 보지 않으므로
  Reeder에서 먼저 읽은 글도 요약된다. 기준은 글의 발행 시각이 아니라 FreshRSS가 그 글을 받은
  시각이라, 피드가 뒤늦게 올린 글도 빠지지 않는다.
- **커서**: 어디까지 처리했는지를 `/data/freshrss_digest_state.json`에 "마지막으로 처리한 글이
  들어온 시각"으로 적어 둔다. 서버가 며칠 쉬었다 돌아도 그 사이 글을 모두 잡는다. 이 파일이
  없으면(처음 실행) 최근 `LOOKBACK_HOURS`(기본 24)시간을 본다. 컨테이너를 새로 띄워도 남도록
  `/data`를 볼륨으로 물려야 한다.
- **중복 방지**: 처리한 글의 ID를 `/data/freshrss_digest_seen.json`에 적는다. 커서가 뒤로 물러난
  경우(아래 재시도)에도 같은 글을 두 번 요약하지 않는다.
- **실패한 글**: 요약이나 노션 적재가 실패하면 커서를 그 글 앞에 세워 두고 다음 실행에서 다시
  한다. 같은 글이 3번 실패하면 포기하고 넘어간다(로그에 `포기`).
- **읽음 처리**: `MARK_READ=1`(기본)이면 처리한 글을 FreshRSS에서 읽음으로 바꿔 Reeder를 비운다.
  대상 선정과는 무관하다. Reeder의 안 읽음 표시를 그대로 두고 싶으면 `MARK_READ=0`.
- **하루 상한**: 한 번에 `MAX_ITEMS`(기본 40)개까지만 요약한다. 넘친 글은 먼저 들어온 순서로
  다음 실행에 이어서 처리한다.
- **오래된 글 거르기**: 발행된 지 `MAX_AGE_DAYS`(기본 30)일이 넘은 글은 요약하지 않는다
  (로그에 `⏭`, 상한에 포함되지 않음). 블로그가 주소를 옮기면 FreshRSS가 예전 글 전체를 새 글로 다시
  받는데(2026-11 뱅크샐러드: 2017년 글까지 74개가 이틀에 걸쳐 다시 요약됨), 이를 막는다.
  피드를 새로 추가해 옛 글까지 요약하고 싶으면 그때만 `-e MAX_AGE_DAYS=0`으로 끈다.
  최근 30일 안의 글은 주소가 바뀌면 한 번 더 요약될 수 있다(글 ID가 새로 붙어 중복으로 못 봄).
- **비용**: `claude -p`는 구독 사용량을 쓴다(토큰당 과금 X). 단 "무제한"은 아니며 플랜
  사용량 한도에 포함된다. 새벽에 수십 개 요약은 가벼운 수준.
- **모델/비용 절감**: `.env`의 `CLAUDE_MODEL`을 가벼운 모델로 지정하면 사용량을 더 아낄 수 있다.
- **노션 DB**: `제목`(title)·`날짜`(date)·`태그`(multi-select)·`출처`(text)·`링크`(url)·
  `한줄요약`(text) 6개 속성을 그대로 사용한다. DB 스키마가 다르면 적재가 실패하니 유지할 것.
  읽기 요약 앱도 같은 속성을 읽으며, 속성이 없거나 종류가 다르면 연결 단계에서 알려 준다.
- **카드 본문**: 💡 콜아웃(한줄요약) → 불릿(핵심) → "원문 보기" 링크 순서로 쓴다. 앱의 상세 화면이
  이 불릿을 "핵심"으로 보여 준다.
- **토큰 공유**: 앱은 파이프라인과 같은 `NOTION_TOKEN`을 써도 된다. 앱은 읽는 요청만 보낸다.
  권한을 나누고 싶으면 "콘텐츠 읽기"만 가진 통합을 따로 만들어 앱에 넣는다.
- **`날짜` 속성**: 컨테이너 시간대(UTC) 기준이라 한국 시각 오전 9시 전에 발행된 글은 하루 이르게
  기록된다. 앱은 `날짜`가 아니라 카드가 만들어진 시각(기기 시간대)으로 묶는다.
