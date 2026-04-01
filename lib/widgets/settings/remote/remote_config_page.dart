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
        title: Text(_tr(context, 'Remote Media Settings', '远程媒体配置')),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            _RemoteLogsTile(),
            SettingsSwitchListTile(
              selector: (context, s) => s.remoteWifiOnlyDownload,
              onChanged: (v) => settings.remoteWifiOnlyDownload = v,
              title: _tr(context, 'Only auto-load on Wi-Fi', '仅在 Wi-Fi 下自动加载'),
            ),
            SettingsSwitchListTile(
              selector: (context, s) => s.remotePinAtTop,
              onChanged: (v) => settings.remotePinAtTop = v,
              title: _tr(context, 'Pin remote album entry at top', '远程相册入口置顶'),
            ),
            _RemoteCacheInSmartCollectionsTile(),
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
              title: _tr(context, 'Video stream-only playback', '视频仅流式播放'),
              subtitle: _tr(context, 'When enabled, video auto-download limit is ignored', '开启后视频自动下载上限不生效'),
            ),
            _RemoteAutoDownloadImageMaxTile(),
            _RemoteAutoDownloadVideoMaxTile(),
            _RemoteCacheMaxTile(),
          ],
        ),
      ),
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
          title: Text(_tr(context, 'Remote logs', '远程日志')),
          subtitle: Text(_tr(context, 'Tap to view/copy/export logs', '点击查看/复制/导出日志')),
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
    title: _tr(context, 'Include remote cache in media/video sets', '将远程缓存纳入媒体/视频集合'),
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
    tileTitle: _tr(context, 'Image auto-download max size', '图片自动下载大小上限'),
    dialogTitle: _tr(context, 'Image auto-download max size', '图片自动下载大小上限'),
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
          title: Text(_tr(context, 'Video auto-download max size', '视频自动下载大小上限')),
          subtitle: Text(
            streamOnly ? _tr(context, 'Disabled because video stream-only is enabled', '已启用视频仅流式，当前项不生效') : formatFileSize(context.locale, current, round: 0),
          ),
          onTap: streamOnly
              ? null
              : () => showSelectionDialog<int>(
                  context: context,
                  builder: (context) => AvesSingleSelectionDialog<int>(
                    initialValue: current,
                    options: Map.fromEntries(_values.map((v) => MapEntry(v, formatFileSize(context.locale, v, round: 0)))),
                    title: _tr(context, 'Video auto-download max size', '视频自动下载大小上限'),
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
    onSelection: (v) => settings.remoteCacheMaxBytes = v,
    tileTitle: _tr(context, 'Remote cache max size', '远程缓存最大容量'),
    dialogTitle: _tr(context, 'Remote cache max size', '远程缓存最大容量'),
  );
}
