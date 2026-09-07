"""Offline HTTP contract tests using a real Nitter binary and disposable Redis."""
import configparser
import contextlib
import gzip
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SUCCESS = json.dumps({"data": {
    "user": {"result": {"__typename": "User", "rest_id": "123", "legacy": {
        "id_str": "123", "screen_name": "tester", "name": "Tester"}}},
    "search_by_raw_query": {"search_timeline": {"timeline": {"instructions": []}}},
}}).encode()
SESSION = '{"kind":"cookie","authToken":"offline-test-token","ct0":"offline-test-csrf"}\n'
ENDPOINTS = ("/api/search/posts?q=offline-contract", "/api/user/tester")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_port(port, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"Test server exited with {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("Test server did not become ready")


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.server.requests += 1
        response = self.server.responses[0]
        if len(self.server.responses) > 1:
            self.server.responses.pop(0)
        status, body, headers = response[:3]
        reason = response[3] if len(response) > 3 else None
        self.send_response(status, reason)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class ProviderHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get("NITTER_TEST_BINARY", ROOT / "nitter")).resolve()
        cls.redis = shutil.which("redis-server") or shutil.which("valkey-server")
        if not cls.binary.is_file() or not cls.redis:
            raise unittest.SkipTest("A compiled nitter binary and Redis/Valkey server are required")
        cls.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        cls.thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.thread.join(timeout=5)

    @contextlib.contextmanager
    def instance(self, responses, retries=1, sessions=SESSION):
        self.upstream.responses = list(responses)
        self.upstream.requests = 0
        processes = []
        with tempfile.TemporaryDirectory(prefix="nitter-http-contract-") as directory:
            root = Path(directory)
            redis_port = free_port()
            api_port = free_port()
            config = configparser.ConfigParser()
            config.optionxform = str
            config.read_dict({
                "Server": {"address": "127.0.0.1", "hostname": "127.0.0.1",
                           "port": str(api_port), "https": "false", "staticDir": str(ROOT / "public")},
                "Cache": {"redisHost": "127.0.0.1", "redisPort": str(redis_port),
                          "redisConnections": "1", "redisMaxConnections": "2"},
                "Config": {"enableApi": "true", "apiKey": "offline-api-key",
                           "hmacKey": "offline-hmac-key", "tokenCount": "0",
                           "maxRetries": str(retries), "retryDelayMs": "0", "disableTid": "true",
                           "apiProxy": f"http://127.0.0.1:{self.upstream.server_port}"},
            })
            for section in config.sections():
                for key, value in config.items(section):
                    config.set(section, key, json.dumps(value))
            with (root / "nitter.conf").open("w") as stream:
                config.write(stream)
            (root / "sessions.jsonl").write_text(sessions)
            env = os.environ.copy()
            env.update(NITTER_CONF_FILE=str(root / "nitter.conf"),
                       NITTER_SESSIONS_FILE=str(root / "sessions.jsonl"),
                       NITTER_ENABLE_API="true", NITTER_API_KEY="offline-api-key")
            with (root / "server.log").open("w+") as log:
                try:
                    redis = subprocess.Popen([
                        self.redis, "--bind", "127.0.0.1", "--port", str(redis_port),
                        "--save", "", "--appendonly", "no", "--dir", str(root),
                    ], stdout=log, stderr=subprocess.STDOUT)
                    processes.append(redis)
                    wait_port(redis_port, redis)
                    nitter = subprocess.Popen([str(self.binary)], env=env, cwd=ROOT,
                                              stdout=log, stderr=subprocess.STDOUT)
                    processes.append(nitter)
                    wait_port(api_port, nitter)
                    yield api_port
                except Exception:
                    log.flush()
                    log.seek(0)
                    print(log.read())
                    raise
                finally:
                    for process in reversed(processes):
                        if process.poll() is None:
                            process.terminate()
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait(timeout=5)

    def request(self, port, path, key="offline-api-key"):
        client = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        try:
            client.request("GET", path, headers={"Authorization": f"Bearer {key}"})
            response = client.getresponse()
            raw = response.read()
            self.assertIn("application/json", response.getheader("Content-Type", ""))
            return response.status, json.loads(raw), response.getheader("Retry-After")
        finally:
            client.close()

    def test_error_matrix(self):
        cases = [
            ("empty_404", 404, b"", {}, 503, "provider_unavailable"),
            ("html_404", 404, b"<html>not found</html>", {}, 503, "provider_unavailable"),
            ("unknown_json_404", 404, b'{"errors":[{"code":9999}]}', {}, 503, "provider_unavailable"),
            ("empty_json_404", 404, b'{}', {}, 503, "provider_unavailable"),
            ("mixed_errors_404", 404, b'{"errors":[{"code":50},{"code":88}]}', {}, 503, "provider_unavailable"),
            ("broken_gzip_404", 404, b"invalid gzip", {"Content-Encoding": "gzip"}, 503, "provider_unavailable"),
            ("empty_429", 429, b"", {"Retry-After": "60"}, 429, "provider_rate_limited"),
            ("json_429", 429, b'{"data":null,"errors":[{"code":88}]}', {}, 429, "provider_rate_limited"),
            ("html_500", 500, b"<html>error</html>", {}, 503, "provider_unavailable"),
            ("json_502", 502, b'{"error":"Bad Gateway"}', {}, 503, "provider_unavailable"),
            ("json_503", 503, b'{"error":"Service Unavailable"}', {}, 503, "provider_unavailable"),
            ("empty_504", 504, b"", {}, 503, "provider_unavailable"),
            ("empty_401", 401, b"", {}, 503, "provider_authentication_failed"),
            ("empty_403", 403, b"", {}, 503, "provider_authentication_failed"),
            ("json_400", 400, b'{"error":"Bad Request"}', {}, 502, "provider_invalid_response"),
            ("empty_200", 200, b"", {}, 502, "provider_invalid_response"),
            ("empty_204", 204, b"", {}, 502, "provider_invalid_response"),
            ("html_200", 200, b"<html>error</html>", {}, 502, "provider_invalid_response"),
            ("broken_json", 200, b'{"data":', {}, 502, "provider_invalid_response"),
            ("trailing_json", 200, b'{}{}', {}, 502, "provider_invalid_response"),
            ("cloudflare", 200, b" \n<!DOCTYPE html><title>error</title>Cloudflare", {}, 503, "provider_unavailable"),
            ("broken_gzip", 200, b"invalid gzip", {"Content-Encoding": "gzip"}, 502, "provider_invalid_response"),
            ("reordered_rate_limit", 200, b' \n{"data":null,"errors":[{"code":88}]}', {"Retry-After": "60"}, 429, "provider_rate_limited"),
            ("multiple_errors", 200, b'{"errors":[{"code":34},{"code":88}]}', {}, 429, "provider_rate_limited"),
            ("expired_session", 200, b'{"data":null,"errors":[{"code":89}]}', {}, 503, "provider_authentication_failed"),
            ("unknown_error", 200, b'{"errors":[{"code":9999}]}', {}, 502, "provider_invalid_response"),
            ("malformed_errors", 200, b'{"errors":{}}', {}, 502, "provider_invalid_response"),
        ]
        for name, status, body, headers, expected, error in cases:
            for endpoint in ENDPOINTS:
                with self.subTest(case=name, endpoint=endpoint):
                    with self.instance([(status, body, headers)]) as port:
                        actual, value, retry_after = self.request(port, endpoint)
                        self.assertEqual((actual, value.get("error")), (expected, error))
                        self.assertEqual(retry_after, headers.get("Retry-After"))
                        self.assertEqual(self.upstream.requests, 2 if status == 503 else 1)

    def test_success_whitespace_gzip_and_bad_optional_headers(self):
        for body, headers in [
            (SUCCESS, {}), (b" \n" + SUCCESS + b" \r\n", {}),
            (gzip.compress(SUCCESS), {"Content-Encoding": "gzip"}),
            (SUCCESS, {"x-rate-limit-remaining": "oops"}),
            (SUCCESS, {"x-rate-limit-remaining": "10"}),
        ]:
            for endpoint in ENDPOINTS:
                with self.subTest(endpoint=endpoint, headers=headers):
                    with self.instance([(200, body, headers)]) as port:
                        status, value, _ = self.request(port, endpoint)
                        self.assertEqual(status, 200)
                        if endpoint.startswith("/api/user/"):
                            self.assertEqual((value["id"], value["username"]), ("123", "tester"))
                        else:
                            self.assertEqual(value["items"], [])
                        self.assertEqual(self.upstream.requests, 1)

    def test_status_codes_do_not_depend_on_reason_phrases(self):
        cases = [
            (401, b"", 503, "provider_authentication_failed"),
            (403, b"", 503, "provider_authentication_failed"),
            (429, b"", 429, "provider_rate_limited"),
            (503, b"", 503, "provider_unavailable"),
            (404, b"", 503, "provider_unavailable"),
            (404, b'{"errors":[{"code":50}]}', 404, "User not found"),
        ]
        for upstream_status, body, expected, error in cases:
            for reason in ("Custom reason", ""):
                with self.subTest(status=upstream_status, body=body, reason=reason):
                    response = (upstream_status, body, {}, reason)
                    with self.instance([response]) as port:
                        actual, value, _ = self.request(port, ENDPOINTS[1])
                        self.assertEqual((actual, value["error"]), (expected, error))
                        self.assertEqual(self.upstream.requests, 2 if upstream_status == 503 else 1)

    def test_api_key_is_distinct_from_provider_authentication(self):
        with self.instance([(200, SUCCESS, {})]) as port:
            status, value, _ = self.request(port, ENDPOINTS[0], key="incorrect")
            self.assertEqual((status, value["error"]), (401, "Invalid API key"))
            self.assertEqual(self.upstream.requests, 0)
            self.assertEqual(self.request(port, ENDPOINTS[0])[0], 200)

    def test_generic_auth_response_does_not_invalidate_cookie(self):
        for upstream_status in (401, 403):
            with self.subTest(status=upstream_status):
                with self.instance([(upstream_status, b"", {}), (200, SUCCESS, {})]) as port:
                    self.assertEqual(self.request(port, ENDPOINTS[0])[0], 503)
                    self.assertEqual(self.request(port, ENDPOINTS[0])[0], 200)
                    self.assertEqual(self.upstream.requests, 2)

    def test_explicit_expired_cookie_and_empty_pool(self):
        for status, headers, body in [
            (401, {}, b'{"errors":[{"code":89}]}'),
            (200, {}, b'{"errors":[{"code":89}]}'),
            (401, {"Content-Encoding": "gzip"}, gzip.compress(b'{"errors":[{"code":89}]}')),
        ]:
            with self.instance([(status, body, headers), (200, SUCCESS, {})]) as port:
                for _ in range(2):
                    actual, value, _ = self.request(port, ENDPOINTS[0])
                    self.assertEqual((actual, value["error"]), (503, "provider_authentication_failed"))
                self.assertEqual(self.upstream.requests, 1)
        with self.instance([(200, SUCCESS, {})], sessions="") as port:
            status, value, _ = self.request(port, ENDPOINTS[0])
            self.assertEqual((status, value["error"]), (503, "provider_authentication_failed"))
            self.assertEqual(self.upstream.requests, 0)

    def test_expired_cookie_retries_another_session(self):
        responses = [(401, b'{"errors":[{"code":89}]}', {}), (200, SUCCESS, {})]
        with self.instance(responses, retries=2, sessions=SESSION + SESSION) as port:
            self.assertEqual(self.request(port, ENDPOINTS[0])[0], 200)
            self.assertEqual(self.upstream.requests, 2)

    def test_resource_errors_keep_existing_not_found_behavior(self):
        resources = [(50, ENDPOINTS[1], "User not found"),
                     (144, "/api/post/123", "Post not found")]
        for code, endpoint, error in resources:
            for upstream_status in (200, 404):
                for compressed in (False, True):
                    with self.subTest(endpoint=endpoint, status=upstream_status, compressed=compressed):
                        body = json.dumps({"errors": [{"code": code}]}).encode()
                        headers = {"Content-Encoding": "gzip"} if compressed else {}
                        if compressed:
                            body = gzip.compress(body)
                        with self.instance([(upstream_status, body, headers)]) as port:
                            status, value, _ = self.request(port, endpoint)
                            self.assertEqual((status, value["error"]), (404, error))

    def test_retry_after_survives_exhaustion_and_session_limits(self):
        for body, status in [(b"", 429), (b'{"errors":[{"code":88}]}', 200)]:
            with self.instance([(status, body, {"Retry-After": "60"})], retries=2) as port:
                actual, value, retry_after = self.request(port, ENDPOINTS[0])
                self.assertEqual((actual, value["error"], retry_after), (429, "provider_rate_limited", "60"))
                self.assertEqual(self.upstream.requests, 2 if status == 429 else 1)

    def test_transient_503_and_429_can_recover(self):
        for status in (503, 429):
            with self.instance([(status, b"", {}), (200, SUCCESS, {})], retries=2) as port:
                self.assertEqual(self.request(port, ENDPOINTS[0])[0], 200)
                self.assertEqual(self.upstream.requests, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
