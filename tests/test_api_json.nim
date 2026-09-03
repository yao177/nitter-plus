import std/[httpcore, json, options, unittest]

import ../src/routes/api_router
import ../src/types

suite "API JSON serialization":
  test "maps provider availability failures to stable JSON responses":
    let unavailable = apiProviderFailureResponse(apiProviderUnavailable)
    check unavailable.status == Http503
    check parseJson(unavailable.body)["error"].getStr == "provider_unavailable"

    let rateLimited = apiProviderFailureResponse(apiProviderRateLimited)
    check rateLimited.status == Http429
    check parseJson(rateLimited.body)["error"].getStr == "provider_rate_limited"

  test "converts relative API media and route URLs to native absolute URLs":
    let tweet = Tweet(
      id: 1,
      threadId: 1,
      user: User(
        id: "1",
        username: "tester",
        userPic: "profile_images/tester_normal.jpg",
        banner: "profile_banners/1/1500x500"
      ),
      text: "media",
      available: true,
      media: @[
        Media(
          kind: photoMedia,
          photo: Photo(url: "media/photo.jpg", altText: "photo")
        ),
        Media(
          kind: gifMedia,
          gif: Gif(
            url: "video.twimg.com/tweet_video/clip.mp4",
            thumb: "tweet_video_thumb/clip.jpg",
            altText: "gif"
          )
        ),
        Media(
          kind: videoMedia,
          video: Video(
            available: true,
            thumb: "ext_tw_video_thumb/clip.jpg",
            variants: @[
              VideoVariant(contentType: m3u8, url: "video.twimg.com/master.m3u8")
            ]
          )
        )
      ],
      quote: some Tweet(
        id: 3,
        threadId: 3,
        user: User(id: "3", username: "quoted"),
        text: "quote",
        available: true
      )
    )

    let node = tweetToJson(tweet)
    check node["url"].getStr == "https://x.com/tester/status/1"
    check node["user"]["avatar"].getStr == "https://pbs.twimg.com/profile_images/tester_400x400.jpg"
    check node["user"]["banner"].getStr == "https://pbs.twimg.com/profile_banners/1/1500x500"
    check node["media"][0]["url"].getStr == "https://pbs.twimg.com/media/photo.jpg"
    check node["media"][1]["url"].getStr == "https://video.twimg.com/tweet_video/clip.mp4"
    check node["media"][1]["thumbnail"].getStr == "https://pbs.twimg.com/tweet_video_thumb/clip.jpg"
    check node["media"][2]["url"].getStr == "https://video.twimg.com/master.m3u8"
    check node["media"][2]["thumbnail"].getStr == "https://pbs.twimg.com/ext_tw_video_thumb/clip.jpg"
    check node["media"][2]["variants"][0]["url"].getStr == "https://video.twimg.com/master.m3u8"
    check node["quote"]["url"].getStr == "https://x.com/quoted/status/3"

  test "preserves color banners while absolutizing avatars":
    let user = User(
      id: "2",
      username: "tester",
      userPic: "profile_images/tester_normal.jpg",
      banner: "#336699"
    )

    let node = userToJson(user)
    check node["avatar"].getStr == "https://pbs.twimg.com/profile_images/tester_400x400.jpg"
    check node["banner"].getStr == "#336699"

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
            thumb: "ext_tw_video_thumb/thumb.jpg",
            variants: @[
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/low.mp4",
                           bitrate: 256_000, resolution: 360),
              VideoVariant(contentType: mp4, url: "https://video.twimg.com/high.mp4",
                           bitrate: 832_000, resolution: 720),
              VideoVariant(contentType: m3u8, url: "video.twimg.com/master.m3u8")
            ]
          )
        )
      ]
    )

    let video = tweetToJson(tweet)["media"][0]
    check video["url"].getStr == "https://video.twimg.com/master.m3u8"
    check video["playbackType"].getStr == "application/x-mpegURL"
    check video["thumbnail"].getStr == "https://pbs.twimg.com/ext_tw_video_thumb/thumb.jpg"
    check video["variants"].len == 3
    check video["variants"][2]["url"].getStr == "https://video.twimg.com/master.m3u8"

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
            thumb: "ext_tw_video_thumb/thumb.jpg",
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
    check video["thumbnail"].getStr == "https://pbs.twimg.com/ext_tw_video_thumb/thumb.jpg"
    check video["variants"].len == 2
