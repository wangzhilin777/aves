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
    await _materializeRemoteVideoAliases(entries);
    final expandedEntries = await _expandEntriesWithRemoteCacheAliases(entries);
    await remoteMediaService.registerStandaloneFavouritePaths(
      expandedEntries.where((entry) => entry.isRemoteCachedMedia).map((entry) => entry.path).nonNulls.toSet(),
      trigger: 'favourite_add',
    );
    final newRows = expandedEntries.map(_entryToRow).toSet();

    await localMediaDb.addFavourites(newRows);
    _rows.addAll(newRows);

    notifyListeners();
  }

  Future<void> _materializeRemoteVideoAliases(Set<AvesEntry> entries) async {
    final remoteVideos = entries.where((entry) => entry.isVideo && remoteMediaService.getVirtualRemoteRef(entry.uri) != null).toSet();
    if (remoteVideos.isEmpty) return;

    await Future.wait(
      remoteVideos.map(
        (entry) => remoteMediaService.ensureIndexedCacheEntryForEntry(
          entry,
          trigger: 'favourite_add',
        ),
      ),
    );
  }

  Future<void> removeEntries(Set<AvesEntry> entries) async {
    final expandedEntries = await _expandEntriesWithRemoteCacheAliases(entries);
    await remoteMediaService.unregisterStandaloneFavouritePaths(
      expandedEntries.where((entry) => entry.isRemoteCachedMedia).map((entry) => entry.path).nonNulls.toSet(),
      trigger: 'favourite_remove',
    );
    await removeIds(expandedEntries.map((entry) => entry.id).toSet());
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

  Map<String, List<String>>? export(CollectionSource source) {
    final visibleEntries = source.allEntries;
    final ids = all;
    final paths = visibleEntries.where((entry) => ids.contains(entry.id)).map((entry) => entry.path).nonNulls.toSet();
    final byVolume = groupBy<String, StorageVolume?>(paths, androidFileUtils.getStorageVolume);
    final jsonMap = Map.fromEntries(
      byVolume.entries.map((kv) {
        final volume = kv.key?.path;
        if (volume == null) return null;
        final rootLength = volume.length;
        final relativePaths = kv.value.map((v) => v.substring(rootLength)).toList();
        return MapEntry(volume, relativePaths);
      }).nonNulls,
    );
    return jsonMap.isNotEmpty ? jsonMap : null;
  }

  void import(Object jsonMap, CollectionSource source) {
    if (jsonMap is! Map) {
      debugPrint('failed to import favourites for jsonMap=$jsonMap');
      return;
    }

    final visibleEntries = source.allEntries;
    final foundEntries = <AvesEntry>{};
    final missedPaths = <String>{};
    jsonMap.cast<String, List>().forEach((volume, relativePaths) {
      relativePaths.cast<String?>().forEach((relativePath) {
        final path = pContext.join(volume, relativePath);
        final entry = visibleEntries.firstWhereOrNull((entry) => entry.path == path);
        if (entry != null) {
          foundEntries.add(entry);
        } else {
          missedPaths.add(path);
        }
      });

      if (foundEntries.isNotEmpty) {
        add(foundEntries);
      }
      if (missedPaths.isNotEmpty) {
        debugPrint('failed to import favourites with ${missedPaths.length} missed paths');
      }
    });
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
