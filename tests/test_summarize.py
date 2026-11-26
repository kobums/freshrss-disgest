"""summarize_unread.py 의 대상 선정·커서·재시도를 네트워크 없이 확인한다.

실행: python3 -m unittest discover -s tests -v
FreshRSS·Claude·Notion 호출은 모두 가짜로 바꾼다.
"""
import contextlib
import importlib
import io
import json
import os
import sys
import tempfile
import time
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

NOW = time.time()
HOUR = 3600
DAY = 86400
READ = "user/-/state/com.google/read"


def article(name, arrived_ago, published_ago=None, read=False):
    """arrived_ago 초 전에 FreshRSS에 들어온 글."""
    arrived = NOW - arrived_ago
    published = NOW - (arrived_ago if published_ago is None else published_ago)
    return {
        "id": f"item/{name}",
        "title": name,
        "timestampUsec": str(int(arrived * 1_000_000)),
        "crawlTimeMsec": str(int(arrived * 1000)),
        "published": int(published),
        "origin": {"title": "블로그"},
        "categories": ["user/-/state/com.google/reading-list"] + ([READ] if read else []),
    }


class Pipeline:
    """가짜 FreshRSS·Claude·Notion을 물린 파이프라인 한 벌. 상태 파일은 임시 폴더에 둔다."""

    def __init__(self, folder):
        self.folder = folder
        self.articles = []
        self.fail_titles = set()
        self.fail_mark_read = False
        self.requests = 0

    def run(self, **env):
        base = {
            "FRESHRSS_BASE": "http://freshrss.test", "FRESHRSS_USER": "u",
            "FRESHRSS_API_PASSWORD": "p", "NOTION_TOKEN": "t", "CLAUDE_BIN": "python3",
            "SEEN_FILE": os.path.join(self.folder, "freshrss_digest_seen.json"),
        }
        for key in ("MAX_ITEMS", "MAX_AGE_DAYS", "MARK_READ", "DRY_RUN", "LOOKBACK_HOURS", "STATE_FILE"):
            os.environ.pop(key, None)
        os.environ.update(base)
        os.environ.update({k: str(v) for k, v in env.items()})
        sys.modules.pop("summarize_unread", None)
        m = importlib.import_module("summarize_unread")
        self.module = m
        self.summarized, self.created, self.marked = [], [], []
        self.requests = 0

        def request(url, data=None, headers=None, method=None, timeout=30):
            assert "/stream/contents/" in url, url
            self.requests += 1
            query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            assert "xt" not in query and "ot" not in query, "읽음 여부·API 시간 필터에 기대면 안 된다"
            size = int(query["n"][0])
            newest_first = sorted(self.articles, key=lambda a: -int(a["timestampUsec"]))
            if "c" in query:
                newest_first = [a for a in newest_first if int(a["timestampUsec"]) <= int(query["c"][0])]
            page, rest = newest_first[:size], newest_first[size:]
            body = {"items": page}
            if rest:
                body["continuation"] = rest[0]["timestampUsec"]
            return json.dumps(body)

        def summarize(title, source, text):
            if title in self.fail_titles:
                raise RuntimeError("요약 실패")
            self.summarized.append(title)
            return {"tags": ["개발"], "summary_line": "한 줄", "key_points": ["핵심"]}

        def mark_read(auth, token, item_id):
            if self.fail_mark_read:
                raise RuntimeError("읽음 처리 실패")
            self.marked.append(item_id)
            for a in self.articles:
                if a["id"] == item_id and READ not in a["categories"]:
                    a["categories"].append(READ)

        m._request = request
        m.greader_login = lambda: "auth"
        m.get_write_token = lambda auth: "token"
        m.mark_read = mark_read
        m.claude_summarize = summarize
        m.item_text = lambda item: "본문"
        m.notion_create = lambda title, *rest: self.created.append(title)

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            m.main()
        self.out, self.err = out.getvalue(), err.getvalue()
        return self

    def state(self):
        return self._read(self.module.STATE_FILE, {})

    def seen(self):
        return set(self._read(self.module.SEEN_FILE, []))

    @staticmethod
    def _read(path, default):
        if not os.path.exists(path):
            return default
        with open(path, encoding="utf-8") as f:
            return json.load(f)


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = Pipeline(self.tmp.name)

    def test_takes_everything_since_last_run_including_read(self):
        self.p.articles = [
            article("이틀 전", 48 * HOUR),
            article("읽은 글", 10 * HOUR, read=True),
            article("안 읽은 글", 5 * HOUR),
        ]
        self.p.run()
        # 처음에는 최근 24시간만 본다. Reeder에서 이미 읽은 글도 요약한다.
        self.assertEqual(self.p.created, ["읽은 글", "안 읽은 글"])
        self.assertEqual(self.p.marked, ["item/안 읽은 글"])  # 이미 읽은 글은 다시 읽음 처리하지 않는다

    def test_next_run_takes_only_what_arrived_in_between(self):
        self.p.articles = [article("첫날 글", 5 * HOUR)]
        self.p.run()
        self.p.articles += [article("사이에 온 글 1", 2 * HOUR, read=True), article("사이에 온 글 2", HOUR)]
        self.p.run()
        self.assertEqual(self.p.created, ["사이에 온 글 1", "사이에 온 글 2"])
        self.p.run()
        self.assertEqual(self.p.created, [])  # 새로 온 글이 없으면 아무것도 하지 않는다

    def test_cursor_covers_a_gap_of_several_days(self):
        self.p.articles = [article("첫날 글", 5 * DAY)]
        self.p.run(LOOKBACK_HOURS=24 * 6)
        # 서버가 사흘 쉬었다 돌아도 그 사이에 온 글을 모두 잡는다
        self.p.articles += [article("3일 전", 3 * DAY), article("2일 전", 2 * DAY), article("오늘", HOUR)]
        self.p.run()
        self.assertEqual(self.p.created, ["3일 전", "2일 전", "오늘"])

    def test_cap_carries_the_rest_to_the_next_run(self):
        self.p.articles = [article(f"글 {i}", (10 - i) * HOUR) for i in range(5)]
        self.p.run(MAX_ITEMS=2)
        self.assertEqual(self.p.created, ["글 0", "글 1"])  # 먼저 들어온 글부터
        self.assertIn("남은 3개는 다음 실행에서", self.p.out)
        self.p.run(MAX_ITEMS=2)
        self.assertEqual(self.p.created, ["글 2", "글 3"])
        self.p.run(MAX_ITEMS=2)
        self.assertEqual(self.p.created, ["글 4"])

    def test_pages_through_a_long_window(self):
        self.p.articles = [article(f"글 {i:03d}", (200 - i) * 60) for i in range(130)]
        self.p.run(MAX_ITEMS=500)
        self.assertEqual(len(self.p.created), 130)
        self.assertEqual(self.p.created, sorted(self.p.created))
        self.assertGreaterEqual(self.p.requests, 3)

    def test_old_articles_are_not_summarized(self):
        # 주소 이전: 옛 글이 '방금 들어온 글'로 다시 온다
        self.p.articles = [
            article("2017년 글", 3 * HOUR, published_ago=3000 * DAY),
            article("31일 전 글", 2 * HOUR, published_ago=31 * DAY),
            article("어제 글", HOUR, published_ago=DAY),
        ]
        self.p.run()
        self.assertEqual(self.p.created, ["어제 글"])
        self.assertEqual(len(self.p.marked), 3)  # 오래된 글도 Reeder에서는 비운다
        self.p.run()
        self.assertEqual(self.p.created, [])

    def test_old_articles_do_not_use_up_the_cap(self):
        self.p.articles = [article(f"옛 글 {i}", (20 - i) * HOUR, published_ago=400 * DAY) for i in range(5)]
        self.p.articles += [article("새 글 1", 2 * HOUR), article("새 글 2", HOUR)]
        self.p.run(MAX_ITEMS=2)
        self.assertEqual(self.p.created, ["새 글 1", "새 글 2"])

    def test_failed_article_is_retried_without_duplicating_others(self):
        self.p.articles = [article("앞 글", 3 * HOUR), article("실패하는 글", 2 * HOUR), article("뒷 글", HOUR)]
        self.p.fail_titles = {"실패하는 글"}
        self.p.run()
        self.assertEqual(self.p.created, ["앞 글", "뒷 글"])
        self.p.fail_titles = set()
        self.p.run()
        self.assertEqual(self.p.created, ["실패하는 글"])  # 뒷 글은 다시 요약하지 않는다
        self.p.run()
        self.assertEqual(self.p.created, [])

    def test_gives_up_after_repeated_failures(self):
        self.p.articles = [article("늘 실패하는 글", 2 * HOUR), article("멀쩡한 글", HOUR)]
        self.p.fail_titles = {"늘 실패하는 글"}
        self.p.run()
        self.p.run()
        self.assertNotIn("포기", self.p.err)
        self.p.run()
        self.assertIn("포기", self.p.err)
        self.p.fail_titles = set()
        self.p.run()
        self.assertEqual(self.p.created, [])  # 포기한 글이 커서를 붙잡지 않는다
        self.assertEqual(self.p.state()["failures"], {})

    def test_mark_read_failure_does_not_cause_a_second_summary(self):
        self.p.articles = [article("글", HOUR)]
        self.p.fail_mark_read = True
        self.p.run()
        self.assertEqual(self.p.created, ["글"])
        self.assertIn("읽음 처리 실패", self.p.err)
        self.p.run()
        self.assertEqual(self.p.created, [])

    def test_mark_read_off_still_remembers_progress(self):
        self.p.articles = [article("글", HOUR)]
        self.p.run(MARK_READ=0)
        self.assertEqual((self.p.created, self.p.marked), (["글"], []))
        self.p.run(MARK_READ=0)
        self.assertEqual(self.p.created, [])

    def test_dry_run_changes_nothing(self):
        self.p.articles = [article("글", HOUR), article("옛 글", HOUR, published_ago=90 * DAY)]
        self.p.run(DRY_RUN=1)
        self.assertEqual((self.p.created, self.p.marked), ([], []))
        self.assertEqual((self.p.state(), self.p.seen()), ({}, set()))
        self.assertIn("요약할 글 1개, 오래돼서 건너뛸 글 1개", self.p.out)
        self.p.run()
        self.assertEqual(self.p.created, ["글"])

    def test_already_summarized_articles_are_skipped_on_first_run(self):
        # 방식을 바꾸는 첫 실행: 예전 방식으로 이미 요약한 글(seen)은 다시 하지 않는다
        self.p.articles = [article("이미 요약한 글", 20 * HOUR, read=True), article("새 글", HOUR)]
        with open(os.path.join(self.tmp.name, "freshrss_digest_seen.json"), "w", encoding="utf-8") as f:
            json.dump(["item/이미 요약한 글"], f)
        self.p.run()
        self.assertEqual(self.p.created, ["새 글"])

    def test_state_file_sits_next_to_seen_file(self):
        self.p.run()
        self.assertEqual(self.p.module.STATE_FILE, os.path.join(self.tmp.name, "freshrss_digest_state.json"))
        self.assertGreater(self.p.state()["cursor_usec"], 0)


if __name__ == "__main__":
    unittest.main()
