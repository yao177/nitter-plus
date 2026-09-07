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

  test "preserves Retry-After after retry exhaustion":
    proc exhaustWithDelay(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        raise rateLimitError(120)
    try:
      waitFor exhaustWithDelay()
      check false
    except RateLimitError as e:
      check e.retryAfter == 120

  test "preserves rate limit when the next attempt has no ready sessions":
    var attempts = 0
    proc exhaustSessions(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        inc attempts
        if attempts == 1:
          raise rateLimitError(60)
        raise noSessionsError()
    try:
      waitFor exhaustSessions()
      check false
    except RateLimitError as e:
      check e.retryAfter == 60
    check attempts == 2

  test "does not relabel authentication and availability failures":
    proc failAuthentication(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        raise newException(ProviderAuthError, "test")
    proc failAvailability(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        raise newException(ProviderUnavailableError, "test")
    expect ProviderAuthError:
      waitFor failAuthentication()
    expect ProviderUnavailableError:
      waitFor failAvailability()

  test "can try another session after explicit credential rejection":
    var attempts = 0
    proc retryCredentials(): Future[void] {.async.} =
      let req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      retry:
        inc attempts
        if attempts == 1:
          let error = newException(ProviderAuthError, "rejected credentials")
          error.retryable = true
          raise error
    waitFor retryCredentials()
    check attempts == 2
