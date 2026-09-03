import std/[asyncdispatch, unittest]

include ../src/apiutils

suite "API retry exhaustion":
  setup:
    setMaxRetries(2)
    setRetryDelayMs(0)

  test "raises rate limit after all configured attempts fail":
    var attempts = 0

    proc exhaustRetries(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        inc attempts
        raise rateLimitError()

    expect RateLimitError:
      waitFor exhaustRetries()
    check attempts == 2

  test "returns normally after a later attempt succeeds":
    var attempts = 0

    proc retryThenSucceed(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        inc attempts
        if attempts == 1:
          raise rateLimitError()

    waitFor retryThenSucceed()
    check attempts == 2
