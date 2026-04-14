<div align="center">

<img src="https://raw.githubusercontent.com/deckerst/aves/develop/aves_logo.svg" alt='Aves logo' width="200" />

## Aves

![Version badge][Version badge]
![Build badge][Build badge]

Aves is a gallery and metadata explorer app. It is built for Android, with Flutter.

[<img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png"
      alt='Get it on Google Play'
      height="80">](https://play.google.com/store/apps/details?id=deckers.thibault.aves&pcampaignid=pcampaignidMKT-Other-global-all-co-prtnr-py-PartBadge-Mar2515-1)
[<img src="https://gitlab.com/IzzyOnDroid/repo/-/raw/master/assets/IzzyOnDroid.png"
      alt='Get it on IzzyOnDroid'
      height="80">](https://apt.izzysoft.de/fdroid/index/apk/deckers.thibault.aves)
[<img src="https://fdroid.gitlab.io/artwork/badge/get-it-on.png"
      alt='Get it on F-Droid'
      height="80">](https://f-droid.org/packages/deckers.thibault.aves.libre)
[<img src="https://raw.githubusercontent.com/deckerst/common/main/assets/get-it-on-github.png"
      alt='Get it on GitHub'
      height="80">](https://github.com/deckerst/aves/releases/latest)


[Compare versions](https://github.com/deckerst/aves/wiki/App-Versions)

### Remote Media Extension Summary (EN)

- Added a new **Remote Media** settings section with strategy controls for:
  - Wi-Fi only auto-load
  - stream-only / stream-with-download-fallback
  - image/video auto-download size limits
  - remote entry pin-to-top and cache visibility in smart sets
- Added a dedicated **Remote Logs** page with:
  - toggleable logging
  - copy logs
  - export logs as TXT
  - export and share logs
  - clear logs
- Added remote browse and connection capabilities:
  - WebDAV real directory listing (lazy load)
  - FTP/SFTP/SMB connection and folder lazy-loading integration
  - per-file manual open actions (strategy / force download / stream only)
  - stream-open failure fallback to download and reopen
  - per-server cache cleanup and connection-level management
  - when remote cache is allowed in smart sets, downloaded media can be scanned into MediaStore on demand
- Added autoplay stability hardening in preview/video flow:
  - duplicate autoplay trigger protection
  - focus token guard to reduce jitter/racing playback
  - extra diagnostic logs for autoplay/focus transitions
  - CollectionPage grid/mosaic preview now auto-plays both local and remote videos with single-active playback and in-tile mute/unmute toggle
- Remote image preheat/download notes:
  - collection/viewer image preheat count only determines how many upcoming remote images may be prepared
  - actual remote image download is still constrained by the image auto-download size limit
  - current visible remote thumbnails/images may still fetch metadata or bind existing cache so they can display correctly, even when automatic preheat is disabled

### 远程媒体扩展功能摘要（中文）

- 新增 **远程媒体** 设置分组，支持：
  - 仅 Wi-Fi 自动加载
  - 仅流式 / 流式失败后回退下载
  - 图片/视频自动下载大小上限
  - 远程入口置顶与缓存是否纳入媒体集合
- 新增独立 **远程日志** 页面，支持：
  - 日志开关
  - 复制日志
  - 导出 TXT
  - 导出并分享
  - 清空日志
- 新增远程浏览与连接能力：
  - WebDAV 真实目录懒加载
  - FTP/SFTP/SMB 连接与目录懒加载接入
  - 文件级手动打开策略（按策略/强制下载/仅流式）
  - 流式打开失败自动回退下载并重试打开
  - 按连接清理缓存与连接级管理
  - 开启“缓存纳入媒体集合”时，下载后的远程缓存可按需触发 MediaStore 扫描
- 增强预览/视频自动播放稳定性：
  - 自动播放重复触发保护
  - 焦点令牌机制，降低抖动与竞态播放
  - 自动播放与焦点切换关键日志覆盖
  - CollectionPage 网格/马赛克预览已统一支持本地与远程视频自动播放、同屏单视频播放、预览内静音/有声切换
- 新增查看器相关可选能力：
  - 可在“查看器”设置中开启“进入详情时沿用预览进度”，支持本地与远程视频
  - “网格/马赛克预览播放视频”默认关闭
  - “允许缩放到单列预览”默认关闭
- 远程媒体默认策略调整：
  - “仅在 Wi-Fi 下自动加载”默认开启
  - “视频仅流式播放”默认开启
  - “开启自动预热”默认关闭
  - “开启详情页远程视频预热”默认关闭
- 缓存版正式 1.2 远程播放与缓存修正：
  - WebDAV/FTP/SFTP/SMB 普通远程视频在预览拿到稳定帧后，会单独缓存预览封面，后续再次进入可优先顶出首帧/微缩图底板
  - 远程收藏视频与普通远程视频的预览封面缓存链路已拆开，避免统一规则相互干扰
  - 当前聚焦到大远程视频时，如已存在预览封面缓存，不再先清空底板造成白屏
  - 远程图片/视频完整缓存下载成功，或 chunk 合并为整文件后，会回写远端修改时间，避免缓存文件时间变成当前时间并误触发目录变动判断
- 远程图片预热/下载补充说明：
  - 集合页/详情页里的图片预热数量，只决定会尝试提前准备多少张后续远程图片
  - 图片是否真的自动下载，仍然受“图片自动下载大小上限”约束
  - 当前正在显示的远程微缩图/图片，为了正常展示，仍可能补元信息或绑定已有缓存；即使关闭自动预热，也不代表当前项完全不触发准备流程
- 最近一轮远程媒体预热/缓存修正：
  - 网格页在快速滑动时，会统一暂停当前图片下载与后续图片/视频预热，待滚动稳定后再恢复，避免高速滚动时图片被整片拉取
  - 详情页“后续媒体预热”已统一覆盖远程流媒体与远程缓存视频，避免小视频先落到缓存后反而掉出详情视频预热链
  - 小视频 chunk 合并整文件缓存时，补充了 `.mp4.merging` 等临时文件清理/改名竞态容错，减少“明明快缓存完却仍回退流播放”的情况

### Recent Remote Media Preheat/Cache Fixes (EN)

- Grid fast scrolling now pauses both current-image download and upcoming image/video preheat, then resumes after scrolling settles.
- Viewer next-media preheat now covers both remote streams and remote-cached videos, so small videos do not fall out of the detail preheat path after being cached.
- Added extra race-condition guards around merged remote chunk finalize/rename for `.mp4.merging`-style temporary files, reducing cases where nearly completed small-video cache still falls back to streaming.
<div align="left">

## Features

Aves can handle all sorts of images and videos, including your typical JPEGs and MP4s, but also more exotic things like **multi-page TIFFs, SVGs, old AVIs and more**!

It scans your media collection to identify **motion photos**, **panoramas** (aka photo spheres), **360掳 videos**, as well as **GeoTIFF** files.

**Navigation and search** is an important part of Aves. The goal is for users to easily flow from albums to photos to tags to maps, etc.

Aves integrates with Android (including Android TV) with features such as **widgets**, **app shortcuts**, **screen saver** and **global search** handling. It also works as a **media viewer and picker**.

## Screenshots

<div align="center">

[<img src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/1.png"
      alt='Collection screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/1.png)
[<img
      src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/2.png"
      alt='Image screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/2.png)
[<img
      src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/5.png"
      alt='Stats screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/5.png)
[<img
      src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/3.png"
      alt='Info (basic) screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/3.png)
[<img
      src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/4.png"
      alt='Info (metadata) screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/4.png)
[<img
      src="https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/readme/en/6.png"
      alt='Countries screenshot'
      width="130" />](https://raw.githubusercontent.com/deckerst/aves_extra/main/screenshots/play/en/6.png)

<div align="left">

## Changelog

The list of changes for past and future releases is available [here](https://github.com/deckerst/aves/blob/develop/CHANGELOG.md).

## Permissions

Aves requires a few permissions to do its job:
- **read contents of shared storage**: the app only accesses media files, and modifying them requires explicit access grants from the user,
- **read locations from media collection**: necessary to display the media coordinates, and to group them by country (via reverse geocoding),
- **have network access**: necessary for the map view, and most likely for precise reverse geocoding too,
- **view network connections**: checking for connection states allows Aves to gracefully degrade features that depend on internet.

## Contributing

### Issues

[Bug reports](https://github.com/deckerst/aves/issues/new?assignees=&labels=type%3Abug&template=bug_report.md&title=) and [feature requests](https://github.com/deckerst/aves/issues/new?assignees=&labels=type%3Afeature&template=feature_request.md&title=) are welcome, but read the [guidelines](https://github.com/deckerst/aves/issues/234) first. If you have questions, check out the [discussions](https://github.com/deckerst/aves/discussions).

### Code

At this stage this project does *not* accept PRs.

### Translations

Translations are powered by [Weblate](https://hosted.weblate.org/engage/aves/) and the effort of wonderfully generous volunteers.
<a href="https://hosted.weblate.org/engage/aves/">
<img src="https://hosted.weblate.org/widgets/aves/-/multi-auto.svg" alt="Translation status" />
</a>

If you want to translate this app in your language and share the result, [there is a guide](https://github.com/deckerst/aves/wiki/Contributing-to-Translations).

### Donations

Some users have expressed the wish to financially support the project. Thanks! 鉂わ笍

[<img src="https://raw.githubusercontent.com/deckerst/common/main/assets/paypal-badge-cropped.png"
      alt='Donate with PayPal'
      height="40">](https://www.paypal.com/donate/?hosted_button_id=RWKQ4J7D8USX6)
[<img src="https://liberapay.com/assets/widgets/donate.svg"
      alt='Donate using Liberapay'
      height="40">](https://liberapay.com/deckerst/donate)

## Project Setup

Before running or building the app, update the dependencies for the desired flavor:
```
# scripts/apply_flavor_play.sh
```

To build the project, create a file named `<app dir>/android/key.properties`. It should contain a reference to a keystore for app signing, and other necessary credentials. See [key_template.properties](https://github.com/deckerst/aves/blob/develop/android/key_template.properties) for the expected keys.

### Local Custom Release Notes

For local/custom builds, it is recommended to keep signing files outside of Git history and back them up separately.

- Do not commit real signing materials such as `android/key.properties` or keystore files.
- Add them to `.gitignore` and keep an encrypted backup in personal cloud storage or another private location.
- When restoring the project on another machine, put the signing files back in place before building release APKs.
- For local release examples:
  - `flutter build apk -t lib/main_izzy.dart --flavor izzy --release --split-per-abi`
  - the `arm64-v8a` artifact is usually generated at `build/app/outputs/flutter-apk/app-arm64-v8a-izzy-release.apk`

To run the app:
```
# ./flutterw run -t lib/main_play.dart --flavor play
```

[Version badge]: https://img.shields.io/github/v/release/deckerst/aves?include_prereleases&sort=semver
[Build badge]: https://img.shields.io/github/actions/workflow/status/deckerst/aves/quality-check.yml?branch=develop

