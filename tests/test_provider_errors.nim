import std/[httpcore, times, unittest]
import packedjson
import ../src/[provider_errors, types]

suite "Provider response classification":
  test "classifies HTTP failures independently of the response body":
    for code in [Http401, Http403]:
      check classifyHttpStatus(code) == httpAuthenticationFailed
    check classifyHttpStatus(Http429) == httpRateLimited
    check classifyHttpStatus(Http503) == httpBadClient
    for code in [Http404, Http500, Http502, Http504]:
      check classifyHttpStatus(code) == httpUnavailable
    for code in [Http400, Http301, Http418]:
      check classifyHttpStatus(code) == httpInvalidResponse
    check classifyHttpStatus(Http200) == httpSuccess

  test "accepts surrounding JSON whitespace":
    check parseProviderResponse(" \n{\"data\":{}} \r\n").kind == JObject
    check parseProviderResponse(" \n[] ").kind == JArray

  test "rejects empty non-JSON and malformed JSON":
    for body in ["", "  ", "<html>error</html>", "{broken", "null", "123", "{}{}", "{} trailing"]:
      expect InternalError:
        discard parseProviderResponse(body)

  test "finds error codes regardless of field order or additional errors":
    let node = parseProviderResponse("""{"data":null,"errors":[{"code":34},{"code":88}]}""")
    check providerErrorCodes(node) == @[34, 88]
    check providerErrorCodes(parseProviderResponse("""[{"code":89}]""")) == @[89]
    check providerErrorCodes(parseProviderResponse("""[{"id":123}]""")).len == 0

  test "rejects malformed error envelopes":
    for body in ["""{"errors":{}}""", """{"errors":[{"message":"failure"}]}"""]:
      expect InternalError:
        discard providerErrorCodes(parseProviderResponse(body))

  test "recognizes only explicit resource-not-found error envelopes":
    for body in ["""{"errors":[{"code":50}]}""", """[{"code":144}]""",
                 """{"data":null,"errors":[{"code":34},{"code":50}]}"""]:
      check isResourceNotFoundResponse(body)
    for body in ["", "<html>not found</html>", "{}", "{broken", "[]",
                 """{"errors":[{"code":9999}]}""", """{"errors":[{"code":50},{"code":88}]}""",
                 """[{"code":50},{"id":123}]""", """{"errors":[{"message":"not found"}]}"""]:
      check not isResourceNotFoundResponse(body)

  test "parses seconds and HTTP dates for Retry-After":
    check retryAfterSeconds(newHttpHeaders({"Retry-After": "120"})) == 120
    check retryAfterSeconds(newHttpHeaders({"Retry-After": "-1"})) == 0
    check retryAfterSeconds(newHttpHeaders({"Retry-After": "bad"})) == 0
    check retryAfterSeconds(newHttpHeaders()) == 0
    let now = parse("2026-09-07 00:00:00", "yyyy-MM-dd HH:mm:ss", utc()).toTime.toUnix
    check retryAfterSeconds(newHttpHeaders({"Retry-After": "Mon, 07 Sep 2026 00:01:00 GMT"}), now) == 60
    check retryAfterSeconds(newHttpHeaders({"Retry-After": "Mon, 07 Sep 2026 00:00:00 GMT"}), now + 60) == 0
