import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';

extension ExtraAvesEntryFav on AvesEntry {
  bool get isFavourite => favourites.isFavourite(this) || (!settings.remoteCacheInSmartCollections && remoteMediaService.isStandaloneFavouriteEntry(this, settings.remoteStandaloneFavouritePaths));

  Future<void> toggleFavourite() async {
    if (isFavourite) {
      await removeFromFavourites();
    } else {
      await addToFavourites();
    }
  }

  Future<void> addToFavourites() async {
    if (!isFavourite) {
      await favourites.add({this});
    }
  }

  Future<void> removeFromFavourites() async {
    if (isFavourite) {
      await favourites.removeEntries({this});
    }
  }
}
