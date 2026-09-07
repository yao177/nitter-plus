# SPDX-License-Identifier: AGPL-3.0-only
import httpclient, net, asyncdispatch, options, strutils, uri, times, math, tables
import packedjson, zippy, oauth/oauth1
import types, auth, consts, http_pool, tid
import provider_errors

const
  rlRemaining = "x-rate-limit-remaining"
  rlReset = "x-rate-limit-reset"
  rlLimit = "x-rate-limit-limit"
  npCache = "x-np-cache"

proc isCloudflareHtml*(body: string): bool =
  ## Detect Cloudflare HTML error pages returned instead of JSON
  if body.len < 14 or body[0] != '<': return false
  body[0 ..< 14].toLowerAscii() == "<!doctype html" and "Cloudflare" in body

proc cfTitle*(body: string): string =
  ## Extract <title> from Cloudflare HTML for log diagnostics
  let start = body.find("<title>")
  if start < 0: return "unknown"
  let contentStart = start + 7
  let stop = body.find("</title>", contentStart)
  if stop < 0: return "unknown"
  body[contentStart ..< stop].splitWhitespace().join(" ")

var
  pool: HttpPool
  disableTid: bool
  apiProxy: string
  maxRetries: int
  retryDelayMs: int

proc setDisableTid*(disable: bool) =
  disableTid = disable

proc setMaxRetries*(n: int) =
  maxRetries = max(1, n)

proc setRetryDelayMs*(ms: int) =
  retryDelayMs = ms

proc setApiProxy*(url: string) =
  apiProxy = ""
  if url.len > 0:
    apiProxy = url.strip(chars={'/'}) & "/"
    if "http" notin apiProxy:
      apiProxy = "http://" & apiProxy

proc toUrl*(req: ApiReq; sessionKind: SessionKind): Uri =
  let url = case sessionKind
    of oauth:  req.oauth
    of cookie: req.cookie
  let base = case sessionKind
    of oauth:  "https://api.x.com"
    of cookie: "https://x.com/i/api"
  let prefix = if url.endpoint.startsWith("1.1/"): "" else: "graphql/"
  parseUri(base) / (prefix & url.endpoint) ? url.params

proc getOauthHeader(url, oauthToken, oauthTokenSecret: string): string =
  let
    encodedUrl = url.replace(",", "%2C").replace("+", "%20")
    params = OAuth1Parameters(
      consumerKey: consumerKey,
      signatureMethod: "HMAC-SHA1",
      timestamp: $int(round(epochTime())),
      nonce: "0",
      isIncludeVersionToHeader: true,
      token: oauthToken
    )
    signature = getSignature(HttpGet, encodedUrl, "", params, consumerSecret, oauthTokenSecret)

  params.signature = percentEncode(signature)

  return getOauth1RequestHeader(params)["authorization"]

proc getCookieHeader(authToken, ct0: string): string =
  "auth_token=" & authToken & "; ct0=" & ct0

proc genHeaders*(session: Session, url: Uri, skipTid: bool): Future[HttpHeaders] {.async.} =
  result = newHttpHeaders({
    "accept": "*/*",
    "accept-encoding": "gzip",
    "accept-language": "en-US,en;q=0.9",
    "content-type": "application/json",
    "origin": "https://x.com",
    "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
    "x-twitter-active-user": "yes",
    "x-twitter-client-language": "en",
    "priority": "u=1, i"
  }, titleCase=true)

  case session.kind
  of SessionKind.oauth:
    result["authorization"] = getOauthHeader($url, session.oauthToken, session.oauthSecret)
  of SessionKind.cookie:
    result["x-twitter-auth-type"] = "OAuth2Session"
    result["x-csrf-token"] = session.ct0
    result["cookie"] = getCookieHeader(session.authToken, session.ct0)
    result["referer"] = "https://x.com/"
    result["sec-ch-ua"] = """"Google Chrome";v="142", "Chromium";v="142", "Not A(Brand";v="24""""
    result["sec-ch-ua-mobile"] = "?0"
    result["sec-ch-ua-platform"] = "Windows"
    result["sec-fetch-dest"] = "empty"
    result["sec-fetch-mode"] = "cors"
    result["sec-fetch-site"] = "same-origin"
    if disableTid or skipTid or "/1.1/" in url.path:
      result["authorization"] = bearerToken2
    else:
      result["authorization"] = bearerToken
      result["x-client-transaction-id"] = await genTid(url.path)

proc getAndValidateSession*(req: ApiReq): Future[Session] {.async.} =
  result = await getSession(req)
  case result.kind
  of SessionKind.oauth:
    if result.oauthToken.len == 0:
      echo "[sessions] Empty oauth token, session: ", result.pretty
      invalidate(result)
      raise newException(ProviderAuthError, "Empty provider OAuth credentials")
  of SessionKind.cookie:
    if result.authToken.len == 0 or result.ct0.len == 0:
      echo "[sessions] Empty cookie credentials, session: ", result.pretty
      invalidate(result)
      raise newException(ProviderAuthError, "Empty provider cookie credentials")

proc checkProviderCredentials(codes: seq[int]; session: var Session) =
  for code in codes:
    if code in [ord(expiredToken), ord(badToken), ord(locked), ord(couldntAuth), ord(noCsrf)]:
      invalidate(session)
      let error = newException(ProviderAuthError, "Provider rejected session credentials (code " & $code & ")")
      error.retryable = true
      raise error

proc checkProviderErrors(node: JsonNode; session: var Session; req: ApiReq;
                         retryAfter: int) =
  let codes = providerErrorCodes(node)
  checkProviderCredentials(codes, session)
  if ord(rateLimited) in codes:
    setLimited(session, req)
    raise rateLimitError(retryAfter)
  for code in codes:
    # Keep resource-level errors available to the existing timeline/user parsers.
    if code notin [ord(null), ord(noUserMatches), ord(protectedUser), ord(timeout),
                   ord(doesntExist), ord(unauthorized), ord(userNotFound), ord(suspended),
                   ord(tweetNotFound), ord(tweetNotAuthorized), ord(forbidden),
                   ord(badRequest), ord(tweetUnavailable), ord(tweetCensored)]:
      raise newException(InternalError, "Provider returned error code " & $code)

template fetchImpl(result, fetchBody) {.dirty.} =
  once:
    pool = HttpPool()

  try:
    var resp: AsyncResponse
    let skipTid = case session.kind
      of oauth: req.oauth.skipTid
      of cookie: req.cookie.skipTid
    let headers = await genHeaders(session, url, skipTid)

    pool.use(headers):
      template getContent =
        # TODO: this is a temporary simple implementation
        if apiProxy.len > 0 and "/1.1/" notin url.path:
          resp = await c.get(($url).replace("https://", apiProxy))
        else:
          resp = await c.get($url)
        result = await resp.body

      getContent()

      if resp.code == Http503:
        badClient = true
        raise newException(BadClientError, "Bad client")

    let cacheStatus = resp.headers.getOrDefault(npCache)
    if cacheStatus notin ["HIT", "STALE"] and resp.headers.hasKey(rlRemaining):
      try:
        let
          remaining = parseInt(resp.headers.getOrDefault(rlRemaining))
          reset = parseInt(resp.headers.getOrDefault(rlReset))
          limit = parseInt(resp.headers.getOrDefault(rlLimit))
        if remaining >= 0 and reset >= 0 and limit >= 0:
          session.setRateLimit(req, remaining, reset, limit)
      except ValueError:
        echo "[sessions] Ignoring invalid rate-limit headers, API: ", url.path

    let retryAfter = retryAfterSeconds(resp.headers)
    case classifyHttpStatus(resp.code)
    of httpRateLimited:
      raise rateLimitError(retryAfter)
    of httpAuthenticationFailed:
      # A proxy denial or generic 403 does not prove the cookie is invalid.
      # Only explicit credential error codes invalidate a session.
      try:
        let body = if resp.headers.getOrDefault("content-encoding") == "gzip": uncompress(result, dfGzip)
                   else: result
        checkProviderCredentials(providerErrorCodes(parseProviderResponse(body)), session)
      except ProviderAuthError:
        raise
      except CatchableError:
        discard
      raise newException(ProviderAuthError, "Provider returned HTTP " & resp.status)
    of httpBadClient:
      raise newException(ProviderUnavailableError, "Provider returned HTTP " & resp.status)
    of httpUnavailable:
      var resourceNotFound = false
      if resp.code == Http404:
        try:
          let body = if resp.headers.getOrDefault("content-encoding") == "gzip": uncompress(result, dfGzip)
                     else: result
          resourceNotFound = isResourceNotFoundResponse(body)
        except CatchableError:
          discard
      if not resourceNotFound:
        raise newException(ProviderUnavailableError, "Provider returned HTTP " & resp.status)
    of httpInvalidResponse:
      raise newException(InternalError, "Provider returned HTTP " & resp.status)
    of httpSuccess:
      discard

    if result.len > 0:
      if resp.headers.getOrDefault("content-encoding") == "gzip":
        result = uncompress(result, dfGzip)

      if isCloudflareHtml(result.strip):
        echo "[cloudflare] ", resp.status, " (", cfTitle(result), "), API: ", url.path, ", session: ", session.pretty
        raise newException(ProviderUnavailableError, "Provider returned a Cloudflare error page")

      if result.strip.startsWith("429 Too Many Requests"):
        echo "[sessions] 429 error, API: ", url.path, ", session: ", session.pretty
        raise rateLimitError(retryAfter)

    fetchBody

  except InternalError as e:
    raise e
  except RateLimitError as e:
    raise e
  except ProviderAuthError as e:
    raise e
  except ProviderUnavailableError as e:
    raise e
  except BadClientError as e:
    raise e
  except SslError as e:
    raise newException(BadClientError, e.msg)
  except ProtocolError as e:
    raise newException(BadClientError, e.msg)
  except IOError as e:
    raise newException(BadClientError, e.msg)
  except OSError as e:
    raise newException(BadClientError, e.msg)
  except CatchableError as e:
    let s = session.pretty
    echo "error: ", e.name, ", msg: ", e.msg, ", session: ", s, ", url: ", url
    raise newException(InternalError, "Provider response processing failed: " & $e.name)
  finally:
    release(session)

template retry(bod) {.dirty.} =
  var session: Session
  var retrySuccess = false
  var lastFailure: ref CatchableError
  for i in 0 ..< maxRetries:
    try:
      session = nil
      bod
      retrySuccess = true
      break
    except NoSessionsError:
      if not lastFailure.isNil:
        raise lastFailure
      raise
    except ProviderAuthError as e:
      if not e.retryable:
        raise
      lastFailure = e
      if i + 1 >= maxRetries:
        break
      echo "[sessions] Rejected credentials, trying another session (", i + 1, "/", maxRetries, ")..."
      if retryDelayMs > 0:
        await sleepAsync(retryDelayMs)
    except RateLimitError as e:
      lastFailure = e
      if i + 1 >= maxRetries:
        break
      let api = if session.isNil: req.cookie.endpoint
                else: req.endpoint(session)
      if session.isNil:
        echo "[sessions] Rate limited, retrying ", api,
             " request (", i + 1, "/", maxRetries, ")..."
      else:
        echo "[sessions] Rate limited, retrying ", api,
             " request (", i + 1, "/", maxRetries, ")..., session: ", session.pretty
      session = nil
      if retryDelayMs > 0:
        await sleepAsync(retryDelayMs)
  if not retrySuccess:
    if not lastFailure.isNil:
      raise lastFailure
    raise rateLimitError()

proc fetch*(req: ApiReq): Future[JsonNode] {.async.} =
  retry:
    var body: string
    session = await getAndValidateSession(req)

    let url = req.toUrl(session.kind)

    fetchImpl body:
      result = parseProviderResponse(body)
      checkProviderErrors(result, session, req, retryAfter)

proc fetchRaw*(req: ApiReq): Future[string] {.async.} =
  retry:
    session = await getAndValidateSession(req)
    let url = req.toUrl(session.kind)

    fetchImpl result:
      let parsed = parseProviderResponse(result)
      checkProviderErrors(parsed, session, req, retryAfter)
      result = result.strip
