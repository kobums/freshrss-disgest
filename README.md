# Reeder(안 읽은 글) → Claude 요약 → Notion (매일 새벽 4시)

매일 새벽, **안 읽은 글**을 FreshRSS에서 가져와 Claude Code(`claude -p`, 구독)로 요약해
Notion **"Reeder 읽기 요약"** DB에 쌓고, 처리한 글은 **읽음 처리**한다.
→ Reeder는 비워지고, 노션의 요약본이 읽는 화면이 된다.

```
매일 04:00 (서버 cron → docker run)
   └─ kobums/freshrss-digest 컨테이너 (summarize_unread.py)
        ├─ FreshRSS: 안 읽은 글 가져오기 (최신 MAX_ITEMS개)
        ├─ claude -p: 한국어 요약 (구독 → API 과금 없음)
        ├─ Notion: 카드 추가
        └─ FreshRSS: 읽음 처리 (= 중복 방지)
```

## 구성 파일
- `summarize_unread.py` — 메인 (표준 라이브러리만, 요약은 `claude -p` 호출)
- `Dockerfile` / `.dockerignore` — 배포 이미지 (`kobums/freshrss-digest`)
- `Makefile` — 이미지 빌드·푸시 (`make release`)
- `docker-compose.yml` — 서버에 올릴 FreshRSS (요약 컨테이너와 별개)
- `crontab.example` — 새벽 4시 `docker run` 등록 예시
- `run.sh` — Docker 없이 호스트에서 직접 실행(테스트용)
- `nginx-rss.conf.example` / `.env.example`

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
처음엔 `MARK_READ=0`으로 읽음 처리 없이 노션 적재만 확인한다.
```bash
docker run --rm --env-file .env -e MARK_READ=0 \
  -v "$PWD/digest-data:/data" kobums/freshrss-digest:latest
```
정상이면 `안 읽은 글 N개 ... 신규 M개 처리` → `✅ 제목` 로그가 뜨고 노션에 카드가 생긴다.
확인되면 `.env`의 `MARK_READ=1`로 둔다. (Docker 없이 호스트에서 보려면 `MARK_READ=0 ./run.sh`)

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

## 동작 메모
- **중복 방지**: 요약·적재 후 그 글을 읽음 처리 → 다음 실행 땐 안 잡힘. `/data`의 seen 파일은
  읽음 처리가 실패한 글의 재적재를 막는 안전망(컨테이너 재시작에도 유지하려 볼륨 마운트).
- **백로그 폭주 방지**: `MAX_ITEMS`(기본 40)만큼만 처리. 안 읽은 글이 수백 개면 며칠에 걸쳐
  소화되고, 안정화되면 그날 들어온 새 글만 요약된다. 첫날 한 번에 비우려면 값을 크게.
- **비용**: `claude -p`는 구독 사용량을 쓴다(토큰당 과금 X). 단 "무제한"은 아니며 플랜
  사용량 한도에 포함된다. 새벽에 수십 개 요약은 가벼운 수준.
- **모델/비용 절감**: `.env`의 `CLAUDE_MODEL`을 가벼운 모델로 지정하면 사용량을 더 아낄 수 있다.
- **노션 DB**: `제목`(title)·`날짜`(date)·`태그`(multi-select)·`출처`(text)·`링크`(url)·
  `한줄요약`(text) 6개 속성을 그대로 사용한다. DB 스키마가 다르면 적재가 실패하니 유지할 것.
