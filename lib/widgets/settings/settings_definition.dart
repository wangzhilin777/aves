import 'dart:async';

import 'package:aves/widgets/common/identity/aves_expansion_tile.dart';
import 'package:flutter/widgets.dart';

abstract class SettingsSection {
  String get key;

  Widget icon(BuildContext context);

  String title(BuildContext context);

  Future<List<SettingsTile>> tiles(BuildContext context);

  Widget build(BuildContext sectionContext, ValueNotifier<String?> expandedNotifier) {
    return FutureBuilder<List<SettingsTile>>(
      future: tiles(sectionContext),
      builder: (tileContext, snapshot) {
        if (snapshot.hasError) {
          debugPrint('failed to load settings section=$key with error=${snapshot.error}');
          return AvesExpansionTile(
            key: Key('section-$key'),
            value: key,
            leading: icon(tileContext),
            title: title(tileContext),
            expandedNotifier: expandedNotifier,
            showHighlight: false,
            children: const [
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
                child: Text('Failed to load this settings section.'),
              ),
            ],
          );
        }

        final tiles = snapshot.data;
        if (tiles == null) return const SizedBox();

        return AvesExpansionTile(
          // key is expected by test driver
          key: Key('section-$key'),
          // use a fixed value instead of the title to identify this expansion tile
          // so that the tile state is kept when the language is modified
          value: key,
          leading: icon(tileContext),
          title: title(tileContext),
          expandedNotifier: expandedNotifier,
          showHighlight: false,
          // reuse section context so that dialogs opened from tiles have the right text theme
          children: tiles.map((v) => v.build(sectionContext)).toList(),
        );
      },
    );
  }
}

abstract class SettingsTile {
  String title(BuildContext context);

  Widget build(BuildContext context);
}
