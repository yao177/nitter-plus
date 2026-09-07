"""Network-free regression tests for the live API contract runner."""

import copy
from email.message import Message
import json
import unittest
from urllib.parse import parse_qs, urlsplit

from api_live_contract import ContractFailure, NoRedirect, OPERATIONS, Runner, validate_tweet


KEY = "fake-test-key-not-a-live-secret"
CURSOR = "opaque+cursor/value=:with spaces"


def user():
    return {"id": "123", "username": "NASA", "fullname": "NASA", "bio": "",
            "avatar": "https://pbs.twimg.com/profile_images/example.jpg", "banner": "#000000",
            "following": 1, "followers": 2, "posts": 3, "likes": 4,
            "joinedAt": "2000-01-01T00:00:00Z", "protected": False,
            "suspended": False, "verifiedType": None}


def tweet(identifier="100"):
    return {"id": identifier, "threadId": identifier, "replyId": "0",
            "url": f"https://x.com/NASA/status/{identifier}", "user": user(),
            "text": "public fixture", "html": "public fixture", "createdAt": "2020-01-01T00:00:00Z",
            "available": True, "stats": {"replies": 100, "retweets": 2, "likes": 3, "views": 4},
            "media": [{"type": "photo", "url": "https://pbs.twimg.com/media/example.jpg", "altText": ""}]}


def page(second=False):
    return {"items": [tweet("200" if second else "100")], "nextCursor": "" if second else CURSOR,
            "previousCursor": "", "beginning": not second}


class Response:
    def __init__(self, status, value, content_type="application/json"):
        self.status = status
        self.body = json.dumps(value).encode() if not isinstance(value, bytes) else value
        self.headers = Message()
        self.headers["Content-Type"] = content_type

    def read(self, size):
        return self.body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass


class Opener:
    def __init__(self, missing_cursor=False, failure=None):
        self.calls = []
        self.missing_cursor = missing_cursor
        self.failure = failure

    def open(self, request, timeout):
        self.calls.append(request)
        if request.get_header("Authorization") != "Bearer " + KEY and request.get_header("X-api-key") != KEY:
            return Response(401, {"error": "Invalid API key"})
        path = urlsplit(request.full_url).path
        params = parse_qs(urlsplit(request.full_url).query)
        parts = path.split("/")
        query = params.get("q", [""])[0]
        cursor = params.get("cursor", [""])[0]
        if request.method == "POST":
            if not request.data:
                return Response(400, {"error": "Missing JSON body"})
            try:
                body = json.loads(request.data)
            except json.JSONDecodeError:
                return Response(400, {"error": "Invalid JSON body"})
            if not isinstance(body, dict):
                return Response(400, {"error": "Invalid JSON body"})
            query = body.get("q", "")
            query = query if isinstance(query, str) else ""
            cursor = body.get("cursor", "")
        if path.startswith("/api/user/"):
            if parts[3] == "invalid-name" or len(parts[3]) > 15:
                return Response(400, {"error": "Invalid username"})
            if len(parts) > 4 and parts[4] not in {"posts", "replies", "media"}:
                return Response(404, {"error": "API endpoint not found"})
            if parts[3] != "NASA":
                return Response(404, {"error": "User not found"})
        if path.startswith("/api/post/"):
            if not parts[3].isdigit() or len(parts[3]) > 19:
                return Response(400, {"error": "Invalid post ID"})
            if parts[3] == "1":
                return Response(404, {"error": "Post not found"})
        if path == "/api/search/posts":
            if not query:
                return Response(400, {"error": "Missing q parameter"})
            if len(query) > 500:
                return Response(400, {"error": "Search input too long"})
        if self.failure:
            return Response(*self.failure)
        if cursor:
            if cursor != CURSOR:
                raise AssertionError("The exact opaque cursor was not round-tripped")
        value = page(bool(cursor))
        if self.missing_cursor:
            value["nextCursor"] = ""
        if path == "/api/user/NASA":
            value = user()
        elif path.startswith("/api/user/"):
            value["user"] = user()
        elif path.startswith("/api/post/"):
            replies = copy.deepcopy(value)
            replies["items"] = [{"items": value["items"], "hasMore": False, "cursor": ""}]
            value = {"tweet": tweet(parts[3]), "before": {"items": [], "hasMore": False, "cursor": ""},
                     "after": {"items": [], "hasMore": False, "cursor": ""}, "replies": replies}
        elif path == "/api/search/posts":
            value["query"] = query
        return Response(200, value)


class LiveContractTests(unittest.TestCase):
    def test_native_default_avatar_host_is_allowed(self):
        value = tweet()
        value["user"]["avatar"] = "https://abs.twimg.com/sticky/default_profile_images/default_profile.png"
        validate_tweet(value)

    def runner(self, **kwargs):
        result = Runner("http://127.0.0.1:8080", KEY, delay=0, **kwargs)
        result.opener = Opener()
        return result

    def test_every_operation_auth_validation_and_actual_cursor(self):
        runner = self.runner()
        report = runner.run()
        self.assertTrue(report["summary"]["complete"], report["checks"])
        self.assertEqual(set(report["summary"]["success_contracts"]), set(OPERATIONS))
        self.assertEqual(len(report["pagination"]), 6)
        self.assertTrue(all(row["new_items"] > 0 for row in report["pagination"].values()))
        self.assertLess(report["summary"]["requests"], 80)
        serialized = json.dumps(report)
        self.assertNotIn(KEY, serialized)
        self.assertNotIn(CURSOR, serialized)
        self.assertNotIn("public fixture", serialized)

    def test_missing_cursor_is_explicitly_incomplete(self):
        runner = self.runner(only=["posts"])
        runner.opener = Opener(missing_cursor=True)
        report = runner.run()
        self.assertFalse(report["summary"]["complete"])
        self.assertEqual(report["summary"]["failed_checks"], 0)
        self.assertEqual(report["summary"]["unverified_pagination"], ["posts"])
        self.assertEqual(report["pagination"]["posts"]["result"], "untested")

    def test_rate_limit_and_auth_failure_stop_without_retry(self):
        for status, error in [(429, "provider_rate_limited"), (503, "provider_authentication_failed")]:
            with self.subTest(status=status):
                runner = self.runner(only=["user"])
                runner.opener = Opener(failure=(status, {"error": error}))
                report = runner.run()
                self.assertTrue(report["stopped"])
                self.assertFalse(report["summary"]["complete"])
                self.assertEqual(len([r for r in report["requests"] if r.get("status") == status]), 1)
                self.assertEqual(report["requests"][-1]["status"], status)

    def test_html_failure_does_not_leak_raw_body(self):
        runner = self.runner(only=["user"])
        runner.opener = Opener(failure=(200, b"<html>secret upstream body</html>", "text/html"))
        report = runner.run()
        self.assertGreater(report["summary"]["failed_checks"], 0)
        self.assertNotIn("secret upstream body", json.dumps(report))

    def test_no_credential_bearing_redirect(self):
        with self.assertRaises(ContractFailure):
            NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_nested_unavailable_quote_can_have_no_identity(self):
        value = tweet()
        value["quote"] = tweet("0")
        value["quote"].update(available=False, createdAt=None, user={})
        validate_tweet(value)
        value["id"] = "0"
        with self.assertRaises(ContractFailure):
            validate_tweet(value)

    def test_invalid_base_url_is_rejected_before_requests(self):
        with self.assertRaises(ContractFailure):
            Runner("https://secret@example.com", KEY)

    def test_post_only_derives_public_fixture_with_one_search(self):
        report = self.runner(only=["post"]).run()
        self.assertTrue(report["summary"]["complete"])
        self.assertEqual(len([r for r in report["requests"] if r["label"] == "fixture.search"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
