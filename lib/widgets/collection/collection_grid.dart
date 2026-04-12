import 'dart:async';
import 'dart:math';

import 'package:aves/app_mode.dart';
import 'package:aves/model/app/permissions.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/filters/favourite.dart';
import 'package:aves/model/filters/mime.dart';
import 'package:aves/model/remote/remote_protocol.dart';
import 'package:aves/model/selection.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_lens.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/model/source/section_keys.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/durations.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/utils/time_utils.dart';
import 'package:aves/widgets/collection/app_bar.dart';
import 'package:aves/widgets/collection/draggable_thumb_label.dart';
import 'package:aves/widgets/collection/grid/list_details_theme.dart';
import 'package:aves/widgets/collection/grid/section_layout.dart';
import 'package:aves/widgets/collection/grid/tile.dart';
import 'package:aves/widgets/collection/loading.dart';
import 'package:aves/widgets/common/basic/draggable_scrollbar/scrollbar.dart';
import 'package:aves/widgets/common/basic/insets.dart';
import 'package:aves/widgets/common/behaviour/routes.dart';
import 'package:aves/widgets/common/behaviour/sloppy_scroll_physics.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/extensions/media_query.dart';
import 'package:aves/widgets/common/grid/draggable_thumb_label.dart';
import 'package:aves/widgets/common/grid/item_tracker.dart';
import 'package:aves/widgets/common/grid/scaling.dart';
import 'package:aves/widgets/common/grid/sections/fixed/scale_grid.dart';
import 'package:aves/widgets/common/grid/sections/list_layout.dart';
import 'package:aves/widgets/common/grid/sections/section_layout.dart';
import 'package:aves/widgets/common/grid/selector.dart';
import 'package:aves/widgets/common/grid/sliver.dart';
import 'package:aves/widgets/common/grid/theme.dart';
import 'package:aves/widgets/common/identity/buttons/outlined_button.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/common/identity/scroll_thumb.dart';
import 'package:aves/widgets/common/providers/tile_extent_controller_provider.dart';
import 'package:aves/widgets/common/providers/viewer_entry_provider.dart';
import 'package:aves/widgets/common/thumbnail/decorated.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/common/thumbnail/notifications.dart';
import 'package:aves/widgets/common/tile_extent_controller.dart';
import 'package:aves/widgets/navigation/nav_bar/nav_bar.dart';
import 'package:aves/widgets/viewer/entry_viewer_page.dart';
import 'package:aves/widgets/viewer/video/conductor.dart';
import 'package:aves/widgets/viewer/viewer_pop_result.dart';
import 'package:aves_video/aves_video.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

class CollectionGrid extends StatefulWidget {
  final String settingsRouteKey;

  static const double extentMin = 46;
  static const double extentMax = 300;
  static const double fixedExtentLayoutSpacing = 2;
  static const double mosaicLayoutSpacing = 4;

  static int get columnCountDefault => settings.useTvLayout ? 6 : 4;

  const CollectionGrid({
    super.key,
    required this.settingsRouteKey,
  });

  @override
  State<CollectionGrid> createState() => _CollectionGridState();
}

class _CollectionGridState extends State<CollectionGrid> {
  TileExtentController? _tileExtentController;

  String get settingsRouteKey => widget.settingsRouteKey;

  @override
  void dispose() {
    _tileExtentController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.select<Settings, double>((v) => v.getTileLayout(settingsRouteKey) == TileLayout.mosaic ? CollectionGrid.mosaicLayoutSpacing : CollectionGrid.fixedExtentLayoutSpacing);
    if (_tileExtentController?.spacing != spacing) {
      _tileExtentController = TileExtentController(
        settingsRouteKey: settingsRouteKey,
        columnCountMin: settings.allowSingleColumnPreview ? 1 : 2,
        columnCountDefault: CollectionGrid.columnCountDefault,
        extentMin: CollectionGrid.extentMin,
        extentMax: CollectionGrid.extentMax,
        spacing: spacing,
        horizontalPadding: 2,
      );
    }
    return TileExtentControllerProvider(
      controller: _tileExtentController!,
      child: const _CollectionGridContent(),
    );
  }
}

class _CollectionGridContent extends StatefulWidget {
  const _CollectionGridContent();

  @override
  State<_CollectionGridContent> createState() => _CollectionGridContentState();
}

class _CollectionGridContentState extends State<_CollectionGridContent> {
  final ValueNotifier<AvesEntry?> _focusedItemNotifier = ValueNotifier(null);
  final ValueNotifier<AvesEntry?> _previewPlayingEntryNotifier = ValueNotifier(null);
  final ValueNotifier<ViewerPopResult?> _viewerReturnNotifier = ValueNotifier(null);
  final ValueNotifier<bool> _isScrollingNotifier = ValueNotifier(false);
  final ValueNotifier<AppMode> _selectingAppModeNotifier = ValueNotifier(AppMode.pickFilteredMediaInternal);
  ViewerEntryNotifier? _viewerEntryNotifier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _viewerEntryNotifier?.value = null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewerEntryNotifier = context.read<ViewerEntryNotifier>();
  }

  @override
  void dispose() {
    _focusedItemNotifier.dispose();
    _previewPlayingEntryNotifier.dispose();
    _viewerReturnNotifier.dispose();
    _isScrollingNotifier.dispose();
    _selectingAppModeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectable = context.select<ValueNotifier<AppMode>, bool>((v) => v.value.canSelectMedia);
    final settingsRouteKey = context.read<TileExtentController>().settingsRouteKey;
    final tileLayout = context.select<Settings, TileLayout>((v) => v.getTileLayout(settingsRouteKey));
    return Consumer<CollectionLens>(
      builder: (context, collection, child) {
        final sectionedListLayoutProvider = ValueListenableBuilder<double>(
          valueListenable: context.select<TileExtentController, ValueNotifier<double>>((controller) => controller.extentNotifier),
          builder: (context, thumbnailExtent, child) {
            assert(thumbnailExtent > 0);
            return Selector<TileExtentController, (double, int, double, double)>(
              selector: (context, c) => (c.viewportSize.width, c.columnCount, c.spacing, c.horizontalPadding),
              builder: (context, c, child) {
                final (scrollableWidth, columnCount, tileSpacing, horizontalPadding) = c;
                final effectiveSpacing = columnCount == 1 ? max(tileSpacing, 8.0) : tileSpacing;
                final effectiveHorizontalPadding = columnCount == 1 ? max(horizontalPadding, 8.0) : horizontalPadding;
                final source = collection.source;
                return GridTheme(
                  extent: thumbnailExtent,
                  child: EntryListDetailsTheme(
                    extent: thumbnailExtent,
                    child: ValueListenableBuilder<SourceState>(
                      valueListenable: source.stateNotifier,
                      builder: (context, sourceState, child) {
                        late final Duration tileAnimationDelay;
                        if (sourceState == SourceState.ready) {
                          // do not listen for animation delay change
                          final target = context.read<DurationsData>().staggeredAnimationPageTarget;
                          tileAnimationDelay = context.read<TileExtentController>().getTileAnimationDelay(target);
                        } else {
                          tileAnimationDelay = Duration.zero;
                        }

                        return NotificationListener<OpenViewerNotification>(
                          onNotification: (notification) {
                            _goToViewer(collection, notification.entry);
                            return true;
                          },
                          child: StreamBuilder(
                            stream: source.eventBus.on<AspectRatioChangedEvent>(),
                            builder: (context, snapshot) => SectionedEntryListLayoutProvider(
                              collection: collection,
                              selectable: selectable,
                              scrollableWidth: scrollableWidth,
                              tileLayout: tileLayout,
                              columnCount: columnCount,
                              spacing: effectiveSpacing,
                              horizontalPadding: effectiveHorizontalPadding,
                              tileExtent: thumbnailExtent,
                              tileBuilder: (entry, tileSize) {
                                final extent = tileSize.shortestSide;
                                return AnimatedBuilder(
                                  animation: favourites,
                                  builder: (context, child) {
                                    Widget tile = InteractiveTile(
                                      key: ValueKey(entry.id),
                                      collection: collection,
                                      entry: entry,
                                      thumbnailExtent: extent,
                                      tileLayout: tileLayout,
                                      isScrollingNotifier: _isScrollingNotifier,
                                      playbackFocusNotifier: _previewPlayingEntryNotifier,
                                      viewerReturnNotifier: _viewerReturnNotifier,
                                    );
                                    if (!settings.useTvLayout) return tile;

                                    return Focus(
                                      onFocusChange: (focused) {
                                        if (focused) {
                                          _focusedItemNotifier.value = entry;
                                        } else if (_focusedItemNotifier.value == entry) {
                                          _focusedItemNotifier.value = null;
                                        }
                                      },
                                      child: ValueListenableBuilder<AvesEntry?>(
                                        valueListenable: _focusedItemNotifier,
                                        builder: (context, focusedItem, child) {
                                          return AnimatedScale(
                                            scale: focusedItem == entry ? 1 : .9,
                                            curve: Curves.fastOutSlowIn,
                                            duration: context.select<DurationsData, Duration>((v) => v.tvImageFocusAnimation),
                                            child: child!,
                                          );
                                        },
                                        child: tile,
                                      ),
                                    );
                                  },
                                );
                              },
                              tileAnimationDelay: tileAnimationDelay,
                              child: child!,
                            ),
                          ),
                        );
                      },
                      child: child,
                    ),
                  ),
                );
              },
              child: child,
            );
          },
          child: _CollectionSectionedContent(
            collection: collection,
            isScrollingNotifier: _isScrollingNotifier,
            previewPlayingEntryNotifier: _previewPlayingEntryNotifier,
            viewerReturnNotifier: _viewerReturnNotifier,
            scrollController: PrimaryScrollController.of(context),
            tileLayout: tileLayout,
            selectable: selectable,
          ),
        );
        return sectionedListLayoutProvider;
      },
    );
  }

  Future<void> _goToViewer(CollectionLens collection, AvesEntry entry) async {
    // track viewer entry for dynamic hero placeholder
    final viewerEntryNotifier = context.read<ViewerEntryNotifier>();
    final initialPreviewPositionMillis = entry.isVideo ? context.read<VideoConductor>().getController(entry)?.currentPosition : null;

    // `EntryViewerPage` is pushed with a transparent route, so the collection page
    // remains alive underneath it. Pause grid preview playback proactively to avoid
    // remote stream competition between grid preview and viewer.
    _previewPlayingEntryNotifier.value = null;
    await context.read<VideoConductor>().pauseAll();

    // prevent navigating again to the same entry until fully back,
    // as a workaround for the hero pop/push diversion animation issue
    // (cf `ThumbnailImage` `Hero` usage)
    if (viewerEntryNotifier.value == entry) return;
    viewerEntryNotifier.value = entry;

    final selection = context.read<Selection<AvesEntry>>();
    final result = await Navigator.maybeOf(context)?.push<ViewerPopResult>(
      TransparentMaterialPageRoute(
        settings: const RouteSettings(name: EntryViewerPage.routeName),
        pageBuilder: (context, a, sa) {
          final viewerCollection = collection.copyWith(
            listenToSource: false,
          );
          Widget child = EntryViewerPage(
            collection: viewerCollection,
            initialEntry: entry,
            initialPreviewPositionMillis: initialPreviewPositionMillis != null && initialPreviewPositionMillis > 0 ? initialPreviewPositionMillis : null,
          );

          if (selection.isSelecting) {
            child = MultiProvider(
              providers: [
                ListenableProvider<ValueNotifier<AppMode>>.value(value: _selectingAppModeNotifier),
                ChangeNotifierProvider<Selection<AvesEntry>>.value(value: selection),
              ],
              child: child,
            );
          }

          return child;
        },
      ),
    );

    // reset track viewer entry
    final animate = context.read<Settings>().animate;
    if (animate) {
      // TODO TLAD fix timing when transition is incomplete, e.g. when going back while going to the viewer
      await Future.delayed(ADurations.pageTransitionExact * timeDilation);
    }
    viewerEntryNotifier.value = null;
    if (!mounted || result == null) return;
    await _restoreViewerReturn(result);
  }

  Future<void> _restoreViewerReturn(ViewerPopResult result) async {
    final entry = result.entry;
    _viewerReturnNotifier.value = result;
    _focusedItemNotifier.value = entry;
    if (!entry.isVideo) {
      return;
    }

    final positionMillis = result.previewPositionMillis;
    if (positionMillis != null && positionMillis > 0) {
      final conductor = context.read<VideoConductor>();
      final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
      try {
        if (remoteProtocol == RemoteProtocol.webdav) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'collection_viewer_return_restore');
        } else if (remoteProtocol == RemoteProtocol.ftp) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'collection_viewer_return_restore');
        } else if (remoteProtocol == RemoteProtocol.sftp) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'collection_viewer_return_restore');
        } else if (remoteProtocol == RemoteProtocol.smb) {
          await remoteMediaService.prepareInitialStreamPlaybackForEntry(entry, trigger: 'collection_viewer_return_restore');
        }

        final controller = await conductor.getOrCreateController(entry, maxControllerCount: 5);
        try {
          await controller.untilReady.timeout(const Duration(milliseconds: 800));
        } catch (_) {}
        try {
          await controller.seekTo(positionMillis);
        } catch (_) {}
      } catch (_) {}
    }

    _previewPlayingEntryNotifier.value = entry;
  }
}

class _CollectionSectionedContent extends StatefulWidget {
  final CollectionLens collection;
  final ValueNotifier<bool> isScrollingNotifier;
  final ValueNotifier<AvesEntry?> previewPlayingEntryNotifier;
  final ValueNotifier<ViewerPopResult?> viewerReturnNotifier;
  final ScrollController scrollController;
  final TileLayout tileLayout;
  final bool selectable;

  const _CollectionSectionedContent({
    required this.collection,
    required this.isScrollingNotifier,
    required this.previewPlayingEntryNotifier,
    required this.viewerReturnNotifier,
    required this.scrollController,
    required this.tileLayout,
    required this.selectable,
  });

  @override
  State<_CollectionSectionedContent> createState() => _CollectionSectionedContentState();
}

class _CollectionSectionedContentState extends State<_CollectionSectionedContent> {
  final ValueNotifier<double> _appBarHeightNotifier = ValueNotifier(0);
  final GlobalKey _scrollableKey = GlobalKey(debugLabel: 'thumbnail-collection-scrollable');
  Timer? _focusDebounceTimer;
  Timer? _deferredPrefetchTimer;
  AvesEntry? _pendingFocusTarget;
  DateTime _lastPrefetchAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastPrefetchSignature;
  DateTime _lastKeepFocusLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastKeepFocusLogUri;
  double? _lastScrollOffset;
  DateTime? _lastScrollSampleAt;
  double _lastScrollSpeedPxPerSecond = 0;
  DateTime? _initialFocusLockUntil;
  String? _initialFocusLockedUri;
  double? _initialFocusLockOffset;
  DateTime _lastVideoPreheatAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastVideoPreheatSignature;
  DateTime _lastFastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastEdgeFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastEdgeFocusUri;
  DateTime _lastFocusChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  ScrollDirection _lastScrollIntentDirection = ScrollDirection.idle;
  DateTime _lastScrollIntentAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _prefetchRequestToken = 0;
  late VideoConductor _videoConductor;

  CollectionLens get collection => widget.collection;

  TileLayout get tileLayout => widget.tileLayout;

  ScrollController get scrollController => widget.scrollController;

  String _remotePrefetchIdentity(AvesEntry entry) {
    final ref = remoteMediaService.getVirtualRemoteRef(entry.uri);
    final protocol = ref?.$1.protocol ?? remoteMediaService.getRemoteProtocolForEntry(entry);
    if (protocol == RemoteProtocol.webdav && ref != null) {
      return 'webdav:${ref.$1.id}:${ref.$2.path}';
    } else if (protocol == RemoteProtocol.ftp && ref != null) {
      return 'ftp:${ref.$1.id}:${ref.$2.path}';
    } else if (protocol == RemoteProtocol.sftp && ref != null) {
      return 'sftp:${ref.$1.id}:${ref.$2.path}';
    } else if (protocol == RemoteProtocol.smb && ref != null) {
      return 'smb:${ref.$1.id}:${ref.$2.path}';
    } else if (protocol == null) {
      return entry.uri;
    }
    return entry.uri;
  }

  int _imagePrefetchDedupeWindowMillis(AvesEntry anchor) {
    final protocol = remoteMediaService.getVirtualRemoteRef(anchor.uri)?.$1.protocol ?? remoteMediaService.getRemoteProtocolForEntry(anchor);
    if (protocol == RemoteProtocol.webdav) {
      return 2800;
    } else if (protocol == RemoteProtocol.ftp) {
      return 1500;
    } else if (protocol == RemoteProtocol.sftp) {
      return 1500;
    } else if (protocol == RemoteProtocol.smb) {
      return 2800;
    }
    return 1500;
  }

  int _videoPreheatDedupeWindowMillis(AvesEntry anchor) {
    final protocol = remoteMediaService.getVirtualRemoteRef(anchor.uri)?.$1.protocol ?? remoteMediaService.getRemoteProtocolForEntry(anchor);
    if (protocol == RemoteProtocol.webdav) {
      return 3200;
    } else if (protocol == RemoteProtocol.ftp) {
      return 1800;
    } else if (protocol == RemoteProtocol.sftp) {
      return 1800;
    } else if (protocol == RemoteProtocol.smb) {
      return 3200;
    }
    return 1800;
  }

  int _imagePrefetchConcurrency(AvesEntry anchor) {
    final protocol = remoteMediaService.getVirtualRemoteRef(anchor.uri)?.$1.protocol ?? remoteMediaService.getRemoteProtocolForEntry(anchor);
    if (protocol == RemoteProtocol.webdav) {
      return 2;
    } else if (protocol == RemoteProtocol.ftp) {
      return 2;
    } else if (protocol == RemoteProtocol.sftp) {
      return 2;
    } else if (protocol == RemoteProtocol.smb) {
      return 2;
    }
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _appBarHeightNotifier.addListener(_onAppBarHeightChanged);
    scrollController.addListener(_onScrollOrLayoutChanged);
    widget.isScrollingNotifier.addListener(_onScrollingStateChanged);
    widget.viewerReturnNotifier.addListener(_onViewerReturnChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onScrollOrLayoutChanged();
      Future.delayed(const Duration(milliseconds: 140), _onScrollOrLayoutChanged);
      Future.delayed(const Duration(milliseconds: 320), _onScrollOrLayoutChanged);
      Future.delayed(const Duration(milliseconds: 680), _onScrollOrLayoutChanged);
      Future.delayed(const Duration(milliseconds: 1100), _onScrollOrLayoutChanged);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _videoConductor = context.read<VideoConductor>();
  }

  @override
  void didUpdateWidget(covariant _CollectionSectionedContent oldWidget) {
    super.didUpdateWidget(oldWidget);

    final currentPreview = widget.previewPlayingEntryNotifier.value;
    if (currentPreview == null) return;

    final entries = collection.sortedEntries;
    final stillVisible = entries.any((entry) => entry.uri == currentPreview.uri);
    if (!stillVisible) {
      widget.previewPlayingEntryNotifier.value = null;
      _pendingFocusTarget = null;
      _focusDebounceTimer?.cancel();
      _deferredPrefetchTimer?.cancel();
      return;
    }

    final firstEntry = entries.firstOrNull;
    final nearTop =
        scrollController.hasClients &&
        scrollController.offset <= scrollController.position.minScrollExtent + 24;
    if (nearTop && firstEntry != null && !firstEntry.isVideo && currentPreview.uri != firstEntry.uri) {
      widget.previewPlayingEntryNotifier.value = null;
      _pendingFocusTarget = null;
      _focusDebounceTimer?.cancel();
      _deferredPrefetchTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onScrollOrLayoutChanged();
      });
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(_onScrollOrLayoutChanged);
    widget.isScrollingNotifier.removeListener(_onScrollingStateChanged);
    widget.viewerReturnNotifier.removeListener(_onViewerReturnChanged);
    _focusDebounceTimer?.cancel();
    _deferredPrefetchTimer?.cancel();
    widget.previewPlayingEntryNotifier.value = null;
    _appBarHeightNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrollView = AnimationLimiter(
      child: _CollectionScrollView(
        scrollableKey: _scrollableKey,
        collection: collection,
        appBar: CollectionAppBar(
          appBarHeightNotifier: _appBarHeightNotifier,
          scrollController: scrollController,
          collection: collection,
        ),
        appBarHeightNotifier: _appBarHeightNotifier,
        isScrollingNotifier: widget.isScrollingNotifier,
        scrollController: scrollController,
        onScrollIntent: _onScrollIntent,
      ),
    );

    final scaler = _CollectionScaler(
      scrollableKey: _scrollableKey,
      appBarHeightNotifier: _appBarHeightNotifier,
      tileLayout: tileLayout,
      child: scrollView,
    );

    final selector = GridSelectionGestureDetector<AvesEntry>(
      scrollableKey: _scrollableKey,
      selectable: widget.selectable,
      items: collection.sortedEntries,
      scrollController: scrollController,
      appBarHeightNotifier: _appBarHeightNotifier,
      child: scaler,
    );

    return GridItemTracker<AvesEntry>(
      scrollableKey: _scrollableKey,
      tileLayout: tileLayout,
      appBarHeightNotifier: _appBarHeightNotifier,
      scrollController: scrollController,
      child: selector,
    );
  }

  void _onAppBarHeightChanged() => setState(() {});

  void _onScrollIntent(ScrollDirection direction) {
    _lastScrollIntentDirection = direction;
    _lastScrollIntentAt = DateTime.now();
    if (direction != ScrollDirection.idle) {
      _onScrollOrLayoutChanged();
    }
  }

  void _onScrollingStateChanged() {
    if (!widget.isScrollingNotifier.value) {
      _deferredPrefetchTimer?.cancel();
      _deferredPrefetchTimer = Timer(const Duration(milliseconds: 80), () {
        if (!mounted) return;
        _onScrollOrLayoutChanged();
        unawaited(_prefetchRemoteWindow(widget.previewPlayingEntryNotifier.value));
      });
    }
  }

  void _onViewerReturnChanged() {
    final result = widget.viewerReturnNotifier.value;
    final entry = result?.entry;
    if (entry == null) return;
    _initialFocusLockUntil = DateTime.now().add(const Duration(milliseconds: 1800));
    _initialFocusLockedUri = entry.uri;
    _initialFocusLockOffset = scrollController.hasClients ? scrollController.offset : _initialFocusLockOffset;
    _applyFocusTarget(entry);
  }

  void _onScrollOrLayoutChanged() {
    final scrollableContext = _scrollableKey.currentContext;
    if (scrollableContext == null) return;
    final renderObject = scrollableContext.findRenderObject();
    if (renderObject is! RenderBox) return;
    if (!mounted) return;

    final layout = context.read<SectionedListLayout<AvesEntry>>();
    final size = renderObject.size;
    final viewportTopY = scrollController.offset - _appBarHeightNotifier.value;
    final minScrollExtent = scrollController.position.minScrollExtent;
    final maxScrollExtent = scrollController.position.maxScrollExtent;
    final currentOffset = scrollController.offset;
    final previousOffset = _lastScrollOffset ?? currentOffset;
    final now = DateTime.now();
    final userDirection = scrollController.hasClients ? scrollController.position.userScrollDirection : ScrollDirection.idle;
    final effectiveDirection = userDirection != ScrollDirection.idle && widget.isScrollingNotifier.value
        ? userDirection
        : now.difference(_lastScrollIntentAt).inMilliseconds <= 700
        ? _lastScrollIntentDirection
        : userDirection;
    final scrollingTowardBottom = effectiveDirection == ScrollDirection.reverse || (effectiveDirection == ScrollDirection.idle && currentOffset > previousOffset);
    _lastScrollOffset = currentOffset;
    final sampleAt = _lastScrollSampleAt;
    if (sampleAt != null) {
      final dtMs = now.difference(sampleAt).inMilliseconds;
      if (dtMs > 0) {
        _lastScrollSpeedPxPerSecond = ((currentOffset - previousOffset).abs() * 1000) / dtMs;
      }
      if (widget.isScrollingNotifier.value && _lastScrollSpeedPxPerSecond >= 900) {
        _lastFastScrollAt = now;
      }
    }
    _lastScrollSampleAt = now;
    if (_initialFocusLockOffset != null && (currentOffset - _initialFocusLockOffset!).abs() > 24) {
      _initialFocusLockUntil = null;
      _initialFocusLockedUri = null;
      _initialFocusLockOffset = null;
    }

    final probesY = <double>[
      viewportTopY + size.height * .52,
      viewportTopY + size.height * .60,
      viewportTopY + size.height * .68,
      viewportTopY + size.height * .74,
    ];
    if (currentOffset <= minScrollExtent + size.height * .18) {
      probesY.insertAll(0, [
        viewportTopY + size.height * .16,
        viewportTopY + size.height * .28,
        viewportTopY + size.height * .40,
      ]);
    }
    if (currentOffset >= maxScrollExtent - size.height * .18) {
      probesY.addAll([
        viewportTopY + size.height * .82,
        viewportTopY + size.height * .92,
      ]);
    }
    final probesX = [
      size.width * .5,
      size.width * .33,
      size.width * .67,
      size.width * .2,
      size.width * .8,
      size.width * .08,
      size.width * .92,
      0.0,
      size.width,
    ];

    AvesEntry? target;
    AvesEntry? anchor;
    AvesEntry? firstVisibleCandidate;
    AvesEntry? lastVisibleCandidate;
    for (final y in probesY) {
      for (final x in probesX) {
        final candidate = layout.getItemAt(Offset(x, y));
        anchor ??= candidate;
        firstVisibleCandidate ??= candidate;
        lastVisibleCandidate = candidate ?? lastVisibleCandidate;
        if (candidate?.isVideo == true) {
          target = candidate;
          break;
        }
      }
      if (target != null) break;
    }
    final preserveLeadingNonVideoAtTop =
        widget.previewPlayingEntryNotifier.value == null &&
        currentOffset <= minScrollExtent + size.height * .18 &&
        firstVisibleCandidate != null &&
        !firstVisibleCandidate.isVideo;
    if (!preserveLeadingNonVideoAtTop) {
      final edgeTarget = _resolveEdgeFocusTarget(
        layout: layout,
        size: size,
        viewportTopY: viewportTopY,
        currentOffset: currentOffset,
        minScrollExtent: minScrollExtent,
        maxScrollExtent: maxScrollExtent,
        scrollingTowardBottom: scrollingTowardBottom,
        probesX: probesX,
        firstVisibleCandidate: firstVisibleCandidate,
        lastVisibleCandidate: lastVisibleCandidate,
        fallbackAnchor: lastVisibleCandidate ?? anchor,
      );
      target = edgeTarget ?? target;
      target ??= _resolveInitialTopFocusTarget(
        currentOffset: currentOffset,
        minScrollExtent: minScrollExtent,
        fallbackAnchor: lastVisibleCandidate ?? anchor,
      );
    } else {
      target = null;
    }
    unawaited(_prefetchRemoteWindow(anchor));
    _scheduleFocusUpdate(target);
  }

  AvesEntry? _resolveInitialTopFocusTarget({
    required double currentOffset,
    required double minScrollExtent,
    required AvesEntry? fallbackAnchor,
  }) {
    if (widget.previewPlayingEntryNotifier.value != null) return null;
    final nearTop = currentOffset <= minScrollExtent + 24;
    if (!nearTop) return null;

    final entries = collection.sortedEntries;
    if (entries.isEmpty) return null;

    final anchor = fallbackAnchor ?? entries.firstOrNull;
    if (anchor == null) return null;
    final target = _findClosestVideoEntry(anchor, searchBackward: false);
    if (target != null) {
      _initialFocusLockUntil = DateTime.now().add(const Duration(milliseconds: 1200));
      _initialFocusLockedUri = target.uri;
      _initialFocusLockOffset = currentOffset;
      unawaited(
        remoteMediaLogService.log(
          'focus',
          'resolved initial collection preview focus near top',
          data: {
            'anchorUri': anchor.uri,
            'targetUri': target.uri,
          },
        ),
      );
    }
    return target;
  }

  AvesEntry? _resolveEdgeFocusTarget({
    required SectionedListLayout<AvesEntry> layout,
    required Size size,
    required double viewportTopY,
    required double currentOffset,
    required double minScrollExtent,
    required double maxScrollExtent,
    required bool scrollingTowardBottom,
    required List<double> probesX,
    required AvesEntry? firstVisibleCandidate,
    required AvesEntry? lastVisibleCandidate,
    required AvesEntry? fallbackAnchor,
  }) {
    final entries = collection.sortedEntries;
    final firstVisibleIndex = firstVisibleCandidate != null ? entries.indexOf(firstVisibleCandidate) : -1;
    final lastVisibleIndex = lastVisibleCandidate != null ? entries.indexOf(lastVisibleCandidate) : -1;
    final currentFocus = widget.previewPlayingEntryNotifier.value;
    final currentFocusIndex = currentFocus != null ? entries.indexOf(currentFocus) : -1;
    final atListTop = entries.isNotEmpty && firstVisibleIndex == 0;
    final atListBottom = entries.isNotEmpty && lastVisibleIndex == entries.length - 1;
    final nearTop = currentOffset <= minScrollExtent + size.height * .18 || atListTop;
    final nearBottom = currentOffset >= maxScrollExtent - size.height * .18 || atListBottom;
    if (!nearTop && !nearBottom) return null;

    final forceTop = nearTop && !scrollingTowardBottom;
    final forceBottom = nearBottom && scrollingTowardBottom;
    if (!forceTop && !forceBottom) return null;

    final fastScroll = widget.isScrollingNotifier.value && _lastScrollSpeedPxPerSecond >= 1400;
    if (fastScroll) return null;

    final now = DateTime.now();
    final withinEdgeCooldown = now.difference(_lastEdgeFocusAt) < const Duration(milliseconds: 900);
    final currentFocusVisible = currentFocus != null && currentFocusIndex >= 0 && firstVisibleIndex >= 0 && lastVisibleIndex >= 0 && currentFocusIndex >= firstVisibleIndex && currentFocusIndex <= lastVisibleIndex;
    if (withinEdgeCooldown && currentFocusVisible && currentFocus.isVideo) {
      return currentFocus;
    }

    final edgeProbeYs = forceTop
        ? [
            viewportTopY + size.height * .06,
            viewportTopY + size.height * .16,
            viewportTopY + size.height * .28,
          ]
        : [
            viewportTopY + size.height * .94,
            viewportTopY + size.height * .84,
            viewportTopY + size.height * .72,
          ];

    AvesEntry? edgeAnchor;
    for (final y in edgeProbeYs) {
      for (final x in probesX) {
        final candidate = layout.getItemAt(Offset(x, y));
        edgeAnchor ??= candidate;
        if (candidate?.isVideo == true) {
          final uri = candidate?.uri;
          final sameTarget = _lastEdgeFocusUri == uri;
          final withinCooldown = now.difference(_lastEdgeFocusAt) < const Duration(milliseconds: 900);
          if (!(sameTarget && withinCooldown)) {
            _lastEdgeFocusUri = uri;
            _lastEdgeFocusAt = now;
            unawaited(
              remoteMediaLogService.log(
                'focus',
                'forced preview focus at collection edge',
                data: {
                  'uri': uri,
                  'atTop': forceTop,
                  'atBottom': forceBottom,
                },
              ),
            );
          }
          return candidate;
        }
      }
    }

    final anchor = edgeAnchor ?? fallbackAnchor;
    if (anchor == null) return null;
    return _findClosestVideoEntry(anchor, searchBackward: forceTop);
  }

  AvesEntry? _findClosestVideoEntry(AvesEntry anchor, {required bool searchBackward}) {
    final entries = collection.sortedEntries;
    final anchorIndex = entries.indexOf(anchor);
    if (anchorIndex < 0) return null;

    if (searchBackward) {
      for (var i = anchorIndex; i >= 0; i--) {
        final entry = entries[i];
        if (entry.isVideo) return entry;
      }
    } else {
      for (var i = anchorIndex; i < entries.length; i++) {
        final entry = entries[i];
        if (entry.isVideo) return entry;
      }
    }
    return null;
  }

  void _scheduleFocusUpdate(AvesEntry? target) {
    final isScrolling = widget.isScrollingNotifier.value;
    final current = widget.previewPlayingEntryNotifier.value;
    if (current == target) return;
    final now = DateTime.now();
    if (isScrolling && current != null && target != null && current.uri != target.uri) {
      final sameUri = _lastKeepFocusLogUri == current.uri;
      final withinCooldown = now.difference(_lastKeepFocusLogAt) < const Duration(milliseconds: 900);
      if (!(sameUri && withinCooldown)) {
        _lastKeepFocusLogUri = current.uri;
        _lastKeepFocusLogAt = now;
        unawaited(
          remoteMediaLogService.log(
            'focus',
            'keep current preview focus while actively scrolling',
            data: {
              'currentUri': current.uri,
              'nextTargetUri': target.uri,
              'speedPxPerSecond': _lastScrollSpeedPxPerSecond,
            },
          ),
        );
      }
      return;
    }
    if (isScrolling && current == null && target != null) {
      _pendingFocusTarget = target;
      _focusDebounceTimer?.cancel();
      _focusDebounceTimer = Timer(const Duration(milliseconds: 220), () {
        if (!mounted || widget.isScrollingNotifier.value) return;
        _applyFocusTarget(_pendingFocusTarget);
        _pendingFocusTarget = null;
      });
      return;
    }
    final initialFocusLocked =
        _initialFocusLockUntil != null &&
        now.isBefore(_initialFocusLockUntil!) &&
        current != null &&
        target != null &&
        current.uri == _initialFocusLockedUri &&
        target.uri != current.uri &&
        (scrollController.offset - (_initialFocusLockOffset ?? scrollController.offset)).abs() <= 24;
    if (initialFocusLocked) {
      return;
    }

    final rapidVideoRetarget = current?.isVideo == true && target?.isVideo == true && now.difference(_lastFocusChangeAt) < const Duration(milliseconds: 700);
    if (rapidVideoRetarget && _lastScrollSpeedPxPerSecond < 900) {
      return;
    }

    if (target == null && current != null && now.difference(_lastFocusChangeAt) < const Duration(milliseconds: 360)) {
      return;
    }

    if (target == null && isScrolling && current != null) {
      final currentUri = current.uri;
      final sameUri = _lastKeepFocusLogUri == currentUri;
      final withinCooldown = now.difference(_lastKeepFocusLogAt) < const Duration(seconds: 2);
      if (sameUri && withinCooldown) {
        return;
      }
      _lastKeepFocusLogUri = currentUri;
      _lastKeepFocusLogAt = now;
      unawaited(
        remoteMediaLogService.log(
          'focus',
          'keep current preview focus while scrolling without probe hit',
          data: {'uri': current.uri},
        ),
      );
      return;
    }

    // First target assignment should be immediate so the initial visible video can autoplay.
    if (current == null || target == null) {
      _applyFocusTarget(target);
      return;
    }

    _pendingFocusTarget = target;
    _focusDebounceTimer?.cancel();
    _focusDebounceTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _applyFocusTarget(_pendingFocusTarget);
      _pendingFocusTarget = null;
    });
  }

  void _applyFocusTarget(AvesEntry? target) {
    if (widget.previewPlayingEntryNotifier.value == target) return;
    widget.previewPlayingEntryNotifier.value = target;
    _lastFocusChangeAt = DateTime.now();
    unawaited(_prefetchRemoteWindow(target));
    unawaited(
      remoteMediaLogService.log(
        'focus',
        'collection preview focus changed',
        data: {
          'uri': target?.uri,
          'isVideo': target?.isVideo,
        },
      ),
    );
  }

  Future<void> _prefetchRemoteWindow(AvesEntry? anchor) async {
    if (anchor == null || !mounted) return;
    if (!settings.remotePreviewPreheatEnabled) return;
    final requestToken = ++_prefetchRequestToken;
    final now = DateTime.now();
    final fastScrollActive = widget.isScrollingNotifier.value && _lastScrollSpeedPxPerSecond >= 900;
    final fastScrollRecently = now.difference(_lastFastScrollAt).inMilliseconds < 650;
    if (fastScrollActive || fastScrollRecently) {
      _deferredPrefetchTimer?.cancel();
      _deferredPrefetchTimer = Timer(const Duration(milliseconds: 480), () {
        if (!mounted || widget.isScrollingNotifier.value) return;
        final target = widget.previewPlayingEntryNotifier.value ?? anchor;
        unawaited(_prefetchRemoteWindow(target));
      });
      unawaited(
        remoteMediaLogService.log(
          'lazy_load',
          'skip remote preview prefetch during fast scrolling and defer until settled',
          data: {
            'focusUri': anchor.uri,
            'speedPxPerSecond': _lastScrollSpeedPxPerSecond,
            'fastScrollRecently': fastScrollRecently,
          },
        ),
      );
      return;
    }
    _deferredPrefetchTimer?.cancel();
    final entries = collection.sortedEntries;
    if (entries.isEmpty) return;

    var focusIndex = entries.indexOf(anchor);
    if (focusIndex < 0) {
      // Fallback to the first available media entry to guarantee initial lazy-load on entry.
      focusIndex = 0;
    }

    final candidates = <AvesEntry>[];
    final imagePreheatCount = max(0, settings.remotePreviewImageCount);
    final upperBound = min(focusIndex + max(1, imagePreheatCount), entries.length);
    for (var i = focusIndex; i < upperBound; i++) {
      final entry = entries[i];
      if (!entry.isImage) continue;
      if (!remoteMediaService.hasVirtualRemoteRef(entry.uri)) continue;
      candidates.add(entry);
      if (candidates.length >= imagePreheatCount) break;
    }
    final signature = '$focusIndex:${_remotePrefetchIdentity(anchor)}:${candidates.map(_remotePrefetchIdentity).join('|')}';
    final duplicated = signature == _lastPrefetchSignature && now.difference(_lastPrefetchAt).inMilliseconds < _imagePrefetchDedupeWindowMillis(anchor);
    if (!duplicated && candidates.isNotEmpty) {
      _lastPrefetchSignature = signature;
      _lastPrefetchAt = now;

      await remoteMediaLogService.log(
        'lazy_load',
        'trigger remote image lazy download window',
        data: {
          'focusUri': anchor.uri,
          'focusIndex': focusIndex,
          'count': candidates.length,
          'concurrency': _imagePrefetchConcurrency(anchor),
          'uris': candidates.map((e) => e.uri).toList(),
        },
      );

      final concurrency = max(1, min(_imagePrefetchConcurrency(anchor), candidates.length));
      for (var start = 0; start < candidates.length; start += concurrency) {
        if (!_isActiveImagePrefetchRequest(requestToken)) return;
        final batch = candidates.skip(start).take(concurrency).toList();
        final results = await Future.wait(
          batch.map(
            (entry) => remoteMediaService.ensureDownloadedForEntry(
              entry,
              trigger: 'collection_focus_image_window',
            ),
          ),
          eagerError: false,
        );
        if (!_isActiveImagePrefetchRequest(requestToken)) return;
        if (results.any((file) => file != null)) {
          collection.source.onAspectRatioChanged();
        }
      }
    }

    final nextVideos = <AvesEntry>[];
    final nextVideoPreheatCount = max(0, settings.remotePreviewVideoCount);
    if (nextVideoPreheatCount <= 0) return;
    for (var i = focusIndex + 1; i < entries.length; i++) {
      final candidate = entries[i];
      if (!candidate.isVideo) continue;
      if (!remoteMediaService.hasVirtualRemoteRef(candidate.uri)) continue;
      nextVideos.add(candidate);
      if (nextVideos.length >= nextVideoPreheatCount) break;
    }
    if (nextVideos.isEmpty) return;
    if (!_isActivePrefetchRequest(anchor, requestToken)) return;
    final shouldDelayForCurrentLargePreview = remoteMediaService.shouldDelayPreviewVideoPreheatForEntry(anchor);
    if (shouldDelayForCurrentLargePreview) {
      final ready = await _waitForLargePreviewPlaybackStable(anchor, requestToken);
      if (!ready) return;
    }
    if (!_isActivePrefetchRequest(anchor, requestToken)) return;
    final videoSignature = '$focusIndex:${_remotePrefetchIdentity(anchor)}:${nextVideos.map(_remotePrefetchIdentity).join('|')}';
    if (_lastVideoPreheatSignature == videoSignature && now.difference(_lastVideoPreheatAt).inMilliseconds < _videoPreheatDedupeWindowMillis(anchor)) {
      return;
    }
    _lastVideoPreheatSignature = videoSignature;
    _lastVideoPreheatAt = now;
    for (final nextVideo in nextVideos) {
      await _preheatNextRemoteVideo(nextVideo, anchor);
    }
  }

  bool _isActivePrefetchRequest(AvesEntry anchor, int requestToken) {
    return mounted && _prefetchRequestToken == requestToken && widget.previewPlayingEntryNotifier.value?.uri == anchor.uri;
  }

  bool _isActiveImagePrefetchRequest(int requestToken) {
    return mounted && _prefetchRequestToken == requestToken;
  }

  bool _hasStablePreviewPlayback(AvesVideoController controller) {
    return controller.isReady && controller.isPlaying && _hasRenderablePreheatFrame(controller) && controller.currentPosition >= 120;
  }

  Future<bool> _waitForLargePreviewPlaybackStable(AvesEntry anchor, int requestToken) async {
    final thresholdBytes = remoteMediaService.previewVideoPreheatDelayThresholdBytesForEntry(anchor);
    final sizeBytes = remoteMediaService.getVirtualRemoteRef(anchor.uri)?.$2.sizeBytes ?? anchor.sizeBytes;
    await remoteMediaLogService.log(
      'stream',
      'delay next video preview preheat until large current preview becomes stable',
      data: {
        'focusUri': anchor.uri,
        'sizeBytes': sizeBytes,
        'thresholdBytes': thresholdBytes,
      },
    );

    final conductor = _videoConductor;
    final deadline = DateTime.now().add(const Duration(milliseconds: 3200));
    while (DateTime.now().isBefore(deadline)) {
      if (!_isActivePrefetchRequest(anchor, requestToken)) return false;

      final controller = conductor.getController(anchor);
      if (controller != null && _hasStablePreviewPlayback(controller)) {
        await Future.delayed(const Duration(milliseconds: 260));
        if (_isActivePrefetchRequest(anchor, requestToken) && _hasStablePreviewPlayback(controller)) {
          await remoteMediaLogService.log(
            'stream',
            'large current preview became stable, resume next video preview preheat',
            data: {
              'focusUri': anchor.uri,
              'sizeBytes': sizeBytes,
              'positionMillis': controller.currentPosition,
            },
          );
          return true;
        }
      }

      await Future.delayed(const Duration(milliseconds: 120));
    }

    await remoteMediaLogService.log(
      'stream',
      'large current preview did not stabilize before next video preheat window timed out',
      data: {
        'focusUri': anchor.uri,
        'sizeBytes': sizeBytes,
      },
    );
    _deferredPrefetchTimer?.cancel();
    _deferredPrefetchTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || widget.isScrollingNotifier.value) return;
      final current = widget.previewPlayingEntryNotifier.value;
      if (current?.uri != anchor.uri) return;
      unawaited(_prefetchRemoteWindow(anchor));
    });
    return false;
  }

  Future<void> _preheatNextRemoteVideo(AvesEntry entry, AvesEntry focusAnchor) async {
    try {
      final remoteProtocol = remoteMediaService.getRemoteProtocolForEntry(entry);
      await remoteMediaService.prepareInitialStreamPlaybackForEntry(
        entry,
        trigger: 'collection_focus_next_video_warmup',
      );
      var existingFile = await remoteMediaService.prepareEntryForPlayback(
        entry,
        trigger: 'collection_focus_next_video_preheat',
        allowDownload: false,
      );
      await remoteMediaService.ensureEntryMetadata(entry, trigger: 'collection_focus_next_video_preheat');

      if (remoteProtocol == RemoteProtocol.webdav && existingFile != null) {
        await remoteMediaLogService.log(
          'stream',
          'prepared next webdav video preview preheat using existing cache file',
          data: {
            'focusUri': focusAnchor.uri,
            'uri': entry.uri,
            'file': existingFile.path,
            'width': entry.width > 1 ? entry.width : null,
            'height': entry.height > 1 ? entry.height : null,
          },
        );
        return;
      }

      final controller = await _videoConductor.getOrCreateController(entry, maxControllerCount: 5);
      Future<void> waitForPreheatFrame(AvesVideoController controller, Duration timeout) async {
        if (_hasRenderablePreheatFrame(controller)) return;
        final completer = Completer<void>();
        late VoidCallback sizeListener;
        late VoidCallback frameListener;
        StreamSubscription<int>? positionSub;
        void completeIfReady() {
          if (completer.isCompleted || !_hasRenderablePreheatFrame(controller)) return;
          completer.complete();
        }

        sizeListener = completeIfReady;
        frameListener = completeIfReady;
        controller.decodedVideoSizeNotifier.addListener(sizeListener);
        controller.firstFrameRenderedNotifier.addListener(frameListener);
        positionSub = controller.positionStream.listen((position) {
          if (position > 0 && !completer.isCompleted) {
            completer.complete();
          }
        });
        try {
          await completer.future.timeout(timeout);
        } catch (_) {
          // best-effort preheat
        } finally {
          controller.decodedVideoSizeNotifier.removeListener(sizeListener);
          controller.firstFrameRenderedNotifier.removeListener(frameListener);
          await positionSub.cancel();
        }
      }

      Future<AvesVideoController> primeController(AvesVideoController controller, {required bool isRemoteNoCache}) async {
        try {
          await controller.untilReady.timeout(const Duration(milliseconds: 700));
        } catch (_) {}

        final decoded = controller.decodedVideoSizeNotifier.value;
        final hasDecodedFrame = decoded != null && decoded.width > 1 && decoded.height > 1;
        final shouldPrimeByMutedPlayback = !hasDecodedFrame && (entry.uri.startsWith('file://') || existingFile == null);
        if (!shouldPrimeByMutedPlayback) {
          return controller;
        }

        await controller.mute(true);
        try {
          await controller.play();
          await waitForPreheatFrame(controller, isRemoteNoCache ? const Duration(milliseconds: 2200) : const Duration(milliseconds: 600));
        } catch (_) {}
        await controller.pause();
        if (remoteProtocol != RemoteProtocol.ftp) {
          try {
            await controller.seekTo(0);
          } catch (_) {}
        }
        try {
          await controller.untilReady.timeout(const Duration(milliseconds: 450));
        } catch (_) {}
        return controller;
      }

      var activeController = await primeController(controller, isRemoteNoCache: existingFile == null);
      if (existingFile == null && !_hasRenderablePreheatFrame(activeController)) {
        await remoteMediaService.prepareInitialStreamPlaybackForEntry(
          entry,
          trigger: 'collection_focus_next_video_warmup_retry',
        );
        existingFile = await remoteMediaService.prepareEntryForPlayback(
          entry,
          trigger: 'collection_focus_next_video_preheat_retry',
          allowDownload: false,
        );
        activeController = await context.read<VideoConductor>().recreateController(entry);
        activeController = await primeController(activeController, isRemoteNoCache: existingFile == null);
      }

      final refreshedSize = activeController.decodedVideoSizeNotifier.value;
      if (refreshedSize != null && refreshedSize.width > 1 && refreshedSize.height > 1) {
        entry.width = refreshedSize.width.round();
        entry.height = refreshedSize.height.round();
        entry.visualChangeNotifier.notify();
        collection.source.onAspectRatioChanged();
      }

      await remoteMediaLogService.log(
        'stream',
        'prepared next remote video preview preheat',
        data: {
          'focusUri': focusAnchor.uri,
          'uri': entry.uri,
          'usedCachedFile': existingFile != null || entry.uri.startsWith('file://'),
          'hasDecodedFrame': refreshedSize != null && refreshedSize.width > 1 && refreshedSize.height > 1,
          'width': refreshedSize?.width.round(),
          'height': refreshedSize?.height.round(),
        },
      );
    } catch (error) {
      await remoteMediaLogService.log(
        'stream',
        'failed next remote video preview preheat',
        data: {
          'focusUri': focusAnchor.uri,
          'uri': entry.uri,
          'error': '$error',
        },
      );
    }
  }

  bool _hasRenderablePreheatFrame(AvesVideoController controller) {
    final size = controller.decodedVideoSizeNotifier.value;
    return controller.firstFrameRenderedNotifier.value || (size != null && size.width > 1 && size.height > 1) || controller.currentPosition > 0;
  }
}

class _CollectionScaler extends StatelessWidget {
  final GlobalKey scrollableKey;
  final ValueNotifier<double> appBarHeightNotifier;
  final TileLayout tileLayout;
  final Widget child;

  const _CollectionScaler({
    required this.scrollableKey,
    required this.appBarHeightNotifier,
    required this.tileLayout,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final (tileSpacing, horizontalPadding) = context.select<TileExtentController, (double, double)>((v) => (v.spacing, v.horizontalPadding));
    final brightness = Theme.of(context).brightness;
    final borderColor = DecoratedThumbnail.borderColor(context);
    final borderWidth = DecoratedThumbnail.borderWidth(context);
    return GridScaleGestureDetector<AvesEntry>(
      scrollableKey: scrollableKey,
      tileLayout: tileLayout,
      heightForWidth: (width) => width,
      gridBuilder: (center, tileSize, child) => CustomPaint(
        painter: FixedExtentGridPainter(
          tileLayout: tileLayout,
          tileCenter: center,
          tileSize: tileSize,
          spacing: tileSpacing,
          horizontalPadding: horizontalPadding,
          borderWidth: borderWidth,
          borderRadius: Radius.zero,
          color: borderColor,
          textDirection: Directionality.of(context),
        ),
        child: child,
      ),
      scaledItemBuilder: (entry, tileSize) => EntryListDetailsTheme(
        extent: tileSize.height,
        child: Tile(
          entry: entry,
          thumbnailExtent: context.read<TileExtentController>().effectiveExtentMax,
          tileLayout: tileLayout,
        ),
      ),
      mosaicItemBuilder: (index, targetExtent) => DecoratedBox(
        decoration: BoxDecoration(
          color: ThumbnailImage.computeLoadingBackgroundColor(index * 10, brightness).withValues(alpha: .9),
          border: Border.all(
            color: borderColor,
            width: borderWidth,
          ),
        ),
      ),
      child: child,
    );
  }
}

class _CollectionScrollView extends StatefulWidget {
  final GlobalKey scrollableKey;
  final CollectionLens collection;
  final Widget appBar;
  final ValueNotifier<double> appBarHeightNotifier;
  final ValueNotifier<bool> isScrollingNotifier;
  final ScrollController scrollController;
  final ValueChanged<ScrollDirection> onScrollIntent;

  const _CollectionScrollView({
    required this.scrollableKey,
    required this.collection,
    required this.appBar,
    required this.appBarHeightNotifier,
    required this.isScrollingNotifier,
    required this.scrollController,
    required this.onScrollIntent,
  });

  @override
  State<_CollectionScrollView> createState() => _CollectionScrollViewState();
}

class _CollectionScrollViewState extends State<_CollectionScrollView> with WidgetsBindingObserver {
  Timer? _scrollMonitoringTimer;
  bool _checkingStoragePermission = false;

  @override
  void initState() {
    super.initState();
    _registerWidget(widget);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant _CollectionScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unregisterWidget(oldWidget);
    _registerWidget(widget);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unregisterWidget(widget);
    _stopScrollMonitoringTimer();
    super.dispose();
  }

  void _registerWidget(_CollectionScrollView widget) {
    widget.collection.filterChangeNotifier.addListener(_scrollToTop);
    widget.collection.sortSectionChangeNotifier.addListener(_scrollToTop);
    widget.scrollController.addListener(_onScrollChanged);
  }

  void _unregisterWidget(_CollectionScrollView widget) {
    widget.collection.filterChangeNotifier.removeListener(_scrollToTop);
    widget.collection.sortSectionChangeNotifier.removeListener(_scrollToTop);
    widget.scrollController.removeListener(_onScrollChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _checkingStoragePermission) {
      _checkingStoragePermission = false;
      _isStoragePermissionGranted.then((granted) {
        if (granted) {
          widget.collection.source.init(scope: CollectionSource.fullScope);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scrollView = _buildScrollView(widget.appBar, widget.collection);
    return settings.useTvLayout ? scrollView : _buildDraggableScrollView(scrollView, widget.collection);
  }

  Widget _buildDraggableScrollView(Widget scrollView, CollectionLens collection) {
    return ValueListenableBuilder<double>(
      valueListenable: widget.appBarHeightNotifier,
      builder: (context, appBarHeight, child) {
        return Selector<MediaQueryData, double>(
          selector: (context, mq) => mq.effectiveBottomPadding,
          builder: (context, mqPaddingBottom, child) {
            return Selector<Settings, bool>(
              selector: (context, s) => s.enableBottomNavigationBar,
              builder: (context, enableBottomNavigationBar, child) {
                final canNavigate = context.select<ValueNotifier<AppMode>, bool>((v) => v.value.canNavigate);
                final showBottomNavigationBar = canNavigate && enableBottomNavigationBar;
                final navBarHeight = showBottomNavigationBar ? AppBottomNavBar.height : 0;
                return Selector<SectionedListLayout<AvesEntry>, List<SectionLayout>>(
                  selector: (context, layout) => layout.sectionLayouts,
                  builder: (context, sectionLayouts, child) {
                    final scrollController = widget.scrollController;
                    final offsetIncrementSnapThreshold = context.select<TileExtentController, double>((v) => (v.extentNotifier.value + v.spacing) / 4);
                    return DraggableScrollbar(
                      backgroundColor: Colors.white,
                      scrollThumbSize: Size(avesScrollThumbWidth, avesScrollThumbHeight),
                      scrollThumbBuilder: avesScrollThumbBuilder(
                        height: avesScrollThumbHeight,
                        backgroundColor: Colors.white,
                      ),
                      controller: scrollController,
                      dragOffsetSnapper: (scrollOffset, offsetIncrement) {
                        if (offsetIncrement > offsetIncrementSnapThreshold && scrollOffset < scrollController.position.maxScrollExtent) {
                          final section = sectionLayouts.firstWhereOrNull((section) => section.hasChildAtOffset(scrollOffset));
                          if (section != null) {
                            if (section.maxOffset - section.minOffset < scrollController.position.viewportDimension) {
                              // snap to section header
                              return section.minOffset;
                            } else {
                              // snap to content row
                              final index = section.getMinChildIndexForScrollOffset(scrollOffset);
                              return section.indexToLayoutOffset(index);
                            }
                          }
                        }
                        return scrollOffset;
                      },
                      crumbsBuilder: () => _getCrumbs(sectionLayouts),
                      padding: EdgeInsets.only(
                        // padding to keep scroll thumb between app bar above and nav bar below
                        top: appBarHeight,
                        bottom: navBarHeight + mqPaddingBottom,
                      ),
                      labelTextBuilder: (offsetY) => CollectionDraggableThumbLabel(
                        collection: collection,
                        offsetY: offsetY,
                      ),
                      crumbTextBuilder: (label) => DraggableCrumbLabel(label: label),
                      child: scrollView,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildScrollView(Widget appBar, CollectionLens collection) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is UserScrollNotification) {
          widget.onScrollIntent(notification.direction);
        } else if (notification is OverscrollNotification) {
          widget.onScrollIntent(notification.overscroll > 0 ? ScrollDirection.reverse : ScrollDirection.forward);
        }
        return false;
      },
      child: CustomScrollView(
        key: widget.scrollableKey,
        primary: true,
        // workaround to prevent scrolling the app bar away
        // when there is no content and we use `SliverFillRemaining`
        physics: collection.isEmpty
            ? const NeverScrollableScrollPhysics()
            : SloppyScrollPhysics(
                gestureSettings: MediaQuery.gestureSettingsOf(context),
                parent: const AlwaysScrollableScrollPhysics(),
              ),
        cacheExtent: context.select<TileExtentController, double>((controller) => controller.effectiveExtentMax),
        slivers: [
          appBar,
          collection.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyContent(collection),
                )
              : const SectionedListSliver<AvesEntry>(),
          const NavBarPaddingSliver(),
          const BottomPaddingSliver(),
          const TvTileGridBottomPaddingSliver(),
        ],
      ),
    );
  }

  Widget _buildEmptyContent(CollectionLens collection) {
    final source = collection.source;
    return ValueListenableBuilder<SourceState>(
      valueListenable: source.stateNotifier,
      builder: (context, sourceState, child) {
        if (sourceState == SourceState.loading) {
          return LoadingEmptyContent(source: source);
        }

        return FutureBuilder<bool>(
          future: _isStoragePermissionGranted,
          builder: (context, snapshot) {
            final granted = snapshot.data ?? true;
            Widget? bottom = granted
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: AvesOutlinedButton(
                      label: context.l10n.collectionEmptyGrantAccessButtonLabel,
                      onPressed: () async {
                        if (await openAppSettings()) {
                          _checkingStoragePermission = true;
                        }
                      },
                    ),
                  );

            if (collection.filters.any((filter) => filter is FavouriteFilter)) {
              return EmptyContent(
                icon: AIcons.favourite,
                text: context.l10n.collectionEmptyFavourites,
                bottom: bottom,
              );
            }
            if (collection.filters.any((filter) => filter is MimeFilter && filter.mime == MimeTypes.anyVideo)) {
              return EmptyContent(
                icon: AIcons.video,
                text: context.l10n.collectionEmptyVideos,
                bottom: bottom,
              );
            }
            return EmptyContent(
              icon: AIcons.image,
              text: context.l10n.collectionEmptyImages,
              bottom: bottom,
            );
          },
        );
      },
    );
  }

  void _scrollToTop() => widget.scrollController.jumpTo(0);

  void _onScrollChanged() {
    widget.isScrollingNotifier.value = true;
    _stopScrollMonitoringTimer();
    _scrollMonitoringTimer = Timer(ADurations.collectionScrollMonitoringTimerDelay, () {
      widget.isScrollingNotifier.value = false;
    });
  }

  void _stopScrollMonitoringTimer() => _scrollMonitoringTimer?.cancel();

  Map<double, String> _getCrumbs(List<SectionLayout> sectionLayouts) {
    final crumbs = <double, String>{};
    if (sectionLayouts.length <= 1) return crumbs;

    final maxOffset = sectionLayouts.last.maxOffset;
    void addAlbums(CollectionLens collection, List<SectionLayout> sectionLayouts, Map<double, String> crumbs) {
      final source = collection.source;
      sectionLayouts.forEach((section) {
        final directory = (section.sectionKey as EntryAlbumSectionKey).directory;
        if (directory != null) {
          final label = source.getStoredAlbumDisplayName(context, directory);
          crumbs[section.minOffset / maxOffset] = label;
        }
      });
    }

    final collection = widget.collection;
    switch (collection.sortFactor) {
      case .date:
        switch (collection.sectionFactor) {
          case .album:
            addAlbums(collection, sectionLayouts, crumbs);
          case .month:
          case .day:
            final firstKey = sectionLayouts.first.sectionKey;
            final lastKey = sectionLayouts.last.sectionKey;
            if (firstKey is EntryDateSectionKey && lastKey is EntryDateSectionKey) {
              final newest = firstKey.date;
              final oldest = lastKey.date;
              if (newest != null && oldest != null) {
                final locale = context.locale;
                final dateFormat = (newest.difference(oldest).inHumanDays).abs() > 365 ? DateFormat.y(locale) : DateFormat.MMM(locale);
                String? lastLabel;
                sectionLayouts.forEach((section) {
                  final date = (section.sectionKey as EntryDateSectionKey).date;
                  if (date != null) {
                    final label = dateFormat.format(date);
                    if (label != lastLabel) {
                      crumbs[section.minOffset / maxOffset] = label;
                      lastLabel = label;
                    }
                  }
                });
              }
            }
          case .none:
            break;
        }
      case .name:
      case .path:
        addAlbums(collection, sectionLayouts, crumbs);
      case .rating:
      case .size:
      case .duration:
        break;
    }
    return crumbs;
  }

  Future<bool> get _isStoragePermissionGranted => Future.wait(Permissions.storage.map((v) => v.status)).then((v) => v.any((status) => status.isGranted));
}
