import json
from urllib.request import urlopen


VIDEO_TWEET_ID = "1078373829917974528"
BASE_URL = "http://localhost:8080"


def fetch_json(path):
    with urlopen(f"{BASE_URL}{path}") as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


def test_post_video_media_has_url_and_variants():
    payload = fetch_json(f"/api/post/{VIDEO_TWEET_ID}")
    media = payload["tweet"]["media"]
    videos = [item for item in media if item["type"] == "video"]

    assert videos

    video = videos[0]
    variants = video["variants"]

    assert video["url"]
    assert video["thumbnail"]
    assert variants
    assert video["url"] in {variant["url"] for variant in variants}
    assert any(variant["contentType"] == video["playbackType"] for variant in variants)
