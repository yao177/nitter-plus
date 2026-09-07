# SPDX-License-Identifier: AGPL-3.0-only
import std/[httpcore, strutils, times]
import packedjson
import types

type HttpFailureKind* = enum
  httpSuccess, httpRateLimited, httpAuthenticationFailed, httpBadClient,
  httpUnavailable, httpInvalidResponse

proc classifyHttpStatus*(status: HttpCode): HttpFailureKind =
  case status.int
  of 401, 403: httpAuthenticationFailed
  of 429: httpRateLimited
  of 503: httpBadClient
  of 404, 500 .. 502, 504 .. 599: httpUnavailable
  of 200 .. 299: httpSuccess
  else: httpInvalidResponse

proc retryAfterSeconds*(headers: HttpHeaders; now = epochTime().int64): int =
  let value = headers.getOrDefault("retry-after").strip
  if value.len == 0:
    return 0
  try:
    return max(0, parseInt(value))
  except ValueError:
    discard
  try:
    return max(0'i64, parse(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()).toTime.toUnix - now).int
  except TimeParseError:
    return 0

proc parseProviderResponse*(body: string): JsonNode =
  let normalized = body.strip
  if normalized.len == 0 or normalized[0] notin {'{', '['}:
    raise newException(InternalError, "Provider returned an empty or non-JSON response")
  try:
    result = parseJson(normalized)
  except CatchableError:
    raise newException(InternalError, "Provider returned invalid JSON")

proc providerErrorCodes*(node: JsonNode): seq[int] =
  let errors = if node.kind == JObject: node{"errors"}
               elif node.kind == JArray: node
               else: packedjson.newJNull()
  if errors.kind == JNull:
    return
  if errors.kind != JArray:
    raise newException(InternalError, "Provider returned an invalid errors field")
  for entry in errors:
    let code = entry{"code"}
    if code.kind == JInt:
      result.add code.getInt
    elif node.kind == JObject:
      raise newException(InternalError, "Provider returned an error without a numeric code")

proc isResourceNotFoundResponse*(body: string): bool =
  try:
    let
      node = parseProviderResponse(body)
      codes = providerErrorCodes(node)
    if codes.len == 0 or (node.kind == JArray and codes.len != node.len):
      return false
    for code in codes:
      if code notin [ord(noUserMatches), ord(doesntExist), ord(userNotFound),
                     ord(tweetNotFound), ord(tweetUnavailable)]:
        return false
    return true
  except InternalError:
    return false
