import std/[httpclient, net, unittest]

import ../src/http_pool
import ../src/types

suite "HTTP pool transport recovery":
  setup:
    setMaxHttpConns(4)

  test "retries an SSL failure with a fresh client":
    let pool = HttpPool()
    var attempts = 0

    pool.use(newHttpHeaders()):
      inc attempts
      if attempts == 1:
        raise newException(SslError, "test stale TLS client")

    check attempts == 2
    check pool.conns.len == 1

  test "discards the replacement after a second SSL failure":
    let pool = HttpPool()
    var attempts = 0
    var failed = false

    try:
      pool.use(newHttpHeaders()):
        inc attempts
        raise newException(SslError, "test TLS failure")
    except SslError:
      failed = true

    check failed
    check attempts == 2
    check pool.conns.len == 0

  test "does not retry a rate-limit failure as a transport failure":
    let pool = HttpPool()
    var attempts = 0
    var failed = false

    try:
      pool.use(newHttpHeaders()):
        inc attempts
        raise newException(RateLimitError, "test rate limit")
    except RateLimitError:
      failed = true

    check failed
    check attempts == 1
    check pool.conns.len == 1
