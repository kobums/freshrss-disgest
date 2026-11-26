#!/usr/bin/env python3
"""
FreshRSS(새로 들어온 글) → claude -p 요약 → Notion

매일 새벽, 지난 실행 뒤에 FreshRSS에 새로 들어온 글을 읽음 여부와 상관없이 모두 가져와
Claude Code(`claude -p`)로 한국어 요약한 뒤 Notion 'Reeder 읽기 요약' DB에 카드로 쌓는다.
(11월 9일 04시에 돌았으면 11월 10일 04시에는 그 사이에 들어온 글 전부가 대상)

- 어디까지 처리했는지는 상태 파일의 "커서"(마지막으로 처리한 글이 들어온 시각)로 기억한다.
  Reeder에서 먼저 읽은 글도 빠지지 않는다.
- 발행된 지 MAX_AGE_DAYS일이 넘은 글은 요약하지 않는다.
  (블로그가 주소를 옮기면 FreshRSS가 예전 글 전체를 새 글로 다시 받기 때문)
- MARK_READ=1이면 처리한 글을 FreshRSS에서 읽음으로 바꿔 Reeder를 비운다 (대상 선정과는 무관).

특징:
- 요약은 Claude Code 구독으로 처리 → 토큰당 API 과금 없음 (구독 사용량 한도 사용)
- 표준 라이브러리만 사용 (Notion/FreshRSS는 curl 대신 urllib)
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

# ── 설정 (환경변수) ────────────────────────────────────────────────
FRESHRSS_BASE = os.environ.get("FRESHRSS_BASE", "").rstrip("/")
FRESHRSS_USER = os.environ.get("FRESHRSS_USER", "")
FRESHRSS_API_PASSWORD = os.environ.get("FRESHRSS_API_PASSWORD", "")

CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")   # Claude Code 실행 파일
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "")     # 비우면 기본 모델

NOTION_TOKEN = os.environ.get("NOTION_TOKEN", "")
NOTION_DB_ID = os.environ.get("NOTION_DB_ID", "ba591c8b4bda4127b1a75fa6dc455f85")
NOTION_VERSION = "2022-06-28"

MAX_ITEMS = int(os.environ.get("MAX_ITEMS") or "40")  # 한 번에 요약할 최대 개수 (넘치면 다음 실행으로)
MARK_READ = os.environ.get("MARK_READ", "1") == "1"   # 1이면 처리한 글을 FreshRSS에서 읽음으로 바꾼다
# 1이면 무엇을 처리할지만 보여 주고 아무것도 바꾸지 않는다 (요약·Notion·읽음 처리·상태 저장 없음)
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
# 처음 실행(커서 없음)일 때 몇 시간 전부터 들어온 글을 볼지. 그 뒤로는 커서가 기준이다.
LOOKBACK_HOURS = float(os.environ.get("LOOKBACK_HOURS") or "24")
# 발행된 지 이 일수가 넘은 글은 요약하지 않고 읽음 처리만 한다. 0이면 끈다(모든 글을 요약).
MAX_AGE_DAYS = int(os.environ.get("MAX_AGE_DAYS") or "30")
SEEN_FILE = os.environ.get(
    "SEEN_FILE", os.path.expanduser("~/.freshrss_digest_seen.json")
)
# 커서와 실패 횟수를 두는 파일. seen 파일 옆에 둔다 (Docker에서는 /data 볼륨).
STATE_FILE = os.environ.get("STATE_FILE") or os.path.join(
    os.path.dirname(SEEN_FILE),
    os.path.basename(SEEN_FILE).replace("seen", "state")
    if "seen" in os.path.basename(SEEN_FILE) else os.path.basename(SEEN_FILE) + ".state",
)

PAGE_SIZE = 50       # FreshRSS에서 한 번에 받는 글 수
MAX_PAGES = 100      # 구간이 아무리 길어도 이만큼만 넘긴다 (5,000개)
MAX_ATTEMPTS = 3     # 같은 글의 요약이 이만큼 실패하면 포기하고 넘어간다

READING_LIST = "user/-/state/com.google/reading-list"
READ_TAG = "user/-/state/com.google/read"
KNOWN_TAGS = ["개발", "AI", "디자인", "비즈니스", "인프라", "커리어", "기타"]
UA = "freshrss-digest/2.0 (+https://gowoobro.com)"


# ── 공통 HTTP ─────────────────────────────────────────────────────
def _request(url, data=None, headers=None, method=None, timeout=30):
    if isinstance(data, dict):
        data = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


# ── FreshRSS (Google Reader API) ──────────────────────────────────
def greader_login():
    url = f"{FRESHRSS_BASE}/api/greader.php/accounts/ClientLogin"
    body = _request(url, data={"Email": FRESHRSS_USER, "Passwd": FRESHRSS_API_PASSWORD})
    for line in body.splitlines():
        if line.startswith("Auth="):
            return line[len("Auth="):].strip()
    raise RuntimeError(f"FreshRSS 로그인 실패. 응답: {body[:200]}")


def greader_headers(auth):
    return {"Authorization": f"GoogleLogin auth={auth}", "User-Agent": UA}


def arrived_usec(item):
    """FreshRSS가 이 글을 받은 시각(마이크로초). 알 수 없으면 None.

    FreshRSS는 글 ID를 받은 시각으로 만들고 `timestampUsec`로 내려 준다.
    발행 시각과 달리 피드가 뒤늦게 올린 글도 '받은 때'로 잡힌다.
    """
    for key, scale in (("timestampUsec", 1), ("crawlTimeMsec", 1000)):
        try:
            value = int(item.get(key)) * scale
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return None


def is_read(item):
    return READ_TAG in (item.get("categories") or [])


def fetch_since(auth, since_usec):
    """since_usec 뒤에 FreshRSS에 들어온 글을 읽음 여부와 상관없이 모두, 들어온 순서로 돌려준다.

    API의 시간 필터(ot)는 받은 시각 기준이 아니어서 쓰지 않는다. 최신순으로 넘기며
    받은 시각을 직접 비교하고, 구간에 드는 글이 하나도 없는 쪽이 나오면 멈춘다.
    """
    base = (f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/stream/contents/"
            f"{urllib.parse.quote(READING_LIST, safe='')}?output=json&n={PAGE_SIZE}")
    found, continuation, undated = {}, None, 0
    for _ in range(MAX_PAGES):
        url = base + (f"&c={urllib.parse.quote(str(continuation), safe='')}" if continuation else "")
        data = json.loads(_request(url, headers=greader_headers(auth)))
        page = data.get("items", [])
        # 받은 시각이 없는 글은 언제 들어왔는지 알 수 없어 구간에 넣지 않는다 (FreshRSS는 늘 채워 보낸다)
        undated += sum(1 for it in page if arrived_usec(it) is None)
        fresh = [it for it in page if (arrived_usec(it) or 0) > since_usec]
        for it in fresh:
            found.setdefault(it.get("id"), it)
        continuation = data.get("continuation")
        if not fresh or not continuation:
            break
    else:
        print(f"경고: 구간이 너무 길어 최근 {MAX_PAGES * PAGE_SIZE}개까지만 봤습니다."
              " 그보다 먼저 들어온 글은 건너뜁니다.", file=sys.stderr)
    if undated:
        print(f"경고: 받은 시각이 없는 글 {undated}개는 건너뜁니다.", file=sys.stderr)
    return sorted(found.values(), key=arrived_usec)


def get_write_token(auth):
    url = f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/token"
    return _request(url, headers=greader_headers(auth)).strip()


def mark_read(auth, token, item_id):
    url = f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/edit-tag"
    _request(url, data={"T": token, "i": item_id, "a": READ_TAG},
             headers=greader_headers(auth), method="POST")


def published_time(item):
    """글의 발행 시각(초). 없거나 읽을 수 없으면 None."""
    try:
        published = float(item.get("published"))
    except (TypeError, ValueError):
        return None
    return published if published > 0 else None


def is_stale(published, now=None):
    """발행된 지 MAX_AGE_DAYS일이 넘은 글인가. 발행 시각을 모르면 새 글로 본다."""
    if MAX_AGE_DAYS <= 0 or not published:
        return False
    now = time.time() if now is None else now
    return now - published > MAX_AGE_DAYS * 86400


# ── 본문 추출 ─────────────────────────────────────────────────────
class _TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript"):
            self.skip += 1
        if tag in ("p", "br", "div", "li", "h1", "h2", "h3", "h4", "tr"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self.skip > 0:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(html):
    parser = _TextExtractor()
    try:
        parser.feed(html or "")
    except Exception:
        pass
    text = "".join(parser.parts)
    # 널 바이트·제어문자 제거 (\t \n \r 만 남김).
    # 본문에 \x00 이 있으면 claude -p 호출 시 subprocess 가
    # "embedded null byte" 로 터지므로 여기서 한 번에 거른다.
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text)
    return text.strip()


def fetch_url_text(url):
    try:
        return html_to_text(_request(url, headers={"User-Agent": UA}))
    except Exception:
        return ""


def item_url(item):
    """글의 웹 주소. 피드가 정하는 값이라 http(s)만 받는다.

    file:// 같은 주소를 받아 주면 본문을 가져올 때 서버의 파일을 읽게 되고,
    Notion은 웹 주소가 아니거나 2000자를 넘는 링크를 거절한다.
    """
    for key in ("canonical", "alternate"):
        arr = item.get(key) or []
        href = arr[0].get("href") if arr and isinstance(arr[0], dict) else None
        if (isinstance(href, str) and len(href) <= 2000
                and href.lower().startswith(("http://", "https://"))):
            return href
    return ""


def item_text(item):
    content = (item.get("content") or item.get("summary") or {}).get("content", "")
    text = html_to_text(content)
    if len(text) < 600:
        url = item_url(item)
        if url:
            fetched = fetch_url_text(url)
            if len(fetched) > len(text):
                text = fetched
    return text[:12000]


# ── Claude Code(`claude -p`) 요약 — 구독 사용 ─────────────────────
def claude_summarize(title, source, text):
    prompt = (
        "다음 글을 한국어로 요약해줘. 반드시 JSON만 출력하고 코드펜스(```)는 쓰지 마.\n"
        "형식: {\"summary_line\": \"한 줄 요약\", "
        "\"key_points\": [\"핵심 3~6개\"], "
        f"\"tags\": [\"주제 태그 2~4개, 가능하면 다음 중에서: {', '.join(KNOWN_TAGS)}\"]}}\n\n"
        f"제목: {title}\n출처: {source}\n\n본문:\n{text}"
    )
    prompt = prompt.replace("\x00", "")  # subprocess 는 인자에 널 바이트가 있으면 거부
    cmd = [CLAUDE_BIN, "-p", prompt]
    if CLAUDE_MODEL:
        cmd += ["--model", CLAUDE_MODEL]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
    if proc.returncode != 0:
        raise RuntimeError(f"claude -p 실패(코드 {proc.returncode}): "
                           f"{proc.stderr.strip()[:300]}")
    raw = proc.stdout.strip()
    raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.MULTILINE).strip()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = {"summary_line": raw[:200], "key_points": [], "tags": ["기타"]}
    data.setdefault("summary_line", "")
    data.setdefault("key_points", [])
    data.setdefault("tags", ["기타"])
    return data


# ── Notion ────────────────────────────────────────────────────────
def _rt(text):
    return [{"type": "text", "text": {"content": text[:1900]}}]


def notion_create(title, source, url, date_iso, tags, summary_line, key_points):
    children = []
    if summary_line:
        children.append({"object": "block", "type": "callout", "callout": {
            "rich_text": _rt(summary_line), "icon": {"type": "emoji", "emoji": "💡"}}})
    for kp in key_points:
        children.append({"object": "block", "type": "bulleted_list_item",
                         "bulleted_list_item": {"rich_text": _rt(str(kp))}})
    if url:
        children.append({"object": "block", "type": "paragraph", "paragraph": {
            "rich_text": [{"type": "text",
                           "text": {"content": "원문 보기", "link": {"url": url}}}]}})

    properties = {
        "제목": {"title": _rt(title or "(제목 없음)")},
        "날짜": {"date": {"start": date_iso}},
        "태그": {"multi_select": [{"name": t} for t in tags[:4]]},
    }
    if source:
        properties["출처"] = {"rich_text": _rt(source)}
    if url:
        properties["링크"] = {"url": url}
    if summary_line:
        properties["한줄요약"] = {"rich_text": _rt(summary_line)}

    payload = {
        "parent": {"database_id": NOTION_DB_ID},
        "icon": {"type": "emoji", "emoji": "📰"},
        "properties": properties,
        "children": children,
    }
    _request(
        "https://api.notion.com/v1/pages",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {NOTION_TOKEN}",
            "Notion-Version": NOTION_VERSION,
            "content-type": "application/json",
        },
        method="POST",
    )


# ── 상태 파일 ─────────────────────────────────────────────────────
# seen : 이미 처리한 글 ID. 커서가 뒤로 물러났을 때 같은 글을 두 번 요약하지 않게 한다.
# state: 커서(어디까지 처리했나)와 글마다 실패한 횟수.
def load_seen():
    value = _load_json(SEEN_FILE)
    return set(value) if isinstance(value, list) else set()


def save_seen(seen):
    return _save_json(SEEN_FILE, sorted(seen))


def load_state():
    value = _load_json(STATE_FILE)
    return value if isinstance(value, dict) else {}


def _load_json(path):
    """파일이 없으면 None. 있는데 못 읽으면 알리고 None (없는 것처럼 이어 간다)."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        print(f"경고: {path} 을 읽지 못해 없는 것으로 봅니다: {e}", file=sys.stderr)
        return None


def save_state(state):
    return _save_json(STATE_FILE, state)


def _save_json(path, value):
    """쓰다가 죽어도 파일이 깨지지 않게 옆에 쓰고 바꿔 끼운다."""
    try:
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except Exception as e:
        print(f"경고: {path} 저장 실패: {e}", file=sys.stderr)
        return False


def _when(usec):
    return datetime.datetime.fromtimestamp(usec / 1_000_000).strftime("%Y-%m-%d %H:%M")


# ── 메인 ──────────────────────────────────────────────────────────
def main():
    missing = [k for k, v in {
        "FRESHRSS_BASE": FRESHRSS_BASE, "FRESHRSS_USER": FRESHRSS_USER,
        "FRESHRSS_API_PASSWORD": FRESHRSS_API_PASSWORD, "NOTION_TOKEN": NOTION_TOKEN,
    }.items() if not v]
    if missing:
        sys.exit(f"ERROR: 필수 환경변수 누락: {', '.join(missing)} (.env 확인)")
    if not DRY_RUN and not shutil.which(CLAUDE_BIN):
        sys.exit(f"ERROR: '{CLAUDE_BIN}' 실행 파일을 찾을 수 없음. "
                 "Claude Code 설치 + Pro/Max 구독 로그인 후 PATH 확인.")

    state = load_state()
    cursor = state.get("cursor_usec")
    if isinstance(cursor, int) and cursor > 0:
        since = cursor
    else:
        since = int((time.time() - LOOKBACK_HOURS * 3600) * 1_000_000)
        print(f"저장된 커서가 없어 최근 {LOOKBACK_HOURS:g}시간을 봅니다.")
    failures = state.get("failures") if isinstance(state.get("failures"), dict) else {}

    auth = greader_login()
    items = fetch_since(auth, since)
    seen = load_seen()
    todo = [it for it in items if it.get("id") not in seen]
    print(f"{_when(since)} 뒤에 들어온 글 {len(items)}개 중 처리할 글 {len(todo)}개"
          f" (읽음 {sum(is_read(it) for it in todo)}개 포함, 한 번에 최대 {MAX_ITEMS}개 요약)")

    write_token = get_write_token(auth) if (MARK_READ and todo and not DRY_RUN) else None

    def finish(iid, was_read):
        """처리를 마친 글: 다시 잡히지 않게 기록하고, 원하면 읽음으로 바꾼다."""
        seen.add(iid)
        failures.pop(iid, None)
        save_seen(seen)
        if write_token and not was_read:
            try:
                mark_read(auth, write_token, iid)
            except Exception as e:
                # 읽음 처리는 부가 기능이다. 실패해도 요약은 끝났으니 다시 요약하지 않는다.
                print(f"  경고: 읽음 처리 실패 — {e}", file=sys.stderr)

    done = skipped = given_up = 0
    reached = since      # 여기까지는 살펴봤다
    resume_from = None   # 다음 실행이 다시 봐야 할 글(실패했거나 상한에 밀린 글) 가운데 가장 먼저 들어온 것
    has_retry = False
    left = 0
    for index, it in enumerate(todo):
        iid = it.get("id", "")
        title = it.get("title", "(제목 없음)")
        source = (it.get("origin") or {}).get("title", "")
        url = item_url(it)
        arrived = arrived_usec(it)
        published = published_time(it)
        date_iso = (datetime.date.fromtimestamp(published).isoformat()
                    if published else datetime.date.today().isoformat())
        stale = is_stale(published)

        if not stale and done >= MAX_ITEMS:
            # 오늘 몫을 다 썼다. 남은 글은 커서를 여기 세워 두고 다음 실행에서 이어 한다.
            left = sum(1 for rest in todo[index:] if not is_stale(published_time(rest)))
            resume_from = arrived if resume_from is None else min(resume_from, arrived)
            break

        if DRY_RUN:
            mark = "⏭ 오래됨" if stale else "📝 요약"
            print(f"  {mark} | 들어옴 {_when(arrived)} | 발행 {date_iso} |"
                  f" {'읽음' if is_read(it) else '안읽음'} | {source[:20]} | {title[:50]}")
            skipped, done = skipped + stale, done + (not stale)
            reached = max(reached, arrived)
            continue

        if stale:
            # 오래된 글은 요약하지 않는다 (피드 주소 이전으로 옛 글이 몰려올 때)
            finish(iid, is_read(it))
            skipped += 1
            reached = max(reached, arrived)
            print(f"  ⏭ {title} — {date_iso} 발행, {MAX_AGE_DAYS}일이 넘어 요약 안 함")
            continue

        try:
            summary = claude_summarize(title, source, item_text(it))
            notion_create(title, source, url, date_iso,
                          summary["tags"], summary["summary_line"],
                          summary["key_points"])
        except Exception as e:
            detail = (f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
                      if isinstance(e, urllib.error.HTTPError) else str(e))
            failures[iid] = int(failures.get(iid, 0)) + 1
            if failures[iid] >= MAX_ATTEMPTS:
                # 계속 실패하는 글 하나가 커서를 영영 붙잡지 않게 포기한다
                print(f"  ❌ {title} — {detail} ({MAX_ATTEMPTS}번 실패, 포기)", file=sys.stderr)
                finish(iid, True)
                given_up += 1
            else:
                print(f"  ❌ {title} — {detail} (다음 실행에서 다시 시도)", file=sys.stderr)
                resume_from = arrived if resume_from is None else min(resume_from, arrived)
                has_retry = True
            reached = max(reached, arrived)
            continue

        finish(iid, is_read(it))
        done += 1
        reached = max(reached, arrived)
        print(f"  ✅ {title}")

    if DRY_RUN:
        print(f"DRY_RUN: 요약할 글 {done}개, 오래돼서 건너뛸 글 {skipped}개"
              + (f", 다음 실행으로 넘어갈 글 {left}개" if left else "") + " — 아무것도 바꾸지 않았습니다.")
        return

    # 다시 봐야 할 글이 있으면 커서를 그 글 바로 앞에 둔다. 그 뒤의 끝난 글은 seen이 걸러 준다.
    new_cursor = reached if resume_from is None else min(reached, resume_from - 1)
    state["cursor_usec"] = max(new_cursor, since)
    state["failures"] = {k: v for k, v in failures.items() if k not in seen}
    state["last_run"] = datetime.datetime.now().isoformat(timespec="seconds")
    saved = [save_seen(seen), save_state(state)]

    print(f"완료: {done}개 노션에 추가"
          + (f" · 오래된 글 {skipped}개는 요약 안 함" if skipped else "")
          + (f" · {given_up}개는 계속 실패해 포기" if given_up else "")
          + (" · 다시 시도할 글 있음" if has_retry else "")
          + (f" · 남은 {left}개는 다음 실행에서" if left else "")
          + f" · 커서 {_when(state['cursor_usec'])}")
    if not all(saved):
        # 진행 상황을 못 남겼다. 다음 실행이 같은 글을 다시 요약할 수 있으니 실패로 끝낸다.
        sys.exit(f"ERROR: 진행 상황을 저장하지 못했습니다. {os.path.dirname(STATE_FILE)} 에 쓸 수 있는지 확인하세요.")


if __name__ == "__main__":
    main()
