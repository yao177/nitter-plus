# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, json, options, sequtils, strutils, tables, times

import jester

import router_utils
import ".."/[api, formatters, query, redis_cache, types, utils]

export json

const
  jsonHeaders* = {"Content-Type": "application/json; charset=utf-8"}
  validUsernameChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

type
  ApiProviderFailure* = enum
    apiProviderUnavailable
    apiProviderRateLimited

proc jsonError*(message: string): JsonNode =
  %*{"error": message}

proc apiProviderFailureResponse*(failure: ApiProviderFailure):
    tuple[status: HttpCode, body: string] =
  case failure
  of apiProviderUnavailable:
    (Http503, $jsonError("provider_unavailable"))
  of apiProviderRateLimited:
    (Http429, $jsonError("provider_rate_limited"))

proc isValidUsername(name: string): bool =
  name.len > 0 and name.len <= 15 and name.allCharsInSet(validUsernameChars)

proc isValidTweetId*(id: string): bool =
  id.len > 0 and id.len <= 19 and id.allCharsInSet({'0'..'9'})

proc toIso(dt: DateTime): JsonNode =
  if dt.year <= 1:
    newJNull()
  else:
    %dt.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc verifiedToJson(verifiedType: VerifiedType): JsonNode =
  if verifiedType == VerifiedType.none:
    newJNull()
  else:
    %($verifiedType)

const twitterBaseUrl = "https://x.com"

proc isAbsoluteUrl(url: string): bool =
  url.startsWith("http://") or url.startsWith("https://")

proc toTwitterMediaUrl(url: string): string =
  if url.len == 0 or url.startsWith('#') or url.isAbsoluteUrl:
    return url

  let normalized =
    if url.startsWith('/'):
      url[1 .. ^1]
    else:
      url

  let slashIdx = normalized.find('/')
  let host =
    if slashIdx >= 0: normalized[0 ..< slashIdx]
    else: normalized

  if '.' in host:
    return https & normalized

  https & twimg & normalized

proc toTwitterStatusUrl(tweet: Tweet): string =
  if tweet.isNil or tweet.id == 0:
    return ""

  var username = tweet.user.username
  if username.len == 0:
    username = "i"

  twitterBaseUrl & "/" & username & "/status/" & $tweet.id

proc videoVariantToJson(variant: VideoVariant): JsonNode =
  %*{
    "bitrate": variant.bitrate,
    "contentType": $variant.contentType,
    "url": toTwitterMediaUrl(variant.url),
    "resolution": variant.resolution
  }

proc userToJson*(user: User): JsonNode =
  %*{
    "id": user.id,
    "username": user.username,
    "fullname": user.fullname,
    "bio": stripHtml(user.bio),
    "location": user.location,
    "website": user.website,
    "avatar": toTwitterMediaUrl(user.getUserPic("_400x400")),
    "banner": toTwitterMediaUrl(user.banner),
    "following": user.following,
    "followers": user.followers,
    "posts": user.tweets,
    "likes": user.likes,
    "verifiedType": verifiedToJson(user.verifiedType),
    "protected": user.protected,
    "suspended": user.suspended,
    "joinedAt": toIso(user.joinDate)
  }

proc mediaToJson(media: Media): JsonNode =
  case media.kind
  of photoMedia:
    %*{
      "type": "photo",
      "url": toTwitterMediaUrl(media.photo.url),
      "altText": media.photo.altText
    }
  of videoMedia:
    let variants = media.video.variants.filterIt(it.url.len > 0)
    %*{
      "type": "video",
      "url": toTwitterMediaUrl(media.video.getVideoUrl),
      "thumbnail": toTwitterMediaUrl(media.video.thumb),
      "available": media.video.available,
      "reason": media.video.reason,
      "durationMs": media.video.durationMs,
      "playbackType": $media.video.getPlayablePlaybackType,
      "variants": variants.mapIt(videoVariantToJson(it))
    }
  of gifMedia:
    %*{
      "type": "gif",
      "url": toTwitterMediaUrl(media.gif.url),
      "thumbnail": toTwitterMediaUrl(media.gif.thumb),
      "altText": media.gif.altText
    }

proc pollToJson(poll: Poll): JsonNode =
  var options = newJArray()
  for i, text in poll.options:
    let votes = if i < poll.values.len: poll.values[i] else: 0
    options.add %*{
      "label": text,
      "votes": votes,
      "leading": i == poll.leader
    }

  %*{
    "options": options,
    "votes": poll.votes,
    "status": poll.status
  }

proc tweetToJson*(tweet: Tweet; includeQuote=true): JsonNode =
  if tweet.isNil:
    return newJNull()

  var node = %*{
    "id": $tweet.id,
    "threadId": $tweet.threadId,
    "replyId": $tweet.replyId,
    "url": toTwitterStatusUrl(tweet),
    "user": userToJson(tweet.user),
    "text": stripHtml(tweet.text),
    "html": tweet.text,
    "createdAt": toIso(tweet.time),
    "replyingTo": tweet.reply,
    "pinned": tweet.pinned,
    "hasThread": tweet.hasThread,
    "available": tweet.available,
    "tombstone": tweet.tombstone,
    "location": tweet.location,
    "stats": %*{
      "replies": tweet.stats.replies,
      "retweets": tweet.stats.retweets,
      "likes": tweet.stats.likes,
      "views": tweet.stats.views
    },
    "media": tweet.media.mapIt(mediaToJson(it)),
    "note": tweet.note,
    "isAd": tweet.isAd,
    "isAI": tweet.isAI
  }

  if tweet.poll.isSome:
    node["poll"] = pollToJson(tweet.poll.get)
  if includeQuote and tweet.quote.isSome:
    node["quote"] = tweetToJson(tweet.quote.get, includeQuote=false)
  if tweet.retweet.isSome:
    node["retweet"] = tweetToJson(tweet.retweet.get, includeQuote=false)

  node

proc tweetsToJson*(tweets: Tweets): JsonNode =
  result = newJArray()
  for tweet in tweets:
    result.add tweetToJson(tweet)

proc timelineToJson*(timeline: Timeline): JsonNode =
  var items = newJArray()
  for group in timeline.content:
    for tweet in group:
      items.add tweetToJson(tweet)

  %*{
    "items": items,
    "nextCursor": timeline.bottom,
    "previousCursor": timeline.top,
    "beginning": timeline.beginning
  }

proc postSearchToJson*(query: Query; cursor: string): Future[JsonNode] {.async.} =
  let timeline = await getGraphTweetSearch(query, cursor)
  result = timelineToJson(timeline)
  result["query"] = %query.text

proc authToken*(req: Request): string =
  let headers = req.getNativeReq().headers
  let bearer = headers.getOrDefault("Authorization")
  if bearer.startsWith("Bearer "):
    return bearer[7..^1]
  headers.getOrDefault("X-API-Key")

template requireApi*(cfg: Config; request: Request) =
  if not cfg.enableApi:
    resp Http404, jsonHeaders, $jsonError("API is disabled")
  if cfg.apiKey.len > 0 and authToken(request) != cfg.apiKey:
    resp Http401, jsonHeaders, $jsonError("Invalid API key")

template requireUsername*(name: string) =
  if not isValidUsername(name):
    resp Http400, jsonHeaders, $jsonError("Invalid username")

proc createApiRouter*(cfg: Config) =
  router apiRoute:
    get "/api/user/@name":
      requireApi(cfg, request)
      let name = @"name"
      requireUsername(name)

      let user = await getCachedUser(name)
      if user.id.len == 0 and not user.suspended:
        resp Http404, jsonHeaders, $jsonError("User not found")
      resp Http200, jsonHeaders, $userToJson(user)

    get "/api/user/@name/@kind":
      requireApi(cfg, request)
      let
        name = @"name"
        kind = @"kind"
      requireUsername(name)
      if kind notin ["posts", "replies", "media"]:
        resp Http404, jsonHeaders, $jsonError("API endpoint not found")

      let
        cursor = getCursor()
        timelineKind = case kind
          of "replies": TimelineKind.replies
          of "media": TimelineKind.media
          else: TimelineKind.tweets
        userId = await getUserId(name)

      if userId.len == 0:
        resp Http404, jsonHeaders, $jsonError("User not found")
      if userId == "suspended":
        resp Http404, jsonHeaders, $jsonError("User is suspended")

      var profile = await getGraphUserTweets(userId, timelineKind, cursor)
      profile.user = await getCachedUser(name)

      var node = timelineToJson(profile.tweets)
      node["user"] = userToJson(profile.user)
      resp Http200, jsonHeaders, $node

    get "/api/post/@id":
      requireApi(cfg, request)
      let id = @"id"
      if not isValidTweetId(id):
        resp Http400, jsonHeaders, $jsonError("Invalid post ID")

      let conv = await getTweet(id, getCursor())
      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        resp Http404, jsonHeaders, $jsonError("Post not found")

      var replyItems = newJArray()
      for chain in conv.replies.content:
        replyItems.add %*{
          "items": tweetsToJson(chain.content),
          "hasMore": chain.hasMore,
          "cursor": chain.cursor
        }

      let node = %*{
        "tweet": tweetToJson(conv.tweet),
        "before": %*{
          "items": tweetsToJson(conv.before.content),
          "hasMore": conv.before.hasMore,
          "cursor": conv.before.cursor
        },
        "after": %*{
          "items": tweetsToJson(conv.after.content),
          "hasMore": conv.after.hasMore,
          "cursor": conv.after.cursor
        },
        "replies": %*{
          "items": replyItems,
          "nextCursor": conv.replies.bottom,
          "previousCursor": conv.replies.top,
          "beginning": conv.replies.beginning
        }
      }
      resp Http200, jsonHeaders, $node

    get "/api/search/posts":
      requireApi(cfg, request)
      if @"q".len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing q parameter")
      if @"q".len > 500:
        resp Http400, jsonHeaders, $jsonError("Search input too long")

      var queryParams = params(request)
      queryParams["f"] = "tweets"
      let query = initQuery(queryParams)

      let node = await postSearchToJson(query, getCursor())
      resp Http200, jsonHeaders, $node

    post "/api/search/posts":
      requireApi(cfg, request)
      let body = request.body
      if body.len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing JSON body")

      var js: JsonNode
      try:
        js = parseJson(body)
      except JsonParsingError:
        resp Http400, jsonHeaders, $jsonError("Invalid JSON body")

      if js.kind != JObject:
        resp Http400, jsonHeaders, $jsonError("Invalid JSON body")

      let q = js{"q"}.getStr
      if q.len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing q parameter")
      if q.len > 500:
        resp Http400, jsonHeaders, $jsonError("Search input too long")

      let node = await postSearchToJson(Query(kind: tweets, text: q), js{"cursor"}.getStr)
      resp Http200, jsonHeaders, $node
