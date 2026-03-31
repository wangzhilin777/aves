import 'package:aves/model/filters/container/album_group.dart';
import 'package:aves/model/filters/filters.dart';
import 'package:aves/theme/icons.dart';
import 'package:flutter/widgets.dart';

class RemoteAlbumFilter extends CollectionFilter with AlbumBaseFilter {
  static const type = 'remote_album';

  final String serverId;
  final String path;
  final String title;

  @override
  List<Object?> get props => [serverId, path, title, reversed];

  const RemoteAlbumFilter({
    required this.serverId,
    required this.path,
    required this.title,
    super.reversed = false,
  });

  factory RemoteAlbumFilter.fromMap(Map<String, Object?> json) {
    return RemoteAlbumFilter(
      serverId: json['serverId'] as String,
      path: json['path'] as String,
      title: json['title'] as String,
      reversed: json['reversed'] as bool? ?? false,
    );
  }

  @override
  Map<String, Object?> toMap() => {
    'type': type,
    'serverId': serverId,
    'path': path,
    'title': title,
    'reversed': reversed,
  };

  @override
  EntryPredicate get positiveTest => (_) => false;

  @override
  bool get exclusiveProp => true;

  @override
  String get universalLabel => title;

  @override
  Widget? iconBuilder(BuildContext context, double size, {bool allowGenericIcon = true}) => Icon(AIcons.storageMain, size: size);

  @override
  String get category => type;

  @override
  String get key => '$type-$serverId-$path-$reversed';
}
