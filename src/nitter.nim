# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, strformat, strutils, logging
from net import Port
from htmlgen import a
from os import getEnv, normalizedPath

import jester

import types, config, prefs, formatters, redis_cache, http_pool, auth, apiutils
import views/[general, about]
import routes/[
  preferences, timeline, status, media, search, rss, list, community, debug,
  unsupported, embed, resolver, broadcast, api_router, space, article,
  router_utils]

const instancesUrl = "https://github.com/zedeus/nitter/wiki/Instances"
const issuesUrl = "https://github.com/zedeus/nitter/issues"

let
  configPath = getEnv("NITTER_CONF_FILE", "./nitter.conf")
  (cfg, fullCfg) = getConfig(configPath)

  sessionsPath = getEnv("NITTER_SESSIONS_FILE", "./sessions.jsonl")

initSessionPool(cfg, sessionsPath)

if not cfg.enableDebug:
  # Silence Jester's query warning
  addHandler(newConsoleLogger())
  setLogFilter(lvlError)

stdout.write &"Starting Nitter at {getUrlPrefix(cfg)}\n"
stdout.flushFile

updateDefaultPrefs(fullCfg)
setCacheTimes(cfg)
setHmacKey(cfg.hmacKey)
if cfg.hmacKey.len == 0 or cfg.hmacKey == "secretkey":
  stderr.write "WARNING: insecure default 'hmacKey' in nitter.conf; " &
    "set a unique random value to stop media URL signatures being forgeable.\n"
  stderr.flushFile
setProxyEncoding(cfg.base64Media)
setMaxHttpConns(cfg.httpMaxConns)
setHttpProxy(cfg.proxy, cfg.proxyAuth)
setApiProxy(cfg.apiProxy)
setDisableTid(cfg.disableTid)
setMaxConcurrentReqs(cfg.maxConcurrentReqs)
setMaxRetries(cfg.maxRetries)
setRetryDelayMs(cfg.retryDelayMs)
initAboutPage(cfg.staticDir)

waitFor initRedisPool(cfg)
stdout.write &"Connected to Redis at {cfg.redisHost}:{cfg.redisPort}\n"
stdout.flushFile

createArticleRouter(cfg)
createUnsupportedRouter(cfg)
createResolverRouter(cfg)
createPrefRouter(cfg)
createTimelineRouter(cfg)
createListRouter(cfg)
createCommunityRouter(cfg)
createStatusRouter(cfg)
createSearchRouter(cfg)
createMediaRouter(cfg)
createEmbedRouter(cfg)
createRssRouter(cfg)
createBroadcastRouter(cfg)
createApiRouter(cfg)
createSpaceRouter(cfg)
createDebugRouter(cfg)

settings:
  port = Port(cfg.port)
  staticDir = normalizedPath(cfg.staticDir)
  bindAddr = cfg.address
  reusePort = true
  maxBody = 64 * 1024

routes:
  before:
    # Reject malformed paths
    if request.path.len == 0 or request.path[0] != '/':
      halt Http400

    # skip all file URLs (except Twitter widget compatibility)
    cond "." notin request.path or request.path == "/embed/Tweet.html"
    applyUrlPrefs()

  get "/":
    resp renderMain(renderSearch(), request, cfg, requestPrefs())

  get "/about":
    resp renderMain(renderAbout(), request, cfg, requestPrefs())

  get "/explore":
    redirect("/about")

  get "/help":
    redirect("/about")

  get "/i/redirect":
    let url = decodeUrl(@"url")
    if url.len == 0: resp Http404
    redirect(replaceUrls(url, requestPrefs()))

  error Http404:
    resp Http404, showError("Page not found", cfg)

  error InternalError:
    echo error.exc.name, ": ", error.exc.msg
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderInvalidResponse)
      resp response.status, jsonHeaders, response.body
    else:
      const link = a("open a GitHub issue", href = issuesUrl)
      resp Http500, showError(
        &"An error occurred, please {link} with the URL you tried to visit.", cfg)

  error ProviderUnavailableError:
    echo error.exc.name, ": ", error.exc.msg
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderUnavailable)
      resp response.status, jsonHeaders, response.body
    else:
      resp Http503, showError("Provider is unavailable, please try again later.", cfg)

  error ProviderAuthError:
    echo error.exc.name, ": ", error.exc.msg
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderAuthenticationFailed)
      resp response.status, jsonHeaders, response.body
    else:
      resp Http503, showError("Provider authentication failed, please try again later.", cfg)

  error BadClientError:
    echo error.exc.name, ": ", error.exc.msg
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderUnavailable)
      resp response.status, jsonHeaders, response.body
    else:
      resp Http503, showError("Network error occurred, please try again.", cfg)

  error RateLimitError:
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderRateLimited)
      var headers = @jsonHeaders
      let retryAfter = (ref RateLimitError)(error.exc).retryAfter
      if retryAfter > 0:
        headers.add ("Retry-After", $retryAfter)
      resp response.status, headers, response.body
    else:
      const link = a("another instance", href = instancesUrl)
      resp Http429, showError(
        &"Instance has been rate limited.<br>Use {link} or try again later.", cfg)

  error NoSessionsError:
    if request.path.startsWith("/api/"):
      let response = apiProviderFailureResponse(apiProviderRateLimited)
      resp response.status, jsonHeaders, response.body
    else:
      const link = a("another instance", href = instancesUrl)
      resp Http429, showError(
        &"Instance has no auth tokens, or is fully rate limited.<br>Use {link} or try again later.", cfg)

  extend articleRoute, ""
  extend rss, ""
  extend status, ""
  extend search, ""
  extend timeline, ""
  extend media, ""
  extend list, ""
  extend community, ""
  extend preferences, ""
  extend resolver, ""
  extend embed, ""
  extend broadcastRoute, ""
  extend apiRoute, ""
  extend spaceRoute, ""
  extend debug, ""
  extend unsupported, ""
