import 'dart:async';

import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/colors.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/utils/file_utils.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/settings/common/tile_leading.dart';
import 'package:aves/widgets/settings/common/tiles.dart';
import 'package:aves/widgets/settings/remote/remote_logs_page.dart';
import 'package:aves/widgets/settings/settings_definition.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RemoteMediaSection extends SettingsSection {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String get key => 'remote_media';

  @override
  Widget icon(BuildContext context) => SettingsTileLeading(
    icon: AIcons.storageMain,
    color: context.select<AvesColorsData, Color>((v) => v.language),
  );

  @override
  String title(BuildContext context) => _tr(context, 'Remote Media', '远程媒体');

  @override
  Future<List<SettingsTile>> tiles(BuildContext context) async {
    return [
      _SettingsTileRemoteLogs(),
      _SettingsTileRemoteLogEnabled(),
      _SettingsTileRemoteWifiOnlyDownload(),
      _SettingsTileRemotePinAtTop(),
      _SettingsTileRemoteCacheInSmartCollections(),
      _SettingsTileRemoteStreamMode(),
      _SettingsTileRemoteGridVideoAutoPlay(),
      _SettingsTileRemoteGridVideoSoundOn(),
      _SettingsTileRemoteAutoDownloadImageMax(),
      _SettingsTileRemoteAutoDownloadVideoMax(),
    ];
  }
}

class _SettingsTileRemoteLogs extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Remote Logs', '远程日志');

  @override
  Widget build(BuildContext context) => SettingsSubPageTile(
    title: title(context),
    routeName: RemoteLogsPage.routeName,
    builder: (context) => const RemoteLogsPage(),
  );
}

class _SettingsTileRemoteLogEnabled extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Enable remote logging', '启用远程日志');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteLogEnabled,
    onChanged: (v) => settings.remoteLogEnabled = v,
    title: title(context),
  );
}

class _SettingsTileRemoteWifiOnlyDownload extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Only auto-load on Wi-Fi', '仅在 Wi-Fi 下自动加载');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteWifiOnlyDownload,
    onChanged: (v) => settings.remoteWifiOnlyDownload = v,
    title: title(context),
  );
}

class _SettingsTileRemotePinAtTop extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Pin remote album entry at top', '远程相册入口置顶');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remotePinAtTop,
    onChanged: (v) => settings.remotePinAtTop = v,
    title: title(context),
  );
}

class _SettingsTileRemoteCacheInSmartCollections extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Include remote cache in media/video sets', '将远程缓存纳入媒体/视频集合');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteCacheInSmartCollections,
    onChanged: (v) {
      settings.remoteCacheInSmartCollections = v;
      unawaited(remoteMediaService.syncCacheMediaScanPolicy());
    },
    title: title(context),
  );
}

class _SettingsTileRemoteGridVideoAutoPlay extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Auto-play remote videos in grid/mosaic', '网格/马赛克中自动播放远程视频');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteGridVideoAutoPlay,
    onChanged: (v) => settings.remoteGridVideoAutoPlay = v,
    title: title(context),
  );
}

class _SettingsTileRemoteGridVideoSoundOn extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Remote grid video playback with sound by default', '网格远程视频默认有声播放');

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteGridVideoSoundOn,
    onChanged: (v) => settings.remoteGridVideoSoundOn = v,
    title: title(context),
  );
}

class _SettingsTileRemoteStreamMode extends SettingsTile {
  static const _values = RemoteStreamMode.values;
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Streaming strategy', '流式策略');

  @override
  Widget build(BuildContext context) => SettingsSelectionListTile<RemoteStreamMode>(
    values: _values,
    getName: (context, value) => switch (value) {
      RemoteStreamMode.streamOnly => _tr(context, 'Streaming only', '仅流式'),
      RemoteStreamMode.streamWithDownloadFallback => _tr(context, 'Fallback to download when stream fails', '流式失败后回退下载'),
    },
    selector: (context, s) => s.remoteStreamMode,
    onSelection: (v) => settings.remoteStreamMode = v,
    tileTitle: title(context),
    dialogTitle: title(context),
  );
}

class _SettingsTileRemoteAutoDownloadImageMax extends SettingsTile {
  static const _values = [
    1 * 1024 * 1024,
    2 * 1024 * 1024,
    4 * 1024 * 1024,
    8 * 1024 * 1024,
    16 * 1024 * 1024,
    32 * 1024 * 1024,
    64 * 1024 * 1024,
  ];

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Image auto-download max size', '图片自动下载大小上限');

  @override
  Widget build(BuildContext context) => SettingsSelectionListTile<int>(
    values: _values,
    getName: (context, value) => formatFileSize(context.locale, value, round: 0),
    selector: (context, s) => s.remoteAutoDownloadImageMaxBytes,
    onSelection: (v) => settings.remoteAutoDownloadImageMaxBytes = v,
    tileTitle: title(context),
    dialogTitle: title(context),
  );
}

class _SettingsTileRemoteAutoDownloadVideoMax extends SettingsTile {
  static const _values = [
    4 * 1024 * 1024,
    8 * 1024 * 1024,
    16 * 1024 * 1024,
    30 * 1024 * 1024,
    50 * 1024 * 1024,
    100 * 1024 * 1024,
    200 * 1024 * 1024,
  ];

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Video auto-download max size', '视频自动下载大小上限');

  @override
  Widget build(BuildContext context) => SettingsSelectionListTile<int>(
    values: _values,
    getName: (context, value) => formatFileSize(context.locale, value, round: 0),
    selector: (context, s) => s.remoteAutoDownloadVideoMaxBytes,
    onSelection: (v) => settings.remoteAutoDownloadVideoMaxBytes = v,
    tileTitle: title(context),
    dialogTitle: title(context),
  );
}
