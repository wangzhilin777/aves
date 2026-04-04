import 'package:aves/model/filters/container/album_group.dart';
import 'package:aves/model/filters/container/dynamic_album.dart';
import 'package:aves/model/filters/covered/remote_album.dart';
import 'package:aves/model/filters/covered/stored_album.dart';
import 'package:aves/model/filters/trash.dart';
import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/album.dart';
import 'package:aves/model/source/collection_lens.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/model/source/location/country.dart';
import 'package:aves/model/source/location/place.dart';
import 'package:aves/model/source/tag.dart';
import 'package:aves/ref/locales.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/durations.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/utils/android_file_utils.dart';
import 'package:aves/utils/file_utils.dart';
import 'package:aves/widgets/about/about_page.dart';
import 'package:aves/widgets/collection/collection_page.dart';
import 'package:aves/widgets/common/basic/text/outlined.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/extensions/media_query.dart';
import 'package:aves/widgets/common/identity/aves_logo.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/debug/app_debug_page.dart';
import 'package:aves/widgets/explorer/explorer_page.dart';
import 'package:aves/widgets/filter_grids/albums_page.dart';
import 'package:aves/widgets/filter_grids/common/action_delegates/album_set.dart';
import 'package:aves/widgets/filter_grids/common/filter_nav_page.dart';
import 'package:aves/widgets/filter_grids/common/section_keys.dart';
import 'package:aves/widgets/filter_grids/countries_page.dart';
import 'package:aves/widgets/filter_grids/places_page.dart';
import 'package:aves/widgets/filter_grids/tags_page.dart';
import 'package:aves/widgets/home/home_page.dart';
import 'package:aves/widgets/navigation/drawer/collection_nav_tile.dart';
import 'package:aves/widgets/navigation/drawer/page_nav_tile.dart';
import 'package:aves/widgets/navigation/drawer/tile.dart';
import 'package:aves/widgets/navigation/nav_item.dart';
import 'package:aves/widgets/settings/settings_page.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class AppDrawer extends StatefulWidget {
  // collection loaded in the `CollectionPage`, if any
  final CollectionLens? currentCollection;

  // current path loaded in the `ExplorerPage`, if any
  final String? currentExplorerPath;

  const AppDrawer({
    super.key,
    this.currentCollection,
    this.currentExplorerPath,
  });

  @override
  State<AppDrawer> createState() => _AppDrawerState();

  static List<AlbumBaseFilter> _getDefaultAlbums(BuildContext context) {
    final source = context.read<CollectionSource>();
    final specialAlbums = source.rawAlbums.where((album) {
      final type = androidFileUtils.getAlbumType(album);
      return [AlbumType.camera, AlbumType.download, AlbumType.screenshots].contains(type);
    }).toList()..sort(source.compareAlbumsByName);
    return specialAlbums.map((v) => StoredAlbumFilter(v, source.getStoredAlbumDisplayName(context, v))).toList();
  }

  static List<AlbumBaseFilter>? _getCustomAlbums(BuildContext context) {
    final source = context.read<CollectionSource>();
    return settings.drawerAlbumBookmarks?.map((v) {
      if (v is StoredAlbumFilter) {
        final album = v.album;
        return StoredAlbumFilter(album, source.getStoredAlbumDisplayName(context, album));
      }
      return v;
    }).toList();
  }

  static List<AlbumBaseFilter> effectiveAlbumBookmarks(BuildContext context) {
    return _getCustomAlbums(context) ?? _getDefaultAlbums(context);
  }
}

class _AppDrawerState extends State<AppDrawer> with WidgetsBindingObserver, FeedbackMixin {
  // using the default controller conflicts
  // with bottom nav bar primary scroll monitoring
  final ScrollController _scrollController = ScrollController();
  late Future<List<Object>> _profileSwitchFuture;
  bool _profileSwitchPermissionRequested = false;

  CollectionLens? get currentCollection => widget.currentCollection;
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  void initState() {
    super.initState();
    _initProfileSwitchFuture();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case .resumed:
        if (_profileSwitchPermissionRequested) {
          _profileSwitchPermissionRequested = false;
          _initProfileSwitchFuture();
          setState(() {});
        }
      default:
        break;
    }
  }

  void _initProfileSwitchFuture() {
    _profileSwitchFuture = Future.wait([
      appProfileService.canRequestInteractAcrossProfiles(),
      appProfileService.canInteractAcrossProfiles(),
      appProfileService.getProfileSwitchingLabel(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final drawerItems = <Widget>[
      _buildHeader(context),
      _buildHomeLink(),
      if (settings.remotePinAtTop) ..._buildRemotePinnedLinks(context),
      ..._buildTypeLinks(),
      _buildAlbumLinks(context),
      if (!settings.remotePinAtTop) ..._buildRemotePinnedLinks(context),
      ..._buildPageLinks(context),
      if (settings.enableBin) ...[
        const Divider(),
        binTile(context),
      ],
      if (!kReleaseMode) ...[
        const Divider(),
        debugTile,
      ],
    ];

    return Drawer(
      child: ListTileTheme.merge(
        selectedColor: Theme.of(context).colorScheme.primary,
        horizontalTitleGap: 20,
        visualDensity: VisualDensity.comfortable,
        child: Selector<MediaQueryData, double>(
          selector: (context, mq) => mq.effectiveBottomPadding,
          builder: (context, mqPaddingBottom, child) {
            final textScaler = MediaQuery.textScalerOf(context);
            final iconTheme = IconTheme.of(context);
            return SingleChildScrollView(
              controller: _scrollController,
              // key is expected by test driver
              key: const Key('drawer-scrollview'),
              padding: EdgeInsets.only(bottom: mqPaddingBottom),
              child: IconTheme(
                data: iconTheme.copyWith(
                  size: textScaler.scale(iconTheme.size!),
                ),
                child: Column(
                  children: drawerItems,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = context.l10n;

    Future<void> goTo(String routeName, WidgetBuilder pageBuilder) async {
      final localNavigator = Navigator.maybeOf(context);
      final rootNavigator = Navigator.of(context, rootNavigator: true);
      localNavigator?.pop();
      await Future.delayed(ADurations.drawerTransitionLoose);
      if (!mounted) return;
      await rootNavigator.push(
        MaterialPageRoute(
          settings: RouteSettings(name: routeName),
          builder: pageBuilder,
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final onPrimary = colorScheme.onPrimary;

    final drawerButtonStyle = ButtonStyle(
      padding: WidgetStateProperty.all(const EdgeInsetsDirectional.only(start: 12, end: 16)),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: colorScheme.primary,
      child: SafeArea(
        bottom: false,
        child: OutlinedButtonTheme(
          data: OutlinedButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.all<Color>(onPrimary),
              overlayColor: WidgetStateProperty.all<Color>(onPrimary.withValues(alpha: .12)),
              iconColor: WidgetStateProperty.all<Color>(onPrimary),
              side: WidgetStateProperty.all<BorderSide>(BorderSide(width: 1, color: onPrimary.withValues(alpha: .24))),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const AvesLogo(size: 48),
                    OutlinedText(
                      textSpans: [
                        TextSpan(
                          text: l10n.appName,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 38,
                            fontWeight: FontWeight.w300,
                            letterSpacing: canHaveLetterSpacing(context.locale) ? 1 : 0,
                            fontFeatures: const [FontFeature.enable('smcp')],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    // key is expected by test driver
                    key: const Key('drawer-about-button'),
                    onPressed: () => goTo(AboutPage.routeName, (_) => const AboutPage()),
                    style: drawerButtonStyle,
                    icon: const Icon(AIcons.info),
                    label: Text(l10n.drawerAboutButton),
                  ),
                  OutlinedButton.icon(
                    // key is expected by test driver
                    key: const Key('drawer-settings-button'),
                    onPressed: () => goTo(SettingsPage.routeName, (_) => const SettingsPage()),
                    style: drawerButtonStyle,
                    icon: const Icon(AIcons.settings),
                    label: Text(l10n.drawerSettingsButton),
                  ),
                ],
              ),
              FutureBuilder<List<Object>>(
                future: _profileSwitchFuture,
                builder: (context, snapshot) {
                  final flags = snapshot.data;
                  if (flags == null) return const SizedBox();

                  final canRequestInteractAcrossProfiles = flags[0] as bool;
                  final canSwitchProfile = flags[1] as bool;
                  final profileSwitchingLabel = flags[2] as String;
                  if ((!canRequestInteractAcrossProfiles && !canSwitchProfile) || profileSwitchingLabel.isEmpty) return const SizedBox();

                  return OutlinedButton(
                    onPressed: () async {
                      if (canSwitchProfile) {
                        await appProfileService.switchProfile();
                      } else {
                        _profileSwitchPermissionRequested = await appProfileService.requestInteractAcrossProfiles();
                      }
                    },
                    child: Text(profileSwitchingLabel),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeLink() {
    // route name used for display purposes, no actual routing
    const displayRoute = HomePage.routeName;
    const leading = DrawerPageIcon(route: displayRoute);
    const title = DrawerPageTitle(route: displayRoute);

    switch (settings.homeNavItem.route) {
      case CollectionPage.routeName:
        final filters = settings.homeCustomCollection;
        if (filters.isNotEmpty) {
          return CollectionNavTile(
            leading: leading,
            title: title,
            filters: filters,
            isSelected: () => setEquals(currentCollection?.filters, filters),
          );
        }
      case ExplorerPage.routeName:
        final path = settings.homeCustomExplorerPath;
        if (path != null) {
          return PageNavTile(
            leading: leading,
            title: title,
            navItem: AvesNavItem(route: ExplorerPage.routeName, path: path),
            isSelected: () => widget.currentExplorerPath == path,
          );
        }
    }
    return const SizedBox();
  }

  List<Widget> _buildTypeLinks() {
    final hiddenFilters = settings.hiddenFilters;
    final typeBookmarks = settings.drawerTypeBookmarks;
    final currentFilters = currentCollection?.filters;
    return typeBookmarks
        .where((filter) => !hiddenFilters.contains(filter))
        .map(
          (filter) => CollectionNavTile(
            // key is expected by test driver
            key: Key('drawer-type-${filter?.key}'),
            leading: DrawerFilterIcon(filter: filter),
            title: DrawerFilterTitle(filter: filter),
            filters: {filter},
            isSelected: () {
              if (currentFilters == null || currentFilters.length > 1) return false;
              return currentFilters.firstOrNull == filter;
            },
          ),
        )
        .toList();
  }

  Widget _buildAlbumLinks(BuildContext context) {
    final source = context.read<CollectionSource>();
    final currentFilters = currentCollection?.filters;
    return StreamBuilder(
      stream: source.eventBus.on<AlbumsChangedEvent>(),
      builder: (context, snapshot) {
        final albums = AppDrawer.effectiveAlbumBookmarks(context);
        if (albums.isEmpty) return const SizedBox();
        return Column(
          children: [
            const Divider(),
            ...albums.map(
              (filter) => AlbumNavTile(
                filter: filter,
                isSelected: () {
                  if (currentFilters == null || currentFilters.length > 1) return false;
                  final currentFilter = currentFilters.firstOrNull;
                  if (currentFilter is StoredAlbumFilter && filter is StoredAlbumFilter) {
                    return currentFilter.album == filter.album;
                  } else if (currentFilter is DynamicAlbumFilter && filter is DynamicAlbumFilter) {
                    return currentFilter.name == filter.name;
                  }
                  return false;
                },
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildPageLinks(BuildContext context) {
    final pageBookmarks = settings.drawerPageBookmarks;
    if (pageBookmarks.isEmpty) return [];

    final source = context.read<CollectionSource>();
    return [
      const Divider(),
      ...pageBookmarks.map((route) {
        Widget? trailing;
        switch (route) {
          case AlbumListPage.routeName:
            trailing = StreamBuilder(
              stream: source.eventBus.on<AlbumsChangedEvent>(),
              builder: (context, _) => Text('${source.rawAlbums.length}'),
            );
          case CountryListPage.routeName:
            trailing = StreamBuilder(
              stream: source.eventBus.on<CountriesChangedEvent>(),
              builder: (context, _) => Text('${source.sortedCountries.length}'),
            );
          case PlaceListPage.routeName:
            trailing = StreamBuilder(
              stream: source.eventBus.on<PlacesChangedEvent>(),
              builder: (context, _) => Text('${source.sortedPlaces.length}'),
            );
          case TagListPage.routeName:
            trailing = StreamBuilder(
              stream: source.eventBus.on<TagsChangedEvent>(),
              builder: (context, _) => Text('${source.sortedTags.length}'),
            );
        }

        return PageNavTile(
          // key is expected by test driver
          key: Key('drawer-page-$route'),
          trailing: trailing,
          navItem: AvesNavItem(route: route),
        );
      }),
    ];
  }

  List<Widget> _buildRemotePinnedLinks(BuildContext context) {
    final allPinned = settings.remotePinnedFolders;
    if (allPinned.isEmpty) return const [];

    final servers = settings.remoteServers;
    final items = allPinned.where((v) => servers.byId(v.serverId) != null).toList();
    if (items.isEmpty) return const [];

    Future<void> goToPinned(RemotePinnedFolder folder) async {
      final server = servers.byId(folder.serverId);
      if (server == null) return;
      Navigator.maybeOf(context)?.pop();
      await Future.delayed(ADurations.drawerTransitionLoose);
      final source = context.read<CollectionSource>();
      final pathParts = folder.path.split('/').where((v) => v.isNotEmpty).toList();
      final leafName = pathParts.isEmpty ? '/' : pathParts.last;
      final remoteFilter = RemoteAlbumFilter(
        serverId: folder.serverId,
        path: folder.path,
        title: '${server.name}:$leafName',
      );
      final remoteFilters = {remoteFilter}.cast<AlbumBaseFilter>();
      final gridItems = FilterNavigationPage.sort<AlbumBaseFilter, AlbumChipSetActionDelegate>(
        settings.albumSortFactor,
        settings.albumSortReverse,
        source,
        remoteFilters,
      );
      await Navigator.maybeOf(context)?.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/remote-pinned-filter'),
          builder: (_) => FilterNavigationPage<AlbumBaseFilter, AlbumChipSetActionDelegate>(
            source: source,
            title: remoteFilter.title,
            sortFactor: settings.albumSortFactor,
            actionDelegate: AlbumChipSetActionDelegate(gridItems),
            filterSections: {
              const ChipSectionKey(): gridItems,
            },
            emptyBuilder: () => EmptyContent(
              icon: AIcons.storageMain,
              text: context.l10n.albumEmpty,
            ),
          ),
        ),
      );
    }

    Future<void> managePinned(RemoteServer server, RemotePinnedFolder folder) async {
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(AIcons.folder),
                title: Text(_tr(context, 'Open folder', '\u6253\u5f00\u76ee\u5f55')),
                onTap: () => Navigator.maybeOf(sheetContext)?.pop('open'),
              ),
              ListTile(
                leading: const Icon(AIcons.clear),
                title: Text(_tr(context, 'Clear folder cache', '\u6e05\u7406\u76ee\u5f55\u7f13\u5b58')),
                onTap: () => Navigator.maybeOf(sheetContext)?.pop('clear_cache'),
              ),
              ListTile(
                leading: const Icon(AIcons.unpin),
                title: Text(_tr(context, 'Remove from albums', '\u4ece\u76f8\u518c\u79fb\u9664')),
                subtitle: Text(_tr(context, 'Auto clear folder cache', '\u81ea\u52a8\u6e05\u7406\u76ee\u5f55\u7f13\u5b58')),
                onTap: () => Navigator.maybeOf(sheetContext)?.pop('remove'),
              ),
            ],
          ),
        ),
      );
      switch (action) {
        case 'open':
          await goToPinned(folder);
        case 'clear_cache':
          final cleared = await remoteMediaService.clearPinnedFolderCache(server: server, folderPath: folder.path);
          if (!mounted) return;
          showFeedback(
            context,
            cleared ? FeedbackType.info : FeedbackType.warn,
            cleared ? _tr(context, 'Folder cache cleared', '\u76ee\u5f55\u7f13\u5b58\u5df2\u6e05\u7406') : _tr(context, 'Failed to clear folder cache', '\u76ee\u5f55\u7f13\u5b58\u6e05\u7406\u5931\u8d25'),
          );
          setState(() {});
        case 'remove':
          final cleared = await remoteMediaService.clearPinnedFolderCache(server: server, folderPath: folder.path);
          settings.remotePinnedFolders = settings.remotePinnedFolders.where((v) => !(v.serverId == server.id && v.path == folder.path)).toList();
          if (!mounted) return;
          showFeedback(
            context,
            FeedbackType.info,
            cleared ? _tr(context, 'Removed and cache cleared', '\u5df2\u79fb\u9664\u5e76\u6e05\u7406\u7f13\u5b58') : _tr(context, 'Removed from albums', '\u5df2\u4ece\u76f8\u518c\u79fb\u9664'),
          );
          setState(() {});
      }
    }

    final grouped = <RemoteServer, List<RemotePinnedFolder>>{};
    for (final folder in items) {
      final server = servers.byId(folder.serverId);
      if (server == null) continue;
      grouped.putIfAbsent(server, () => []).add(folder);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.path.compareTo(b.path));
    }

    return [
      const Divider(),
      ExpansionTile(
        leading: const Icon(AIcons.storageMain),
        title: Text(_tr(context, 'Remote Albums', '\u8fdc\u7a0b\u76f8\u518c\u5217\u8868')),
        subtitle: Text(_tr(context, 'Connection -> Folder', '\u8fde\u63a5 -> \u6587\u4ef6\u5939')),
        children: grouped.entries.map((entry) {
          final server = entry.key;
          final folders = entry.value;
          return ExpansionTile(
            leading: const Icon(AIcons.storageMain),
            title: Text(server.name),
            subtitle: Text(_tr(context, '${folders.length} folders', '${folders.length} \u4e2a\u6587\u4ef6\u5939')),
            children: folders.map((folder) {
              final pathParts = folder.path.split('/').where((v) => v.isNotEmpty).toList();
              final leafName = pathParts.isEmpty ? '/' : pathParts.last;
              return ListTile(
                dense: true,
                leading: const Icon(AIcons.folder),
                title: Text(leafName),
                subtitle: Text(folder.path),
                onTap: () => goToPinned(folder),
                onLongPress: () => managePinned(server, folder),
              );
            }).toList(),
          );
        }).toList(),
      ),
    ];
  }

  Widget binTile(BuildContext context) {
    final source = context.read<CollectionSource>();
    final trashSize = source.trashedEntries.fold<int>(0, (sum, entry) => sum + (entry.sizeBytes ?? 0));

    const filter = TrashFilter.instance;
    return CollectionNavTile(
      leading: const DrawerFilterIcon(filter: filter),
      title: const DrawerFilterTitle(filter: filter),
      trailing: Text(formatFileSize(context.locale, trashSize, round: 0)),
      filters: {filter},
      isSelected: () => currentCollection?.filters.contains(filter) ?? false,
    );
  }

  Widget get debugTile => const PageNavTile(
    // key is expected by test driver
    key: Key('drawer-debug'),
    navItem: AvesNavItem(route: AppDebugPage.routeName),
  );
}
