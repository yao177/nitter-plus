import std/[json, unittest]

import ../src/routes/api_router
import ../src/types

suite "API video serialization":
  test "prefers HLS video URLs when available":
    let tweet = Tweet(
      id: 1,
      threadId: 1,
      user: User(id: "1", username: "tester"),
      text: "video",
      available: true,
      media: @[
        Media(
          kind: videoMedia,
          video: Video(
            available: true,
            thumb: "/thumb.jpg",
            variants: @[
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/low.mp4",
                           bitrate: 256_000, resolution: 360),
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/high.mp4",
                           bitrate: 832_000, resolution: 720),
              VideoVariant(contentType: m3u8, url: "https://video.twimg.com/master.m3u8")
            ]
          )
        )
      ]
    )

    let video = tweetToJson(tweet)["media"][0]
    check video["url"].getStr == "https://video.twimg.com/master.m3u8"
    check video["playbackType"].getStr == "application/x-mpegURL"
    check video["variants"].len == 3

  test "falls back to the highest resolution mp4 URL":
    let tweet = Tweet(
      id: 2,
      threadId: 2,
      user: User(id: "2", username: "tester"),
      text: "video",
      available: true,
      media: @[
        Media(
          kind: videoMedia,
          video: Video(
            available: true,
            thumb: "/thumb.jpg",
            variants: @[
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/360.mp4",
                           bitrate: 256_000, resolution: 360),
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/1080.mp4",
                           bitrate: 2_176_000, resolution: 1080)
            ]
          )
        )
      ]
    )

    let video = tweetToJson(tweet)["media"][0]
    check video["url"].getStr == "https://video.twimg.com/1080.mp4"
    check video["playbackType"].getStr == "video/mp4"
    check video["variants"].len == 2
