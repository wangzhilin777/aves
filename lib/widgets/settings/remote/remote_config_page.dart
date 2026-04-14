import 'dart:async';

import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/utils/file_utils.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/common.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/single_selection.dart';
import 'package:aves/widgets/settings/common/tiles.dart';
import 'package:aves/widgets/settings/remote/remote_logs_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RemoteMediaConfigPage extends StatelessWidget {
  static const routeName = '/settings/remote/config';

  const RemoteMediaConfigPage({super.key});

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr(context, 'Remote Media Settings', '\u8fdc\u7a0b\u5a92\u4f53\u914d\u7f6e')),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            _RemoteLogsTile(),
            SettingsSwitchListTile(
              selector: (context, s) => s.remoteWifiOnlyDownload,
              onChanged: (v) => settings.remoteWifiOnlyDownload = v,
              title: _tr(context, 'Only auto-load on Wi-Fi', '\u4ec5\u5728 Wi-Fi \u4e0b\u81ea\u52a8\u52a0\u8f7d'),
            ),
            SettingsSwitchListTile(
              selector: (context, s) => s.remotePinAtTop,
              onChanged: (v) => settings.remotePinAtTop = v,
              title: _tr(context, 'Pin remote album entry at top', '\u8fdc\u7a0b\u76f8\u518c\u5165\u53e3\u7f6e\u9876'),
            ),
            _RemotePreviewPreheatTile(),
            _RemoteCacheInSmartCollectionsTile(),
            SettingsSwitchListTile(
              selector: (context, s) => s.remoteStandaloneFavouriteMode,
              onChanged: (v) => unawaited(_applyStandaloneFavouriteMode(context, v)),
              title: _tr(context, 'Remote favorites independent from media/video sets', '远程收藏不受媒体/视频合集开关控制'),
              subtitle: _tr(context, 'Allow only favorited remote media to appear in Favorites without adding all remote cache to media/video sets', '允许仅收藏的远程媒体进入收藏夹，而不把全部远程缓存加入媒体/视频合集'),
            ),
            SettingsSwitchListTile(
              selector: (context, s) => s.remoteStreamMode == RemoteStreamMode.streamOnly,
              onChanged: (v) {
                settings.remoteStreamMode = v ? RemoteStreamMode.streamOnly : RemoteStreamMode.streamWithDownloadFallback;
                unawaited(
                  remoteMediaLogService.log(
                    'remote_load',
                    'updated remote video stream-only setting',
                    data: {'enabled': v},
                  ),
                );
              },
              title: _tr(context, 'Video stream-only playback', '\u89c6\u9891\u4ec5\u6d41\u5f0f\u64ad\u653e'),
              subtitle: _tr(context, 'When enabled, video auto-download limit is ignored', '\u5f00\u542f\u540e\u89c6\u9891\u81ea\u52a8\u4e0b\u8f7d\u4e0a\u9650\u4e0d\u751f\u6548'),
            ),
            _RemoteAutoDownloadImageMaxTile(),
            _RemoteAutoDownloadVideoMaxTile(),
            _RemoteCacheMaxTile(),
          ],
        ),
      ),
    );
  }

  Future<void> _applyStandaloneFavouriteMode(BuildContext context, bool enabled) async {
    settings.remoteStandaloneFavouriteMode = enabled;
    await remoteMediaService.syncStandaloneFavouriteMode(trigger: 'settings_remote_standalone_favourite_mode');
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          _tr(
            context,
            enabled ? 'Remote favorites standalone mode enabled' : 'Remote favorites standalone mode disabled',
            enabled ? '已开启远程收藏独立模式' : '已关闭远程收藏独立模式',
          ),
        ),
      ),
    );
  }
}

class _RemotePreviewPreheatTile extends StatelessWidget {
  static const _imageValues = [0, 1, 2, 3, 4, 6];
  static const _videoValues = [0, 1, 2, 3];

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) {
    return Selector<Settings, (bool, bool, int, int)>(
      selector: (context, s) => (s.remotePreviewPreheatEnabled, s.remoteViewerPreheatEnabled, s.remotePreviewImageCount, s.remotePreviewVideoCount),
      builder: (context, state, child) {
        final (enabled, viewerEnabled, imageCount, videoCount) = state;
        final anyPreheatEnabled = enabled || viewerEnabled;
        return ExpansionTile(
          title: Text(_tr(context, 'Preview preheat', '预览预热')),
          subtitle: Text(
            anyPreheatEnabled
                ? _tr(
                    context,
                    'Images: $imageCount, next videos: $videoCount, viewer: ${viewerEnabled ? 'on' : 'off'}',
                    '图片：$imageCount 张，后续视频：$videoCount 个，详情页预热：${viewerEnabled ? '开' : '关'}',
                  )
                : _tr(context, 'Disabled', '已关闭'),
          ),
          children: [
            SwitchListTile(
              value: enabled,
              onChanged: (v) => settings.remotePreviewPreheatEnabled = v,
              title: Text(_tr(context, 'Enable automatic preview preheat', '开启自动预热')),
            ),
            SwitchListTile(
              value: viewerEnabled,
              onChanged: (v) => settings.remoteViewerPreheatEnabled = v,
              title: Text(_tr(context, 'Enable viewer next-media preheat', '开启详情页后续媒体预热')),
              subtitle: Text(_tr(context, 'Preheats upcoming remote videos and images using the counts below', '按下方数量设置预热后续远程视频和图片')),
            ),
            ListTile(
              enabled: enabled,
              title: Text(_tr(context, 'Preheat images ahead', '预热图片数量')),
              subtitle: Text(_tr(context, '$imageCount items', '$imageCount 张')),
              onTap: !enabled
                  ? null
                  : () => showSelectionDialog<int>(
                        context: context,
                        builder: (context) => AvesSingleSelectionDialog<int>(
                          initialValue: imageCount,
                          options: Map.fromEntries(
                            _imageValues.map(
                              (value) => MapEntry(
                                value,
                                value == 0 ? _tr(context, 'Off', '关闭') : _tr(context, '$value items', '$value 张'),
                              ),
                            ),
                          ),
                          title: _tr(context, 'Preheat images ahead', '预热图片数量'),
                        ),
                        onSelection: (v) => settings.remotePreviewImageCount = v,
                      ),
            ),
            ListTile(
              enabled: anyPreheatEnabled,
              title: Text(_tr(context, 'Preheat next videos', '预热后续视频数量')),
              subtitle: Text(_tr(context, '$videoCount items', '$videoCount 个')),
              onTap: !anyPreheatEnabled
                  ? null
                  : () => showSelectionDialog<int>(
                        context: context,
                        builder: (context) => AvesSingleSelectionDialog<int>(
                          initialValue: videoCount,
                          options: Map.fromEntries(
                            _videoValues.map(
                              (value) => MapEntry(
                                value,
                                value == 0 ? _tr(context, 'Off', '关闭') : _tr(context, '$value items', '$value 个'),
                              ),
                            ),
                          ),
                          title: _tr(context, 'Preheat next videos', '预热后续视频数量'),
                        ),
                        onSelection: (v) => settings.remotePreviewVideoCount = v,
                      ),
            ),
          ],
        );
      },
    );
  }
}

class _RemoteLogsTile extends StatelessWidget {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) {
    return Selector<Settings, bool>(
      selector: (context, s) => s.remoteLogEnabled,
      builder: (context, enabled, child) {
        return ListTile(
          title: Text(_tr(context, 'Remote logs', '\u8fdc\u7a0b\u65e5\u5fd7')),
          subtitle: Text(_tr(context, 'Tap to view/copy/export logs', '\u70b9\u51fb\u67e5\u770b/\u590d\u5236/\u5bfc\u51fa\u65e5\u5fd7')),
          trailing: Switch(
            value: enabled,
            onChanged: (v) => settings.remoteLogEnabled = v,
          ),
          onTap: () {
            Navigator.maybeOf(context)?.push(
              MaterialPageRoute(
                settings: const RouteSettings(name: RemoteLogsPage.routeName),
                builder: (_) => const RemoteLogsPage(),
              ),
            );
          },
        );
      },
    );
  }
}

class _RemoteCacheInSmartCollectionsTile extends StatelessWidget {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) => SettingsSwitchListTile(
    selector: (context, s) => s.remoteCacheInSmartCollections,
    onChanged: (v) => unawaited(_apply(context, v)),
    title: _tr(context, 'Include remote cache in media/video sets', '\u5c06\u8fdc\u7a0b\u7f13\u5b58\u7eb3\u5165\u5a92\u4f53/\u89c6\u9891\u96c6\u5408'),
  );

  Future<void> _apply(BuildContext context, bool enabled) async {
    settings.remoteCacheInSmartCollections = enabled;
    await remoteMediaService.syncCacheMediaScanPolicy();

    if (!enabled) {
      final purgedDbEntries = await remoteMediaService.purgeIndexedRemoteCacheEntries();
      final source = context.read<CollectionSource>();
      final visibleRemoteUris = source.allEntries.where((entry) => entry.isRemoteCachedMedia).map((entry) => entry.uri).toSet();
      if (visibleRemoteUris.isNotEmpty) {
        await source.removeEntries(visibleRemoteUris, includeTrash: false);
      }

      await remoteMediaLogService.log(
        'remote_load',
        'disabled remote cache in smart collections and purged indexed entries',
        data: {
          'purgedDbEntries': purgedDbEntries,
          'removedVisibleEntries': visibleRemoteUris.length,
        },
      );
    }
  }
}

class _RemoteAutoDownloadImageMaxTile extends StatelessWidget {
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
  Widget build(BuildContext context) => SettingsSelectionListTile<int>(
    values: _values,
    getName: (context, value) => formatFileSize(context.locale, value, round: 0),
    selector: (context, s) => s.remoteAutoDownloadImageMaxBytes,
    onSelection: (v) => settings.remoteAutoDownloadImageMaxBytes = v,
    tileTitle: _tr(context, 'Image auto-download max size', '\u56fe\u7247\u81ea\u52a8\u4e0b\u8f7d\u5927\u5c0f\u4e0a\u9650'),
    dialogTitle: _tr(context, 'Image auto-download max size', '\u56fe\u7247\u81ea\u52a8\u4e0b\u8f7d\u5927\u5c0f\u4e0a\u9650'),
  );
}

class _RemoteAutoDownloadVideoMaxTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Selector<Settings, (int, RemoteStreamMode)>(
      selector: (context, s) => (s.remoteAutoDownloadVideoMaxBytes, s.remoteStreamMode),
      builder: (context, state, child) {
        final current = state.$1;
        final streamOnly = state.$2 == RemoteStreamMode.streamOnly;
        return ListTile(
          enabled: !streamOnly,
          title: Text(_tr(context, 'Video auto-download max size', '\u89c6\u9891\u81ea\u52a8\u4e0b\u8f7d\u5927\u5c0f\u4e0a\u9650')),
          subtitle: Text(
            streamOnly ? _tr(context, 'Disabled because video stream-only is enabled', '\u5df2\u542f\u7528\u89c6\u9891\u4ec5\u6d41\u5f0f\uff0c\u5f53\u524d\u9879\u4e0d\u751f\u6548') : formatFileSize(context.locale, current, round: 0),
          ),
          onTap: streamOnly
              ? null
              : () => showSelectionDialog<int>(
                  context: context,
                  builder: (context) => AvesSingleSelectionDialog<int>(
                    initialValue: current,
                    options: Map.fromEntries(_values.map((v) => MapEntry(v, formatFileSize(context.locale, v, round: 0)))),
                    title: _tr(context, 'Video auto-download max size', '\u89c6\u9891\u81ea\u52a8\u4e0b\u8f7d\u5927\u5c0f\u4e0a\u9650'),
                  ),
                  onSelection: (v) => settings.remoteAutoDownloadVideoMaxBytes = v,
                ),
        );
      },
    );
  }
}

class _RemoteCacheMaxTile extends StatelessWidget {
  static const _values = [
    256 * 1024 * 1024,
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
    4 * 1024 * 1024 * 1024,
    8 * 1024 * 1024 * 1024,
  ];

  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) => SettingsSelectionListTile<int>(
    values: _values,
    getName: (context, value) => formatFileSize(context.locale, value, round: 0),
    selector: (context, s) => s.remoteCacheMaxBytes,
    onSelection: (v) => unawaited(_apply(context, v)),
    tileTitle: _tr(context, 'Remote cache max size', '\u8fdc\u7a0b\u7f13\u5b58\u6700\u5927\u5bb9\u91cf'),
    dialogTitle: _tr(context, 'Remote cache max size', '\u8fdc\u7a0b\u7f13\u5b58\u6700\u5927\u5bb9\u91cf'),
  );

  Future<void> _apply(BuildContext context, int value) async {
    settings.remoteCacheMaxBytes = value;
    await remoteMediaService.enforceAllConnectionCacheLimits(
      trigger: 'settings_remote_cache_limit_changed',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          _tr(
            context,
            'Remote cache limit updated and cleanup applied',
            '\u8fdc\u7a0b\u7f13\u5b58\u4e0a\u9650\u5df2\u66f4\u65b0\uff0c\u5e76\u5df2\u6267\u884c\u6e05\u7406',
          ),
        ),
      ),
    );
  }
}

