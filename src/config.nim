# SPDX-License-Identifier: AGPL-3.0-only
import os
import parsecfg except Config
import types, strutils

proc get*[T](config: parseCfg.Config; section, key: string; default: T): T =
  let val = config.getSectionValue(section, key)
  if val.len == 0: return default

  when T is int: parseInt(val)
  elif T is bool: parseBool(val)
  elif T is string: val

proc getEnvOverride[T](name: string; default: T): T =
  let val = getEnv(name)
  if val.len == 0: return default

  when T is int: parseInt(val)
  elif T is bool: parseBool(val)
  elif T is string: val

proc getConfig*(path: string): (Config, parseCfg.Config) =
  var cfg = loadConfig(path)

  let masterRss = cfg.get("Config", "enableRSS", true)

  let conf = Config(
    # Server
    address: cfg.get("Server", "address", "0.0.0.0"),
    port: cfg.get("Server", "port", 8080),
    useHttps: cfg.get("Server", "https", true),
    httpMaxConns: cfg.get("Server", "httpMaxConnections", 100),
    staticDir: cfg.get("Server", "staticDir", "./public"),
    title: cfg.get("Server", "title", "Nitter"),
    hostname: cfg.get("Server", "hostname", "nitter.net"),

    # Cache
    listCacheTime: cfg.get("Cache", "listMinutes", 120),
    rssCacheTime: cfg.get("Cache", "rssMinutes", 10),

    redisHost: cfg.get("Cache", "redisHost", "localhost"),
    redisPort: cfg.get("Cache", "redisPort", 6379),
    redisConns: cfg.get("Cache", "redisConnections", 20),
    redisMaxConns: cfg.get("Cache", "redisMaxConnections", 30),
    redisPassword: cfg.get("Cache", "redisPassword", ""),

    # Config
    hmacKey: cfg.get("Config", "hmacKey", "secretkey"),
    base64Media: cfg.get("Config", "base64Media", false),
    minTokens: cfg.get("Config", "tokenCount", 10),
    enableRSSUserTweets: masterRss and cfg.get("Config", "enableRSSUserTweets", true),
    enableRSSUserReplies: masterRss and cfg.get("Config", "enableRSSUserReplies", true),
    enableRSSUserMedia: masterRss and cfg.get("Config", "enableRSSUserMedia", true),
    enableRSSUserArticles: masterRss and cfg.get("Config", "enableRSSUserArticles", true),
    enableRSSSearch: masterRss and cfg.get("Config", "enableRSSSearch", true),
    enableRSSList: masterRss and cfg.get("Config", "enableRSSList", true),
    enableDebug: cfg.get("Config", "enableDebug", false),
    enableApi: getEnvOverride("NITTER_ENABLE_API", cfg.get("Config", "enableApi", false)),
    apiKey: getEnvOverride("NITTER_API_KEY", cfg.get("Config", "apiKey", "")),
    proxy: cfg.get("Config", "proxy", ""),
    proxyAuth: cfg.get("Config", "proxyAuth", ""),
    apiProxy: cfg.get("Config", "apiProxy", ""),
    disableTid: cfg.get("Config", "disableTid", false),
    maxConcurrentReqs: cfg.get("Config", "maxConcurrentReqs", 2),
    maxRetries: cfg.get("Config", "maxRetries", 1),
    retryDelayMs: cfg.get("Config", "retryDelayMs", 150)
  )

  if conf.minTokens < 0:
    raise newException(ValueError, "Config.tokenCount must be nonnegative")

  return (conf, cfg)
