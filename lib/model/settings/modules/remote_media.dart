import 'package:aves/model/remote/remote_server.dart';
import 'package:aves/model/settings/defaults.dart';
import 'package:aves/model/settings/enums/remote_stream_mode.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';

mixin RemoteMediaSettings on SettingsAccess {
  bool get remoteLogEnabled => getBool(SettingKeys.remoteLogEnabledKey) ?? SettingsDefaults.remoteLogEnabled;

  set remoteLogEnabled(bool newValue) => set(SettingKeys.remoteLogEnabledKey, newValue);

  bool get remoteWifiOnlyDownload => getBool(SettingKeys.remoteWifiOnlyDownloadKey) ?? SettingsDefaults.remoteWifiOnlyDownload;

  set remoteWifiOnlyDownload(bool newValue) => set(SettingKeys.remoteWifiOnlyDownloadKey, newValue);

  List<RemoteServer> get remoteServers => (getStringList(SettingKeys.remoteServersKey) ?? []).map(RemoteServer.fromJson).nonNulls.toList();

  set remoteServers(List<RemoteServer> value) => set(SettingKeys.remoteServersKey, value.map((v) => v.toJson()).toList());

  List<RemotePinnedFolder> get remotePinnedFolders => (getStringList(SettingKeys.remotePinnedFoldersKey) ?? []).map(RemotePinnedFolder.fromJson).nonNulls.toList();

  set remotePinnedFolders(List<RemotePinnedFolder> value) => set(SettingKeys.remotePinnedFoldersKey, value.map((v) => v.toJson()).toList());

  bool get remotePinAtTop => getBool(SettingKeys.remotePinAtTopKey) ?? SettingsDefaults.remotePinAtTop;

  set remotePinAtTop(bool newValue) => set(SettingKeys.remotePinAtTopKey, newValue);

  bool get remoteCacheInSmartCollections => getBool(SettingKeys.remoteCacheInSmartCollectionsKey) ?? SettingsDefaults.remoteCacheInSmartCollections;

  set remoteCacheInSmartCollections(bool newValue) => set(SettingKeys.remoteCacheInSmartCollectionsKey, newValue);

  bool get remoteStandaloneFavouriteMode => getBool(SettingKeys.remoteStandaloneFavouriteModeKey) ?? SettingsDefaults.remoteStandaloneFavouriteMode;

  set remoteStandaloneFavouriteMode(bool newValue) => set(SettingKeys.remoteStandaloneFavouriteModeKey, newValue);

  Set<String> get remoteStandaloneFavouritePaths => (getStringList(SettingKeys.remoteStandaloneFavouritePathsKey) ?? const []).toSet();

  set remoteStandaloneFavouritePaths(Set<String> newValue) => set(SettingKeys.remoteStandaloneFavouritePathsKey, newValue.toList());

  List<String> get remoteStandaloneFavouriteEntries => getStringList(SettingKeys.remoteStandaloneFavouriteEntriesKey) ?? const [];

  set remoteStandaloneFavouriteEntries(List<String> newValue) => set(SettingKeys.remoteStandaloneFavouriteEntriesKey, newValue);

  bool get remoteGridVideoAutoPlay => getBool(SettingKeys.remoteGridVideoAutoPlayKey) ?? SettingsDefaults.remoteGridVideoAutoPlay;

  set remoteGridVideoAutoPlay(bool newValue) => set(SettingKeys.remoteGridVideoAutoPlayKey, newValue);

  bool get remoteGridVideoSoundOn => getBool(SettingKeys.remoteGridVideoSoundOnKey) ?? SettingsDefaults.remoteGridVideoSoundOn;

  set remoteGridVideoSoundOn(bool newValue) => set(SettingKeys.remoteGridVideoSoundOnKey, newValue);

  bool get remotePreviewPreheatEnabled => getBool(SettingKeys.remotePreviewPreheatEnabledKey) ?? SettingsDefaults.remotePreviewPreheatEnabled;

  set remotePreviewPreheatEnabled(bool newValue) => set(SettingKeys.remotePreviewPreheatEnabledKey, newValue);

  bool get remoteViewerPreheatEnabled => getBool(SettingKeys.remoteViewerPreheatEnabledKey) ?? SettingsDefaults.remoteViewerPreheatEnabled;

  set remoteViewerPreheatEnabled(bool newValue) => set(SettingKeys.remoteViewerPreheatEnabledKey, newValue);

  int get remotePreviewImageCount => getInt(SettingKeys.remotePreviewImageCountKey) ?? SettingsDefaults.remotePreviewImageCount;

  set remotePreviewImageCount(int newValue) => set(SettingKeys.remotePreviewImageCountKey, newValue);

  int get remotePreviewVideoCount => getInt(SettingKeys.remotePreviewVideoCountKey) ?? SettingsDefaults.remotePreviewVideoCount;

  set remotePreviewVideoCount(int newValue) => set(SettingKeys.remotePreviewVideoCountKey, newValue);

  int get remoteAutoDownloadImageMaxBytes => getInt(SettingKeys.remoteAutoDownloadImageMaxBytesKey) ?? SettingsDefaults.remoteAutoDownloadImageMaxBytes;

  set remoteAutoDownloadImageMaxBytes(int newValue) => set(SettingKeys.remoteAutoDownloadImageMaxBytesKey, newValue);

  int get remoteAutoDownloadVideoMaxBytes => getInt(SettingKeys.remoteAutoDownloadVideoMaxBytesKey) ?? SettingsDefaults.remoteAutoDownloadVideoMaxBytes;

  set remoteAutoDownloadVideoMaxBytes(int newValue) => set(SettingKeys.remoteAutoDownloadVideoMaxBytesKey, newValue);

  int get remoteCacheMaxBytes => getInt(SettingKeys.remoteCacheMaxBytesKey) ?? SettingsDefaults.remoteCacheMaxBytes;

  set remoteCacheMaxBytes(int newValue) => set(SettingKeys.remoteCacheMaxBytesKey, newValue);

  RemoteStreamMode get remoteStreamMode {
    final modeName = getString(SettingKeys.remoteStreamModeKey);
    return RemoteStreamMode.values.firstWhereOrNull((v) => v.name == modeName) ?? SettingsDefaults.remoteStreamMode;
  }

  set remoteStreamMode(RemoteStreamMode newValue) => set(SettingKeys.remoteStreamModeKey, newValue.name);

  List<String> get remoteLogEntries => getStringList(SettingKeys.remoteLogEntriesKey) ?? const [];

  set remoteLogEntries(List<String> newValue) => set(SettingKeys.remoteLogEntriesKey, newValue);
}
