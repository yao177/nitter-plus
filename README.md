# Nitter

> [!NOTE]
> On 24 August 2026 cease and desist letters were sent by X Corp. demanding a permanent takedown of Nitter instances and the project's repository.

A free and open source alternative Twitter front-end focused on privacy and
performance. \
Inspired by the [Invidious](https://github.com/iv-org/invidious) project.

## Donations

**Liberapay**: https://liberapay.com/zedeus<br>
**Patreon**: https://patreon.com/nitter<br>
**Ko-fi**: https://ko-fi.com/zedeus<br>
**BTC**: bc1qpqpzjkcpgluhzf7x9yqe7jfe8gpfm5v08mdr55<br>
**ETH**: 0x24a0DB59A923B588c7A5EBd0dBDFDD1bCe9c4460<br>
**XMR**: 42hKayRoEAw4D6G6t8mQHPJHQcXqofjFuVfavqKeNMNUZfeJLJAcNU19i1bGdDvcdN6romiSscWGWJCczFLe9RFhM3d1zpL<br>
**SOL**: FF5bheiD5AqPEdc3eyjymJ8AoMRF1hS78Ht6FiSZZF1t<br>
**$Nitter**: 4fSxCKc91ELQYVdv3tmHW8R15KoALPwEngyoQe1Xpump<br>
**ZEC**: u1vndfqtzyy6qkzhkapxelel7ams38wmfeccu3fdpy2wkuc4erxyjm8ncjhnyg747x6t0kf0faqhh2hxyplgaum08d2wnj4n7cyu9s6zhxkqw2aef4hgd4s6vh5hpqvfken98rg80kgtgn64ff70djy7s8f839z00hwhuzlcggvefhdlyszkvwy3c7yw623vw3rvar6q6evd3xcvveypt

## Features

- No JavaScript or ads
- All requests go through the backend, client never talks to Twitter
- Prevents Twitter from tracking your IP or JavaScript fingerprint
- Uses Twitter's unofficial API (no developer account required)
- Lightweight (for [@nim_lang](https://nitter.net/nim_lang), 60KB vs 784KB from twitter.com)
- RSS feeds
- JSON API
- Themes
- Mobile support (responsive design)
- AGPLv3 licensed, no proprietary instances permitted

## Roadmap

- Embeds
- Account system with timeline support
- Archiving tweets/profiles

## JSON API

The JSON API is disabled by default. Enable it in `nitter.conf`:

```ini
[Config]
enableApi = true
apiKey = "change-me"
```

The same settings can be configured with environment variables:

```bash
NITTER_ENABLE_API=true
NITTER_API_KEY=change-me
```

When `apiKey` is set, send it as `Authorization: Bearer <key>` or `X-API-Key`.

Available endpoints:

- `GET /api/user/@name`
- `GET /api/user/@name/posts?cursor=...`
- `GET /api/user/@name/replies?cursor=...`
- `GET /api/user/@name/media?cursor=...`
- `GET /api/post/@id?cursor=...`
- `GET /api/search/posts?q=...&cursor=...`
- `POST /api/search/posts` with JSON body `{ "q": "...", "cursor": "..." }`

### Provider Errors / 上游错误

Provider failures return JSON with an `error` field. HTTP 429 means an actual
upstream rate limit (`provider_rate_limited`); a valid upstream `Retry-After`
is forwarded in seconds. HTTP 503 reports transport/server failures
(`provider_unavailable`) or unusable provider credentials
(`provider_authentication_failed`). Invalid upstream responses return HTTP 502
(`provider_invalid_response`), never a successful empty result. Caller API-key
rejection remains HTTP 401 and does not rotate or change the configured key.
Generic upstream 401/403 responses do not invalidate cookies; explicit credential
error codes do. Existing resource-level errors remain handled by Nitter's parsers.
HTTP classification uses numeric status codes, regardless of reason phrases.
A 404 body with recognized resource-not-found codes keeps the existing parser
behavior; empty, malformed, or unknown 404 responses remain provider-unavailable.

上游故障返回含 `error` 字段的 JSON。HTTP 429 仅表示真实上游限流
（`provider_rate_limited`），有效的上游 `Retry-After` 会转换为秒并透传。
HTTP 503 表示传输或服务故障（`provider_unavailable`），或者上游凭据不可用
（`provider_authentication_failed`）。无效上游响应返回 HTTP 502
（`provider_invalid_response`），不会伪装成成功的空结果。调用方 API key
被拒绝时仍返回 HTTP 401，不会轮换或修改已配置的密钥。普通上游 401/403
不会使 Cookie 失效；明确的凭据错误码才会移除对应会话。资源级错误仍交由
Nitter 原有解析器处理。
HTTP 分类只依据数值状态码，不依赖原因短语。404 响应中的已识别资源不存在
错误仍交由原有解析器处理；空、损坏或未知的 404 响应仍归为上游不可用。

Offline regression tests require a compiled `./nitter`, Python 3, and
`redis-server` or `valkey-server`. They use disposable loopback-only instances
and fake credentials, without contacting X:

离线回归测试需要已编译的 `./nitter`、Python 3 和 `redis-server` 或
`valkey-server`。测试使用仅绑定本机回环地址的临时实例与假凭据，不访问 X：

```bash
nim c -r tests/test_provider_errors.nim
nim c -r tests/test_apiutils_retry.nim
python3 tests/test_provider_http.py
```

To verify every fork-added API against a running instance, use the bounded live
contract runner below. It tests both authentication headers, input validation,
all seven API operations, and actual next-page cursors. A missing cursor remains
explicitly unverified. Rate limiting or provider authentication failure stops
the run; `--only` selects unfinished operations for a later targeted check.
The report contains no credentials, response bodies, or raw cursors.

使用以下有界真实契约测试验证运行实例相对上游新增的全部 API，覆盖两种鉴权头、
输入校验、七个 API 操作和实际下一页游标。缺少游标会明确标为未验证；发生限流
或上游认证失败时立即停止。可使用 `--only` 选择未完成操作定向补测。报告不含凭据、
响应正文或原始游标。

```bash
python3 tests/test_api_live_contract.py
python3 tests/api_live_contract.py --base-url http://127.0.0.1:8080 \
  --api-key-file /path/to/existing-api-key --username NASA --report api-contract.json
```

## Resources

The wiki contains
[a list of instances](https://github.com/zedeus/nitter/wiki/Instances) and
[browser extensions](https://github.com/zedeus/nitter/wiki/Extensions)
maintained by the community.

## Why?

It's impossible to use Twitter without JavaScript enabled, and as of 2024 you
need to sign up. For privacy-minded folks, preventing JavaScript analytics and
IP-based tracking is important, but apart from using a VPN and uBlock/uMatrix,
it's impossible. Despite being behind a VPN and using heavy-duty adblockers,
you can get accurately tracked with your [browser's
fingerprint](https://restoreprivacy.com/browser-fingerprinting/), [no
JavaScript required](https://noscriptfingerprint.com/). This all became
particularly important after Twitter [removed the
ability](https://www.eff.org/deeplinks/2020/04/twitter-removes-privacy-option-and-shows-why-we-need-strong-privacy-laws)
for users to control whether their data gets sent to advertisers.

Using an instance of Nitter (hosted on a VPS for example), you can browse
Twitter without JavaScript while retaining your privacy. In addition to
respecting your privacy, Nitter is on average around 15 times lighter than
Twitter, and in most cases serves pages faster (eg. timelines load 2-4x faster).

In the future a simple account system will be added that lets you follow Twitter
users, allowing you to have a clean chronological timeline without needing a
Twitter account.

## Screenshot

![nitter](/screenshot.png)

## Installation

### Dependencies

- libpcre
- libsass
- redis/valkey

To compile Nitter you need a Nim installation, see
[nim-lang.org](https://nim-lang.org/install.html) for details. It is possible
to install it system-wide or in the user directory you create below.

To compile the scss files, you need to install `libsass`. On Ubuntu and Debian,
you can use `libsass-dev`.

Redis is required for caching and in the future for account info. As of 2024
Redis is no longer open source, so using the fork Valkey is recommended. It
should be available on most distros as `redis` or `redis-server`
(Ubuntu/Debian), or `valkey`/`valkey-server`. Running it with the default
config is fine, Nitter's default config is set to use the default port and
localhost.

Here's how to create a `nitter` user, clone the repo, and build the project
along with the scss and md files.

```bash
# useradd -m nitter
# su nitter
$ git clone https://github.com/zedeus/nitter
$ cd nitter
$ nimble -l build -d:danger --mm:refc
$ nimble -l scss
$ nimble -l md
$ cp nitter.example.conf nitter.conf
```

Set your hostname, port, HMAC key, https (must be correct for cookies), and
Redis info in `nitter.conf`. To run Redis, either run
`redis-server --daemonize yes`, or `systemctl enable --now redis` (or
redis-server depending on the distro). Run Nitter by executing `./nitter` or
using the systemd service below. You should run Nitter behind a reverse proxy
such as [Nginx](https://github.com/zedeus/nitter/wiki/Nginx) or
[Apache](https://github.com/zedeus/nitter/wiki/Apache) for security and
performance reasons.

### Docker

Page for the Docker image: https://hub.docker.com/r/zedeus/nitter

#### NOTE: The published image is multi-arch — `zedeus/nitter:latest` runs natively on both `amd64` and `arm64`.

To run Nitter with Docker, you'll need to install and run Redis separately
before you can run the container. See below for how to also run Redis using
Docker.

First create your config file. The Docker commands mount it into the container,
so it has to exist on the host beforehand. If you've cloned the repo:

```bash
cp nitter.example.conf nitter.conf
```

If you're using the prebuilt image without a local clone, download
[`nitter.example.conf`](https://raw.githubusercontent.com/zedeus/nitter/master/nitter.example.conf)
and save it as `nitter.conf` instead.

To build and run Nitter in Docker:

```bash
docker build -t nitter:latest .
docker run -v $(pwd)/nitter.conf:/src/nitter.conf -d --network host nitter:latest
```

A prebuilt Docker image is provided as well:

```bash
docker run -v $(pwd)/nitter.conf:/src/nitter.conf -d --network host zedeus/nitter:latest
```

Using docker-compose to run both Nitter and Redis as different containers:
Change `redisHost` from `localhost` to `nitter-redis` in `nitter.conf`, then run:

```bash
docker-compose up -d
```

Note the Docker commands mount `nitter.conf` (and `sessions.jsonl` for
docker-compose) from the directory you run them in. If a mounted file doesn't
exist, Docker silently creates a directory in its place and the container fails
with `not a directory: Are you trying to mount a directory onto a file`. Remove
that directory and create the file as shown above.

### systemd

To run Nitter via systemd you can use this service file:

```ini
[Unit]
Description=Nitter (An alternative Twitter front-end)
After=syslog.target
After=network.target

[Service]
Type=simple

# set user and group
User=nitter
Group=nitter

# configure location
WorkingDirectory=/home/nitter/nitter
ExecStart=/home/nitter/nitter/nitter

Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

Then enable and run the service:
`systemctl enable --now nitter.service`

### Logging

Nitter currently prints some errors to stdout, and there is no real logging
implemented. If you're running Nitter with systemd, you can check stdout like
this: `journalctl -u nitter.service` (add `--follow` to see just the last 15
lines). If you're running the Docker image, you can do this:
`docker logs --follow *nitter container id*`

## Contact

Feel free to join our [Matrix channel](https://matrix.to/#/#nitter:matrix.org).
You can email me at zedeus@pm.me if you wish to contact me personally.

For legal inquiries, contact legal@poast.org
