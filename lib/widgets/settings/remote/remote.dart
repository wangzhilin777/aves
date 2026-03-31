import 'package:aves/theme/colors.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/remote/remote_page.dart';
import 'package:aves/widgets/settings/common/tile_leading.dart';
import 'package:aves/widgets/settings/common/tiles.dart';
import 'package:aves/widgets/settings/remote/remote_config_page.dart';
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
      _SettingsTileRemoteManager(),
      _SettingsTileRemoteConfig(),
    ];
  }
}

class _SettingsTileRemoteManager extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Remote Media Manager', '远程媒体管理');

  @override
  Widget build(BuildContext context) => SettingsSubPageTile(
    title: title(context),
    routeName: RemotePage.routeName,
    builder: (context) => const RemotePage(),
  );
}

class _SettingsTileRemoteConfig extends SettingsTile {
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  String title(BuildContext context) => _tr(context, 'Remote Media Settings', '远程媒体配置');

  @override
  Widget build(BuildContext context) => SettingsSubPageTile(
    title: title(context),
    routeName: RemoteMediaConfigPage.routeName,
    builder: (context) => const RemoteMediaConfigPage(),
  );
}
