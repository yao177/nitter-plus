import std/[asyncdispatch, os, times, unittest]

import ../src/[auth, config, types]

suite "session token reserve":
  let
    configPath = getTempDir() / "nitter-plus-test-auth.conf"
    sessionsPath = getTempDir() / "nitter-plus-test-auth-sessions.jsonl"

  teardown:
    for path in [configPath, sessionsPath]:
      if fileExists(path):
        removeFile(path)

  test "applies a zero token reserve to session selection":
    writeFile(configPath, "[Config]\ntokenCount = 0\n")
    writeFile(sessionsPath,
      "{\"kind\":\"cookie\",\"authToken\":\"test-token\",\"ct0\":\"test-csrf\"}\n")

    let
      (cfg, _) = getConfig(configPath)
      req = ApiReq(cookie: ApiUrl(endpoint: "test-endpoint"))
      reset = epochTime().int + 60

    initSessionPool(cfg, sessionsPath)
    let session = waitFor getSession(req)
    session.setRateLimit(req, remaining=1, reset=reset, limit=10)
    session.release()

    let reused = waitFor getSession(req)
    check reused == session
    reused.setRateLimit(req, remaining=0, reset=reset, limit=10)
    reused.release()

    expect NoSessionsError:
      discard waitFor getSession(req)
