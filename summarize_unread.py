#!/usr/bin/env python3
"""
Reeder(안 읽은 글) → FreshRSS → claude -p 요약 → Notion → 읽음 처리

매일 새벽, 안 읽은(unread) 글을 가져와 Claude Code(`claude -p`)로 한국어 요약한 뒤
Notion 'Reeder 읽기 요약' DB에 카드로 쌓고, 처리한 글은 FreshRSS에서 읽음 처리한다.
(읽음 처리가 곧 중복 방지 — 다음 실행 때 다시 잡히지 않음)

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

MAX_ITEMS = int(os.environ.get("MAX_ITEMS", "40"))    # 한 번에 처리할 최대 개수
MARK_READ = os.environ.get("MARK_READ", "1") == "1"   # 0이면 읽음 처리 안 함(테스트용)
SEEN_FILE = os.environ.get(
    "SEEN_FILE", os.path.expanduser("~/.freshrss_digest_seen.json")
)

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


def fetch_unread(auth, n):
    """reading-list 에서 read 상태를 제외(xt) → 안 읽은 글만."""
    url = (f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/stream/contents/"
           f"{urllib.parse.quote(READING_LIST, safe='')}"
           f"?xt={urllib.parse.quote(READ_TAG, safe='')}&output=json&n={n}")
    body = _request(url, headers=greader_headers(auth))
    return json.loads(body).get("items", [])


def get_write_token(auth):
    url = f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/token"
    return _request(url, headers=greader_headers(auth)).strip()


def mark_read(auth, token, item_id):
    url = f"{FRESHRSS_BASE}/api/greader.php/reader/api/0/edit-tag"
    _request(url, data={"T": token, "i": item_id, "a": READ_TAG},
             headers=greader_headers(auth), method="POST")


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
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text)
    return text.strip()


def fetch_url_text(url):
    try:
        return html_to_text(_request(url, headers={"User-Agent": UA}))
    except Exception:
        return ""


def item_url(item):
    for key in ("canonical", "alternate"):
        arr = item.get(key) or []
        if arr and arr[0].get("href"):
            return arr[0]["href"]
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


# ── seen 파일 (읽음 처리 실패 대비 안전망) ────────────────────────
def load_seen():
    try:
        with open(SEEN_FILE, encoding="utf-8") as f:
            return set(json.load(f))
    except Exception:
        return set()


def save_seen(seen):
    try:
        with open(SEEN_FILE, "w", encoding="utf-8") as f:
            json.dump(sorted(seen), f, ensure_ascii=False)
    except Exception as e:
        print(f"경고: seen 파일 저장 실패: {e}", file=sys.stderr)


# ── 메인 ──────────────────────────────────────────────────────────
def main():
    missing = [k for k, v in {
        "FRESHRSS_BASE": FRESHRSS_BASE, "FRESHRSS_USER": FRESHRSS_USER,
        "FRESHRSS_API_PASSWORD": FRESHRSS_API_PASSWORD, "NOTION_TOKEN": NOTION_TOKEN,
    }.items() if not v]
    if missing:
        sys.exit(f"ERROR: 필수 환경변수 누락: {', '.join(missing)} (.env 확인)")
    if not shutil.which(CLAUDE_BIN):
        sys.exit(f"ERROR: '{CLAUDE_BIN}' 실행 파일을 찾을 수 없음. "
                 "Claude Code 설치 + Pro/Max 구독 로그인 후 PATH 확인.")

    auth = greader_login()
    items = fetch_unread(auth, MAX_ITEMS)
    seen = load_seen()
    todo = [it for it in items if it.get("id") not in seen]
    print(f"안 읽은 글 {len(items)}개(최대 {MAX_ITEMS}) 중 신규 {len(todo)}개 처리")

    write_token = get_write_token(auth) if (MARK_READ and todo) else None
    done = 0
    for it in todo:
        iid = it.get("id", "")
        title = it.get("title", "(제목 없음)")
        source = (it.get("origin") or {}).get("title", "")
        url = item_url(it)
        published = it.get("published")
        date_iso = (datetime.date.fromtimestamp(published).isoformat()
                    if published else datetime.date.today().isoformat())
        try:
            summary = claude_summarize(title, source, item_text(it))
            notion_create(title, source, url, date_iso,
                          summary["tags"], summary["summary_line"],
                          summary["key_points"])
            # MARK_READ=0(테스트)일 땐 seen 에 기록하지 않는다 →
            # 실제 실행(MARK_READ=1) 때 그 글들을 다시 처리해 읽음으로 넘길 수 있게.
            if MARK_READ:
                if write_token:
                    mark_read(auth, write_token, iid)
                seen.add(iid)
            done += 1
            print(f"  ✅ {title}")
        except urllib.error.HTTPError as e:
            print(f"  ❌ {title} — HTTP {e.code}: "
                  f"{e.read().decode('utf-8', 'replace')[:300]}", file=sys.stderr)
        except Exception as e:
            print(f"  ❌ {title} — {e}", file=sys.stderr)

    if MARK_READ:
        save_seen(seen)
    print(f"완료: {done}개 노션에 추가" + (", 읽음 처리됨" if MARK_READ else ""))


if __name__ == "__main__":
    main()
