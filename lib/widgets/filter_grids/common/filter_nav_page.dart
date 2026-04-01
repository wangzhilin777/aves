import 'dart:async';
import 'dart:io';

import 'package:aves/model/filters/container/album_group.dart';
import 'package:aves/model/filters/container/group_base.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/filters/covered/remote_album.dart';
import 'package:aves/model/filters/covered/stored_album.dart';
import 'package:aves/model/filters/filters.dart';
import 'package:aves/model/selection.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/remote_media_service.dart';
import 'package:aves/utils/time_utils.dart';
import 'package:aves/widgets/collection/collection_page.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/action_mixins/vault_aware.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/aves_filter_chip.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/common/providers/filter_group_provider.dart';
import 'package:aves/widgets/common/providers/query_provider.dart';
import 'package:aves/widgets/common/providers/selection_provider.dart';
import 'package:aves/widgets/filter_grids/common/action_delegates/album_set.dart';
import 'package:aves/widgets/filter_grids/common/action_delegates/chip_set.dart';
import 'package:aves/widgets/filter_grids/common/app_bar.dart';
import 'package:aves/widgets/filter_grids/common/filter_grid_page.dart';
import 'package:aves/widgets/filter_grids/common/section_keys.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class FilterNavigationPage<T extends CollectionFilter, CSAD extends ChipSetActionDelegate<T>> extends StatefulWidget {
  final CollectionSource source;
  final String title;
  final ChipSortFactor sortFactor;
  final bool showHeaders;
  final CSAD actionDelegate;
  final Map<ChipSectionKey, List<FilterGridItem<T>>> filterSections;
  final Set<T>? newFilters;
  final Widget Function() emptyBuilder;

  const FilterNavigationPage({
    super.key,
    required this.source,
    required this.title,
    required this.sortFactor,
    this.showHeaders = false,
    required this.actionDelegate,
    required this.filterSections,
    this.newFilters,
    required this.emptyBuilder,
  });

  @override
  State<FilterNavigationPage<T, CSAD>> createState() => _FilterNavigationPageState<T, CSAD>();

  static int compareFiltersByDate(FilterGridItem<CollectionFilter> a, FilterGridItem<CollectionFilter> b) {
    final c = (b.entry?.bestDate ?? epoch).compareTo(a.entry?.bestDate ?? epoch);
    return c != 0 ? c : a.filter.compareTo(b.filter);
  }

  static int compareFiltersByEntryCount(MapEntry<CollectionFilter, num> a, MapEntry<CollectionFilter, num> b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  }

  static int compareFiltersBySize(MapEntry<CollectionFilter, num> a, MapEntry<CollectionFilter, num> b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  }

  static int compareFiltersByName(FilterGridItem<CollectionFilter> a, FilterGridItem<CollectionFilter> b) {
    return a.filter.compareTo(b.filter);
  }

  static int compareFiltersByPath<T extends CollectionFilter>(FilterGridItem<T> a, FilterGridItem<T> b) {
    if (T == AlbumBaseFilter) {
      final filterA = a.filter;
      final filterB = b.filter;
      final pathA = filterA is StoredAlbumFilter ? filterA.album : '';
      final pathB = filterB is StoredAlbumFilter ? filterB.album : '';
      final c = pathA.compareTo(pathB);
      return c != 0 ? c : a.filter.compareTo(b.filter);
    }
    return 0;
  }

  static List<FilterGridItem<T>> sort<T extends CollectionFilter, CSAD extends ChipSetActionDelegate<T>>(
    ChipSortFactor sortFactor,
    bool reverse,
    CollectionSource source,
    Set<T> filters,
  ) {
    List<FilterGridItem<T>> toGridItem(CollectionSource source, Set<T> filters) {
      return filters
          .map(
            (filter) => FilterGridItem(
              filter,
              source.recentEntry(filter),
            ),
          )
          .toList();
    }

    List<FilterGridItem<T>> allMapEntries = [];
    switch (sortFactor) {
      case .name:
        allMapEntries = toGridItem(source, filters)..sort(compareFiltersByName);
      case .date:
        allMapEntries = toGridItem(source, filters)..sort(compareFiltersByDate);
      case .count:
        final filtersWithCount = List.of(filters.map((filter) => MapEntry(filter, source.count(filter))));
        filtersWithCount.sort(compareFiltersByEntryCount);
        filters = filtersWithCount.map((kv) => kv.key).toSet();
        allMapEntries = toGridItem(source, filters);
      case .size:
        final filtersWithSize = List.of(filters.map((filter) => MapEntry(filter, source.size(filter))));
        filtersWithSize.sort(compareFiltersBySize);
        filters = filtersWithSize.map((kv) => kv.key).toSet();
        allMapEntries = toGridItem(source, filters);
      case .path:
        allMapEntries = toGridItem(source, filters)..sort(compareFiltersByPath);
    }
    if (reverse) {
      allMapEntries = allMapEntries.reversed.toList();
    }
    return allMapEntries;
  }
}

class _FilterNavigationPageState<T extends CollectionFilter, CSAD extends ChipSetActionDelegate<T>> extends State<FilterNavigationPage<T, CSAD>> with FeedbackMixin, VaultAwareMixin {
  final ValueNotifier<double> _appBarHeightNotifier = ValueNotifier(0);
  int _virtualEntrySeed = -1;

  @override
  void dispose() {
    _appBarHeightNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionProvider<FilterGridItem<T>>(
      child: Builder(
        builder: (context) {
          final scrollController = PrimaryScrollController.of(context);
          return QueryProvider(
            startEnabled: settings.getShowTitleQuery(context.currentRouteName!),
            child: FilterGridPage<T>(
              appBar: FilterGridAppBar<T, CSAD>(
                source: widget.source,
                title: widget.title,
                actionDelegate: widget.actionDelegate,
                isEmpty: widget.filterSections.isEmpty,
                appBarHeightNotifier: _appBarHeightNotifier,
                scrollController: scrollController,
              ),
              appBarHeightNotifier: _appBarHeightNotifier,
              scrollController: scrollController,
              sections: widget.filterSections,
              newFilters: widget.newFilters ?? {},
              sortFactor: widget.sortFactor,
              showHeaders: widget.showHeaders,
              selectable: true,
              emptyBuilder: () => ValueListenableBuilder<SourceState>(
                valueListenable: widget.source.stateNotifier,
                builder: (context, sourceState, child) {
                  return sourceState != SourceState.loading ? widget.emptyBuilder() : const SizedBox();
                },
              ),
              // do not always enable hero, otherwise unwanted hero gets triggered
              // when using `Show in [...]` action from a chip in the Collection filter bar
              heroType: HeroType.onTap,
              onTileTap: (gridItem, navigate) async {
                final selection = context.read<Selection<FilterGridItem<T>>?>();
                if (selection != null && selection.isSelecting) {
                  selection.toggleSelection(gridItem);
                } else {
                  final filter = gridItem.filter;
                  if (!await unlockFilter(context, filter)) return;

                  if (filter is GroupBaseFilter) {
                    context.read<FilterGroupNotifier>().value = filter.uri;
                  } else if (filter is RemoteAlbumFilter) {
                    await _openRemoteAlbumInNativeCollection(context, filter, navigate);
                  } else {
                    final route = MaterialPageRoute(
                      settings: const RouteSettings(name: CollectionPage.routeName),
                      builder: (context) => CollectionPage(
                        source: context.read<CollectionSource>(),
                        filters: {gridItem.filter},
                      ),
                    );
                    navigate(route);
                  }
                }
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRemoteAlbumInNativeCollection(
    BuildContext context,
    RemoteAlbumFilter filter,
    void Function(Route route) navigate,
  ) async {
    final server = settings.remoteServers.firstWhereOrNull((v) => v.id == filter.serverId);
    if (server == null) return;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      ),
    );

    final entries = <AvesEntry>[];
    final directoryNodes = <RemoteBrowseNode>[];
    try {
      await remoteMediaLogService.log(
        'remote_load',
        'start injecting remote folder into native collection page',
        data: {
          'server': server.name,
          'path': filter.path,
        },
      );

      final page = await remoteMediaService.loadFolder(server: server, path: filter.path);
      directoryNodes.addAll(page.children.where((node) => node.isDirectory));
      final mediaNodes = page.children.where((node) => !node.isDirectory).toList();
      for (final node in mediaNodes) {
        final uri = remoteMediaService.buildStreamUri(server: server, node: node) ?? _buildDeferredRemoteUri(server.id, node.path);
        remoteMediaService.registerVirtualRemoteRef(
          uri: uri.toString(),
          server: server,
          node: node,
        );
        final mimeType = remoteMediaService.inferMimeType(node);
        final entry = _buildVirtualRemoteEntry(
          serverId: server.id,
          node: node,
          uri: uri,
          mimeType: mimeType,
        );
        entries.add(entry);
        await remoteMediaLogService.log(
          'remote_load',
          'injected deferred remote entry for native collection page',
          data: {
            'server': server.name,
            'path': node.path,
            'uri': uri.toString(),
            'mimeType': mimeType,
            'isStreamingUri': uri.scheme == 'http' || uri.scheme == 'https',
          },
        );
      }
    } finally {
      if (context.mounted) {
        Navigator.maybeOf(context)?.pop();
      }
    }

    if (entries.isEmpty) {
      if (directoryNodes.isNotEmpty) {
        final remoteFilters = directoryNodes
            .map(
              (node) => RemoteAlbumFilter(
                serverId: server.id,
                path: node.path,
                title: node.name,
              ),
            )
            .toSet()
            .cast<AlbumBaseFilter>();
        final gridItems = FilterNavigationPage.sort<AlbumBaseFilter, AlbumChipSetActionDelegate>(
          settings.albumSortFactor,
          settings.albumSortReverse,
          widget.source,
          remoteFilters,
        );
        await remoteMediaLogService.log(
          'remote_load',
          'open native folder filter page for remote sub-directories',
          data: {
            'server': server.name,
            'path': filter.path,
            'folderCount': directoryNodes.length,
          },
        );
        final route = MaterialPageRoute(
          settings: const RouteSettings(name: '/remote-folder-filters'),
          builder: (context) => FilterNavigationPage<AlbumBaseFilter, AlbumChipSetActionDelegate>(
            source: widget.source,
            title: filter.title,
            sortFactor: settings.albumSortFactor,
            actionDelegate: AlbumChipSetActionDelegate(gridItems),
            filterSections: {
              const ChipSectionKey(): gridItems,
            },
            emptyBuilder: () => EmptyContent(
              icon: Icons.folder_open,
              text: context.l10n.albumEmpty,
            ),
          ),
        );
        navigate(route);
        return;
      }

      await remoteMediaLogService.log(
        'remote_load',
        'remote folder is empty, open native collection page with empty selection',
        data: {
          'server': server.name,
          'path': filter.path,
        },
      );
      final route = MaterialPageRoute(
        settings: const RouteSettings(name: CollectionPage.routeName),
        builder: (context) => CollectionPage(
          source: widget.source,
          filters: const {},
          fixedSelection: const [],
        ),
      );
      navigate(route);
      return;
    }

    await remoteMediaLogService.log(
      'remote_load',
      'open native collection page with injected remote entries',
      data: {
        'server': server.name,
        'path': filter.path,
        'entryCount': entries.length,
      },
    );

    final route = MaterialPageRoute(
      settings: const RouteSettings(name: CollectionPage.routeName),
      builder: (context) => CollectionPage(
        source: widget.source,
        filters: const {},
        fixedSelection: entries,
      ),
    );
    navigate(route);
  }

  AvesEntry _buildVirtualRemoteEntry({
    required String serverId,
    required RemoteBrowseNode node,
    required Uri uri,
    required String mimeType,
  }) {
    final remotePath = node.path.replaceAll('/', Platform.pathSeparator);
    final path = '${Platform.pathSeparator}remote${Platform.pathSeparator}$serverId$remotePath';
    final entryId = _stableRemoteVirtualEntryId(serverId: serverId, nodePath: node.path, uri: uri.toString());
    final title = node.name.isNotEmpty ? node.name : node.path.split('/').where((v) => v.isNotEmpty).lastOrNull;
    return AvesEntry(
      id: entryId,
      uri: uri.toString(),
      path: path,
      contentId: entryId,
      pageId: null,
      sourceMimeType: MimeTypes.normalize(mimeType),
      width: 1,
      height: 1,
      sourceRotationDegrees: 0,
      sizeBytes: node.sizeBytes,
      sourceTitle: title,
      dateAddedSecs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      dateModifiedMillis: null,
      sourceDateTakenMillis: null,
      durationMillis: null,
      trashed: false,
      origin: EntryOrigins.mediaStoreContent,
    );
  }

  int _stableRemoteVirtualEntryId({
    required String serverId,
    required String nodePath,
    required String uri,
  }) {
    return _virtualEntrySeed--;
  }

  Uri _buildDeferredRemoteUri(String serverId, String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri(
      scheme: 'aves-remote',
      host: serverId,
      path: normalizedPath,
    );
  }
}
