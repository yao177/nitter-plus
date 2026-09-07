"""Bounded live contracts for every JSON API added by the Nitter fork."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


OPERATIONS = ("user", "posts", "replies", "media", "post", "search_get", "search_post")
PAGINATED = set(OPERATIONS) - {"user"}
PUBLIC_HOSTS = {"x.com", "abs.twimg.com", "pbs.twimg.com", "video.twimg.com"}
ERRORS = {
    "Invalid API key", "Invalid username", "Invalid post ID", "API endpoint not found",
    "Missing q parameter", "Search input too long", "Missing JSON body", "Invalid JSON body",
    "User not found", "User is suspended", "Post not found", "API is disabled",
    "provider_unavailable", "provider_rate_limited", "provider_invalid_response",
    "provider_authentication_failed",
}
MAX_BODY = 8 * 1024 * 1024


class ContractFailure(Exception):
    pass


class StopRun(ContractFailure):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        raise ContractFailure("Unexpected redirect; credentials were not forwarded")


def require(condition, message):
    if not condition:
        raise ContractFailure(message)


def object_with(value, fields, label):
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(fields).issubset(value), f"{label} is missing required fields")


def validate_urls(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"url", "avatar", "banner", "thumbnail"} and child:
                require(isinstance(child, str), "URL fields must be strings")
                if key == "banner" and child.startswith("#"):
                    continue
                parsed = urlsplit(child)
                require(parsed.scheme == "https" and parsed.hostname in PUBLIC_HOSTS,
                        "Media/status URL must use an absolute public X media host")
            validate_urls(child)
    elif isinstance(value, list):
        for child in value:
            validate_urls(child)


def validate_user(value, expected=None):
    object_with(value, ("id", "username", "fullname", "bio", "avatar", "banner",
                        "following", "followers", "posts", "likes", "joinedAt",
                        "protected", "suspended", "verifiedType"), "user")
    require(isinstance(value["id"], str) and value["id"].isdigit()
            and int(value["id"]) > 0, "User ID must be a nonempty positive numeric string")
    require(isinstance(value["username"], str) and bool(value["username"]),
            "Username must be nonempty")
    if expected:
        require(value["username"].lower() == expected.lower(), "User identity does not match request")
    for field in ("following", "followers", "posts", "likes"):
        require(type(value[field]) is int and value[field] >= 0, "User counters must be nonnegative integers")
    for field in ("protected", "suspended"):
        require(type(value[field]) is bool, "User availability flags must be booleans")
    require(value["joinedAt"] is None or isinstance(value["joinedAt"], str),
            "joinedAt must be a string or null")
    validate_urls(value)


def validate_tweet(value, expected=None, nested=False):
    object_with(value, ("id", "threadId", "replyId", "url", "user", "text", "html",
                        "createdAt", "available", "stats", "media"), "tweet")
    require(isinstance(value["id"], str) and value["id"].isdigit()
            and (int(value["id"]) > 0 or nested and value["available"] is False),
            "Tweet ID must be a positive numeric string except nested tombstones")
    if expected:
        require(value["id"] == expected, "Tweet identity does not match request")
    require(type(value["available"]) is bool, "Tweet availability must be a boolean")
    # Tombstones can retain an ID but intentionally omit author identity.
    if value["available"]:
        validate_user(value["user"])
        require(isinstance(value["createdAt"], str) and value["createdAt"],
                "Available tweet must have a timestamp")
    require(isinstance(value["text"], str) and isinstance(value["html"], str),
            "Tweet text fields must be strings")
    object_with(value["stats"], ("replies", "retweets", "likes", "views"), "tweet stats")
    for count in value["stats"].values():
        require(type(count) is int and count >= 0, "Tweet counters must be nonnegative integers")
    require(isinstance(value["media"], list), "Tweet media must be an array")
    for medium in value["media"]:
        object_with(medium, ("type", "url"), "media")
        require(medium["type"] in {"photo", "video", "gif"}, "Unknown media type")
        if medium["type"] == "video":
            object_with(medium, ("thumbnail", "available", "reason", "durationMs",
                                 "playbackType", "variants"), "video")
            require(isinstance(medium["variants"], list), "Video variants must be an array")
            for variant in medium["variants"]:
                object_with(variant, ("bitrate", "contentType", "url", "resolution"), "variant")
            if medium["available"]:
                require(bool(medium["url"]), "Available video must have a playback URL")
                require(any(v["url"] == medium["url"] for v in medium["variants"]),
                        "Video playback URL must match one of its variants")
    if not nested:
        for field in ("quote", "retweet"):
            if value.get(field) is not None:
                validate_tweet(value[field], nested=True)
    validate_urls(value)


def validate_page(value, expected_user=None, expected_query=None, nonempty=True):
    object_with(value, ("items", "nextCursor", "previousCursor", "beginning"), "timeline")
    require(isinstance(value["items"], list), "Timeline items must be an array")
    require(isinstance(value["nextCursor"], str) and isinstance(value["previousCursor"], str),
            "Timeline cursors must be strings")
    require(type(value["beginning"]) is bool, "Timeline beginning must be a boolean")
    if nonempty:
        require(bool(value["items"]), "Live timeline unexpectedly contains no posts")
    for item in value["items"]:
        validate_tweet(item)
    if expected_user:
        require("user" in value, "User timeline must include its user")
        validate_user(value["user"], expected_user)
    if expected_query is not None:
        require(value.get("query") == expected_query, "Search query was not preserved")


def validate_detail(value, expected):
    object_with(value, ("tweet", "before", "after", "replies"), "post detail")
    validate_tweet(value["tweet"], expected)
    require(value["tweet"]["available"], "Live fixture post is unavailable")
    for key in ("before", "after"):
        chain = value[key]
        object_with(chain, ("items", "hasMore", "cursor"), "conversation chain")
        require(isinstance(chain["items"], list) and type(chain["hasMore"]) is bool
                and isinstance(chain["cursor"], str), "Conversation chain has invalid field types")
        for item in chain["items"]:
            validate_tweet(item)
    replies = value["replies"]
    object_with(replies, ("items", "nextCursor", "previousCursor", "beginning"), "replies")
    require(isinstance(replies["items"], list) and isinstance(replies["nextCursor"], str)
            and isinstance(replies["previousCursor"], str)
            and type(replies["beginning"]) is bool, "Reply pagination has invalid field types")
    for chain in replies["items"]:
        object_with(chain, ("items", "hasMore", "cursor"), "reply chain")
        require(isinstance(chain["items"], list) and type(chain["hasMore"]) is bool
                and isinstance(chain["cursor"], str), "Reply chain has invalid field types")
        for item in chain["items"]:
            validate_tweet(item)


def detail_ids(value):
    return {item["id"] for group in value["replies"]["items"] for item in group["items"]}


def cursor_receipt(cursor):
    return {"length": len(cursor), "sha256_prefix": hashlib.sha256(cursor.encode()).hexdigest()[:16]}


class Runner:
    def __init__(self, base_url, api_key, username="NASA", query=None, post_id=None,
                 only=None, delay=0.25, timeout=30, max_requests=80, missing_user="ntr0zz0qx9v7p2"):
        parsed = urlsplit(base_url)
        require(parsed.scheme in {"http", "https"} and bool(parsed.hostname)
                and not parsed.username and not parsed.password and not parsed.query
                and not parsed.fragment, "Base URL must be HTTP(S), without credentials/query/fragment")
        require(bool(api_key) and "\n" not in api_key and "\r" not in api_key, "API key file is empty or invalid")
        require(bool(re.fullmatch(r"[A-Za-z0-9_]{1,15}", username)), "Invalid fixture username")
        require(bool(re.fullmatch(r"[A-Za-z0-9_]{1,15}", missing_user)), "Invalid missing-user fixture")
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.username = username
        self.query = query or f"from:{username}"
        self.post_id = post_id
        self.selected = set(only or OPERATIONS)
        require(self.selected <= set(OPERATIONS), "Unknown selected API operation")
        self.delay = max(0, delay)
        self.timeout = timeout
        self.max_requests = max_requests
        self.missing_user = missing_user
        self.opener = build_opener(ProxyHandler({}), NoRedirect())
        self.last_request = 0.0
        self.report = {
            "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "base_url": self.base_url, "username": username,
            "selected_operations": sorted(self.selected), "requests": [], "checks": [],
            "pagination": {}, "stopped": False,
        }

    def request(self, label, path, method="GET", payload=None, raw=None,
                auth="bearer", expected=200, error=None):
        require(len(self.report["requests"]) < self.max_requests, "Request budget exhausted")
        pause = self.delay - (time.monotonic() - self.last_request)
        if pause > 0:
            time.sleep(pause)
        headers = {"Accept": "application/json"}
        if auth == "bearer":
            headers["Authorization"] = f"Bearer {self.api_key}"
        elif auth == "x-api-key":
            headers["X-API-Key"] = self.api_key
        elif auth == "bad":
            headers["Authorization"] = f"Bearer {self.api_key}.invalid-contract-key"
        elif auth == "bad-x-api-key":
            headers["X-API-Key"] = f"{self.api_key}.invalid-contract-key"
        if payload is not None:
            raw = json.dumps(payload).encode()
        if method == "POST":
            headers["Content-Type"] = "application/json"
            raw = b"" if raw is None else raw
        started = time.monotonic()
        record = {"label": label, "method": method, "auth": auth, "expected_status": expected}
        self.report["requests"].append(record)
        self.last_request = started
        try:
            try:
                response = self.opener.open(Request(self.base_url + path, data=raw,
                                                    headers=headers, method=method), timeout=self.timeout)
            except HTTPError as exc:
                response = exc
            with response:
                record["status"] = response.status
                record["json_content_type"] = response.headers.get_content_type() == "application/json"
                retry_after = response.headers.get("Retry-After", "")
                if retry_after.isdigit():
                    record["retry_after_seconds"] = int(retry_after)
                body = response.read(MAX_BODY + 1)
            record["seconds"] = round(time.monotonic() - started, 3)
            require(len(body) <= MAX_BODY, "API response exceeded the bounded body limit")
            value = None
            if record["json_content_type"]:
                try:
                    value = json.loads(body)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    pass
            provider_error = value.get("error") if isinstance(value, dict) else None
            if provider_error in ERRORS:
                record["error"] = provider_error
            if response.status == 429 or provider_error == "provider_authentication_failed":
                self.report["stopped"] = True
                raise StopRun("Stopped to protect existing sessions after rate limit/provider authentication failure")
            require(record["json_content_type"], "API response did not use application/json")
            require(isinstance(value, dict), "API response was not a valid JSON object")
            require(response.status == expected,
                    f"Unexpected HTTP status: expected {expected}, received {response.status}")
            if error:
                require(provider_error == error, "API error code does not match its contract")
            elif expected == 200:
                require("error" not in value, "Successful response contains an error")
            record["transport_contract"] = "passed"
            return value
        except (URLError, OSError, TimeoutError) as exc:
            record["network_error_type"] = type(exc).__name__
            raise ContractFailure(f"Network request failed ({type(exc).__name__})") from None

    def check(self, label, action):
        record = {"name": label}
        self.report["checks"].append(record)
        try:
            result = action()
            record["result"] = "passed"
            if isinstance(result, dict):
                record["evidence"] = result
            return result
        except StopRun as exc:
            record.update(result="stopped", reason=str(exc))
            raise
        except ContractFailure as exc:
            record.update(result="failed", reason=str(exc))
            return None

    def route(self, operation):
        if operation == "user":
            return "GET", f"/api/user/{self.username}", None
        if operation in {"posts", "replies", "media"}:
            return "GET", f"/api/user/{self.username}/{operation}", None
        if operation == "post":
            return "GET", f"/api/post/{self.post_id or '1'}", None
        if operation == "search_get":
            return "GET", "/api/search/posts?" + urlencode({"q": self.query}), None
        return "POST", "/api/search/posts", {"q": self.query}

    def call_operation(self, operation, auth="bearer", cursor=None):
        method, path, payload = self.route(operation)
        if cursor:
            if method == "POST":
                payload["cursor"] = cursor
            else:
                path += ("&" if "?" in path else "?") + urlencode({"cursor": cursor})
        label = f"{operation}.{'next_page' if cursor else auth}"
        value = self.request(label, path, method, payload, auth=auth)
        if operation == "user":
            validate_user(value, self.username)
        elif operation == "post":
            validate_detail(value, self.post_id)
        else:
            validate_page(value, expected_user=self.username if operation in {"posts", "replies", "media"} else None,
                          expected_query=self.query if operation.startswith("search_") else None)
            if operation == "media":
                require(any(item["media"] for item in value["items"]),
                        "Live media timeline contains no media")
        return value

    def validation_cases(self):
        cases = []
        if "user" in self.selected:
            cases += [("user.invalid_name", "/api/user/invalid-name", "GET", None, 400, "Invalid username"),
                      ("user.long_name", "/api/user/" + "a" * 16, "GET", None, 400, "Invalid username")]
        for kind in ("posts", "replies", "media"):
            if kind in self.selected:
                cases.append((f"{kind}.invalid_name", f"/api/user/invalid-name/{kind}", "GET", None, 400, "Invalid username"))
        if self.selected & {"posts", "replies", "media"}:
            cases.append(("timeline.invalid_kind", f"/api/user/{self.username}/likes", "GET", None, 404, "API endpoint not found"))
        if "post" in self.selected:
            for suffix in ("not-a-number", "1" * 20):
                cases.append(("post.invalid_id." + str(len(suffix)), f"/api/post/{suffix}", "GET", None, 400, "Invalid post ID"))
        if "search_get" in self.selected:
            cases += [("search_get.missing_q", "/api/search/posts", "GET", None, 400, "Missing q parameter"),
                      ("search_get.long_q", "/api/search/posts?" + urlencode({"q": "a" * 501}), "GET", None, 400, "Search input too long")]
        if "search_post" in self.selected:
            for label, raw, error in [
                ("empty", b"", "Missing JSON body"), ("malformed", b"{", "Invalid JSON body"),
                ("array", b"[]", "Invalid JSON body"), ("null", b"null", "Invalid JSON body"),
                ("missing_q", b"{}", "Missing q parameter"), ("numeric_q", b'{"q":1}', "Missing q parameter"),
                ("empty_q", b'{"q":""}', "Missing q parameter"),
                ("long_q", json.dumps({"q": "a" * 501}).encode(), "Search input too long"),
            ]:
                cases.append((f"search_post.{label}", "/api/search/posts", "POST", raw, 400, error))
        return cases

    def run(self):
        pages = {}
        try:
            for operation in OPERATIONS:
                if operation not in self.selected:
                    continue
                method, path, payload = self.route(operation)
                for auth in ("missing", "bad", "bad-x-api-key"):
                    label = f"{operation}.{auth}_auth"
                    self.check(label, lambda label=label, path=path, method=method, payload=payload, auth=auth:
                               self.request(label, path, method, payload, auth=auth, expected=401, error="Invalid API key") and {})
            for label, path, method, raw, status, error in self.validation_cases():
                self.check(label, lambda label=label, path=path, method=method, raw=raw, status=status, error=error:
                           self.request(label, path, method, raw=raw, expected=status, error=error) and {})
            for operation in ("user", "posts", "replies", "media", "search_get", "search_post", "post"):
                if operation not in self.selected:
                    continue
                if operation == "post" and self.post_id is None:
                    candidates = [item for value in pages.values() for item in value.get("items", [])]
                    if not candidates:
                        fixture = self.request("fixture.search", "/api/search/posts?" + urlencode({"q": self.query}))
                        validate_page(fixture, expected_query=self.query)
                        candidates = fixture["items"]
                    self.post_id = max(candidates, key=lambda item: item["stats"]["replies"])["id"]
                for auth in ("bearer", "x-api-key"):
                    def success(operation=operation, auth=auth):
                        value = self.call_operation(operation, auth)
                        pages.setdefault(operation, value)
                        if operation == "user":
                            return {"id": value["id"], "username": value["username"]}
                        if operation == "post":
                            return {"id": value["tweet"]["id"], "reply_items": len(detail_ids(value))}
                        media = [medium for item in value["items"] for medium in item["media"]]
                        return {"item_count": len(value["items"]), "first_ids": [item["id"] for item in value["items"][:3]],
                                "media_items": sum(bool(item["media"]) for item in value["items"]),
                                "media_types": sorted({medium["type"] for medium in media}),
                                "video_variants": sum(len(medium.get("variants", [])) for medium in media)}
                    self.check(f"{operation}.{auth}.shape", success)
            if "search_get" in pages and "search_post" in pages:
                def compatible():
                    get_ids = {item["id"] for item in pages["search_get"]["items"]}
                    post_ids = {item["id"] for item in pages["search_post"]["items"]}
                    require(bool(get_ids & post_ids), "GET and POST search returned disjoint result identities")
                    return {"overlapping_ids": len(get_ids & post_ids), "query_equal": True}
                self.check("search.get_post_compatibility", compatible)
            for operation in OPERATIONS:
                if operation not in self.selected or operation not in PAGINATED:
                    continue
                value = pages.get(operation)
                if value is None:
                    self.report["pagination"][operation] = {"result": "untested", "reason": "First page did not pass"}
                    continue
                cursor = value["replies"]["nextCursor"] if operation == "post" else value["nextCursor"]
                if not cursor:
                    self.report["pagination"][operation] = {"result": "untested", "reason": "Live response did not provide a next cursor"}
                    continue
                def next_page(operation=operation, value=value, cursor=cursor):
                    following = self.call_operation(operation, cursor=cursor)
                    prior_ids = detail_ids(value) if operation == "post" else {item["id"] for item in value["items"]}
                    following_ids = detail_ids(following) if operation == "post" else {item["id"] for item in following["items"]}
                    require(bool(following_ids - prior_ids), "Returned next cursor did not produce any new post identities")
                    evidence = {"result": "passed", "cursor": cursor_receipt(cursor),
                                "new_items": len(following_ids - prior_ids), "items": len(following_ids)}
                    self.report["pagination"][operation] = evidence
                    return evidence
                self.report["pagination"][operation] = {"result": "failed"}
                self.check(f"{operation}.pagination", next_page)
            if "user" in self.selected:
                self.check("user.not_found", lambda: self.request("user.not_found", f"/api/user/{self.missing_user}",
                           expected=404, error="User not found") and {})
            for operation in ("posts", "replies", "media"):
                if operation in self.selected:
                    self.check(f"{operation}.not_found", lambda operation=operation:
                               self.request(f"{operation}.not_found", f"/api/user/{self.missing_user}/{operation}",
                                            expected=404, error="User not found") and {})
            if "post" in self.selected:
                self.check("post.not_found", lambda: self.request("post.not_found", "/api/post/1", expected=404,
                                                                 error="Post not found") and {})
        except StopRun as exc:
            self.report["stop_reason"] = str(exc)
        except ContractFailure as exc:
            self.report["checks"].append({"name": "fixture", "result": "failed", "reason": str(exc)})
        self.report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        failures = sum(check["result"] == "failed" for check in self.report["checks"])
        untested = sorted(op for op in self.selected & PAGINATED
                          if self.report["pagination"].get(op, {}).get("result") != "passed")
        successes = {op: all(any(c["name"] == f"{op}.{auth}.shape" and c["result"] == "passed"
                                for c in self.report["checks"]) for auth in ("bearer", "x-api-key"))
                     for op in sorted(self.selected)}
        self.report["summary"] = {"requests": len(self.report["requests"]), "failed_checks": failures,
                                  "success_contracts": successes, "unverified_pagination": untested,
                                  "complete": not failures and not untested and all(successes.values())
                                              and not self.report["stopped"]}
        return self.report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--api-key-file", required=True, type=Path)
    parser.add_argument("--username", default="NASA")
    parser.add_argument("--query")
    parser.add_argument("--post-id")
    parser.add_argument("--only", action="append", choices=OPERATIONS)
    parser.add_argument("--missing-user", default="ntr0zz0qx9v7p2")
    parser.add_argument("--delay", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--max-requests", type=int, default=80)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        key = args.api_key_file.read_text().strip()
        runner = Runner(args.base_url, key, args.username, args.query, args.post_id,
                        args.only, args.delay, args.timeout, args.max_requests, args.missing_user)
        report = runner.run()
    except (OSError, ContractFailure):
        parser.exit(1, "Unable to configure contract test; verify the URL, fixture and key file.\n")
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
    return 0 if report["summary"]["complete"] else 1 if report["summary"]["failed_checks"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
