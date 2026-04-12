import 'dart:convert';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/runtime_collection_source.dart';
import 'package:aves/utils/android_file_utils.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

final Favourites favourites = Favourites._private();

class Favourites with ChangeNotifier {
  Set<FavouriteRow> _rows = {};

  Favourites._private() {
    if (kFlutterMemoryAllocationsEnabled) ChangeNotifier.maybeDispatchObjectCreation(this);
  }

  Future<void> init() async {
    _rows = await localMediaDb.loadAllFavourites();
  }

  int get count => _rows.length;

  Set<int> get all => Set.unmodifiable(_rows.map((v) => v.entryId));

  bool isFavourite(AvesEntry entry) => _rows.any((row) => row.entryId == entry.id);

  FavouriteRow _entryToRow(AvesEntry entry) => FavouriteRow(entryId: entry.id);

  Future<void> add(Set<AvesEntry> entries) async {
    final materializedEntries = await _materializeRemoteFavouriteAliases(entries);
    final expandedEntries = await _expandEntriesWithRemoteCacheAliases(materializedEntries);
    await remoteMediaService.registerStandaloneFavouriteEntries(
      expandedEntries,
      trigger: 'favourite_add',
    );
    final newRows = expandedEntries.where((entry) => entry.id > 0).map(_entryToRow).toSet();

    if (newRows.isNotEmpty) {
      await localMediaDb.addFavourites(newRows);
      _rows.addAll(newRows);
    }

    notifyListeners();
  }

  Future<Set<AvesEntry>> _materializeRemoteFavouriteAliases(Set<AvesEntry> entries) async {
    final resolvedEntries = <AvesEntry>{...entries};
    final virtualRemoteEntries = entries.where((entry) => remoteMediaService.getVirtualRemoteRef(entry.uri) != null).toSet();
    if (virtualRemoteEntries.isEmpty) return resolvedEntries;

    final materializedEntries = await Future.wait(
      virtualRemoteEntries.map((entry) async {
        if (entry.isVideo) {
          await remoteMediaService.ensureEntryMetadata(entry, trigger: 'favourite_add');
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'favourite_add');
          return null;
        }
        final indexedEntry = await remoteMediaService.ensureIndexedCacheEntryForEntry(
          entry,
          trigger: 'favourite_add',
        );
        if (indexedEntry != null && indexedEntry.id > 0 && entry.id != indexedEntry.id) {
          entry.id = indexedEntry.id;
        }
        return indexedEntry;
      }),
    );
    resolvedEntries.addAll(materializedEntries.nonNulls);
    return resolvedEntries;
  }

  Future<void> removeEntries(Set<AvesEntry> entries) async {
    final expandedEntries = await _expandEntriesWithRemoteCacheAliases(entries);
    await remoteMediaService.unregisterStandaloneFavouritePaths(
      expandedEntries.map(remoteMediaService.getStandaloneFavouriteKeyForEntry).nonNulls.toSet(),
      trigger: 'favourite_remove',
    );
    await removeIds(expandedEntries.where((entry) => entry.id > 0).map((entry) => entry.id).toSet());
    await remoteMediaService.enforceAllConnectionCacheLimits(trigger: 'favourite_remove');
  }

  Future<void> removeIds(Set<int> entryIds) async {
    final removedRows = _rows.where((row) => entryIds.contains(row.entryId)).toSet();

    await localMediaDb.removeFavourites(removedRows);
    removedRows.forEach(_rows.remove);

    notifyListeners();
  }

  Future<void> clear() async {
    await remoteMediaService.unregisterStandaloneFavouritePaths(
      settings.remoteStandaloneFavouritePaths,
      trigger: 'favourites_clear',
    );
    await localMediaDb.clearFavourites();
    _rows.clear();

    notifyListeners();
    await remoteMediaService.enforceAllConnectionCacheLimits(trigger: 'favourites_clear');
  }

  Future<Set<AvesEntry>> _expandEntriesWithRemoteCacheAliases(Set<AvesEntry> entries) async {
    if (entries.isEmpty) return entries;

    final remoteCachedPaths = entries.where((entry) => entry.isRemoteCachedMedia).map((entry) => entry.path).nonNulls.toSet();
    if (remoteCachedPaths.isEmpty) return entries;

    final aliases = <AvesEntry>{};
    final runtimeSource = runtimeCollectionSource;
    if (runtimeSource != null) {
      aliases.addAll(runtimeSource.allEntries.where((entry) => entry.path != null && remoteCachedPaths.contains(entry.path)));
    }

    final scannedEntries = await localMediaDb.loadEntries();
    aliases.addAll(scannedEntries.where((entry) => entry.path != null && remoteCachedPaths.contains(entry.path)));
    return {
      ...entries,
      ...aliases,
    };
  }

  // import/export

  Object? export(CollectionSource source) {
    final visibleEntries = source.allEntries;
    final ids = all;
    final paths = visibleEntries.where((entry) => ids.contains(entry.id)).map((entry) => entry.path).nonNulls.toSet();
    final byVolume = groupBy<String, StorageVolume?>(paths, androidFileUtils.getStorageVolume);
    final localJsonMap = Map.fromEntries(
      byVolume.entries.map((kv) {
        final volume = kv.key?.path;
        if (volume == null) return null;
        final rootLength = volume.length;
        final relativePaths = kv.value.map((v) => v.substring(rootLength)).toList();
        return MapEntry(volume, relativePaths);
      }).nonNulls,
    );
    final remoteStandaloneEntries = settings.remoteStandaloneFavouriteEntries;
    if (localJsonMap.isEmpty && remoteStandaloneEntries.isEmpty) return null;

    return {
      'version': 2,
      'local': localJsonMap,
      'remoteStandaloneEntries': remoteStandaloneEntries,
    };
  }

  Future<void> import(Object jsonMap, CollectionSource source) async {
    if (jsonMap is! Map) {
      debugPrint('failed to import favourites for jsonMap=$jsonMap');
      return;
    }

    Map<String, List> localJsonMap;
    List<String> remoteStandaloneEntries = const [];
    if (jsonMap.containsKey('local') || jsonMap.containsKey('remoteStandaloneEntries')) {
      localJsonMap = (jsonMap['local'] as Map?)?.cast<String, List>() ?? const {};
      remoteStandaloneEntries = (jsonMap['remoteStandaloneEntries'] as List?)?.cast<String?>().nonNulls.toList() ?? const [];
    } else {
      localJsonMap = jsonMap.cast<String, List>();
    }

    final visibleEntries = source.allEntries;
    final foundEntries = <AvesEntry>{};
    final missedPaths = <String>{};
    localJsonMap.forEach((volume, relativePaths) {
      relativePaths.cast<String?>().forEach((relativePath) {
        final path = pContext.join(volume, relativePath);
        final entry = visibleEntries.firstWhereOrNull((entry) => entry.path == path);
        if (entry != null) {
          foundEntries.add(entry);
        } else {
          missedPaths.add(path);
        }
      });

    });

    if (foundEntries.isNotEmpty) {
      await add(foundEntries);
    }
    if (missedPaths.isNotEmpty) {
      debugPrint('failed to import favourites with ${missedPaths.length} missed paths');
    }

    if (remoteStandaloneEntries.isNotEmpty) {
      final mergedRemoteEntries = {
        ...settings.remoteStandaloneFavouriteEntries,
        ...remoteStandaloneEntries,
      }.toList();
      settings.remoteStandaloneFavouriteEntries = mergedRemoteEntries;

      final importedRemoteKeys = remoteStandaloneEntries.map((jsonString) {
        try {
          return (jsonDecode(jsonString) as Map)['key'] as String?;
        } catch (_) {
          return null;
        }
      }).nonNulls.toSet();
      if (importedRemoteKeys.isNotEmpty) {
        settings.remoteStandaloneFavouritePaths = {
          ...settings.remoteStandaloneFavouritePaths,
          ...importedRemoteKeys,
        };
      }

      await remoteMediaService.restoreStandaloneFavouriteEntries(trigger: 'favourites_import');
      await remoteMediaService.syncStandaloneFavouriteMode(trigger: 'favourites_import');
      notifyListeners();
    }
  }
}

@immutable
class FavouriteRow extends Equatable {
  final int entryId;

  @override
  List<Object?> get props => [entryId];

  const FavouriteRow({
    required this.entryId,
  });

  factory FavouriteRow.fromMap(Map map) {
    return FavouriteRow(
      entryId: map['id'] as int,
    );
  }

  Map<String, Object?> toMap() => {
    'id': entryId,
  };
}
