import 'dart:convert';

import 'package:aves/model/remote/remote_protocol.dart';
import 'package:collection/collection.dart';

class RemoteServer {
  final String id;
  final String name;
  final RemoteProtocol protocol;

  // WebDAV uses URL as source-of-truth and can already include a port.
  final String? webdavUrl;

  // Non-WebDAV protocols.
  final String? host;
  final int? port;
  final String? basePath;
  final String? username;
  final String? password;

  // FTP extras.
  final bool ftpAnonymous;
  final bool ftpPassiveMode;

  // SMB extras.
  final String? smbDomain;

  // SFTP extras.
  final String? sftpPrivateKey;
  final String? sftpPassphrase;
  final String? sftpAdvancedJson;

  const RemoteServer({
    required this.id,
    required this.name,
    required this.protocol,
    this.webdavUrl,
    this.host,
    this.port,
    this.basePath,
    this.username,
    this.password,
    this.ftpAnonymous = false,
    this.ftpPassiveMode = true,
    this.smbDomain,
    this.sftpPrivateKey,
    this.sftpPassphrase,
    this.sftpAdvancedJson,
  });

  RemoteServer copyWith({
    String? id,
    String? name,
    RemoteProtocol? protocol,
    String? webdavUrl,
    String? host,
    int? port,
    String? basePath,
    String? username,
    String? password,
    bool? ftpAnonymous,
    bool? ftpPassiveMode,
    String? smbDomain,
    String? sftpPrivateKey,
    String? sftpPassphrase,
    String? sftpAdvancedJson,
  }) {
    return RemoteServer(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      host: host ?? this.host,
      port: port ?? this.port,
      basePath: basePath ?? this.basePath,
      username: username ?? this.username,
      password: password ?? this.password,
      ftpAnonymous: ftpAnonymous ?? this.ftpAnonymous,
      ftpPassiveMode: ftpPassiveMode ?? this.ftpPassiveMode,
      smbDomain: smbDomain ?? this.smbDomain,
      sftpPrivateKey: sftpPrivateKey ?? this.sftpPrivateKey,
      sftpPassphrase: sftpPassphrase ?? this.sftpPassphrase,
      sftpAdvancedJson: sftpAdvancedJson ?? this.sftpAdvancedJson,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'protocol': protocol.id,
    'webdavUrl': webdavUrl,
    'host': host,
    'port': port,
    'basePath': basePath,
    'username': username,
    'password': password,
    'ftpAnonymous': ftpAnonymous,
    'ftpPassiveMode': ftpPassiveMode,
    'smbDomain': smbDomain,
    'sftpPrivateKey': sftpPrivateKey,
    'sftpPassphrase': sftpPassphrase,
    'sftpAdvancedJson': sftpAdvancedJson,
  };

  String toJson() => jsonEncode(toMap());

  static RemoteServer? fromJson(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final map = jsonDecode(value);
      if (map is! Map<String, Object?>) return null;
      final protocol = RemoteProtocolX.fromId(map['protocol'] as String?);
      if (protocol == null) return null;
      return RemoteServer(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        protocol: protocol,
        webdavUrl: map['webdavUrl'] as String?,
        host: map['host'] as String?,
        port: map['port'] as int?,
        basePath: map['basePath'] as String?,
        username: map['username'] as String?,
        password: map['password'] as String?,
        ftpAnonymous: map['ftpAnonymous'] as bool? ?? false,
        ftpPassiveMode: map['ftpPassiveMode'] as bool? ?? true,
        smbDomain: map['smbDomain'] as String?,
        sftpPrivateKey: map['sftpPrivateKey'] as String?,
        sftpPassphrase: map['sftpPassphrase'] as String?,
        sftpAdvancedJson: map['sftpAdvancedJson'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class RemotePinnedFolder {
  final String serverId;
  final String path;
  final String title;

  const RemotePinnedFolder({
    required this.serverId,
    required this.path,
    required this.title,
  });

  Map<String, Object?> toMap() => {
    'serverId': serverId,
    'path': path,
    'title': title,
  };

  String toJson() => jsonEncode(toMap());

  static RemotePinnedFolder? fromJson(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final map = jsonDecode(value);
      if (map is! Map<String, Object?>) return null;
      return RemotePinnedFolder(
        serverId: map['serverId'] as String? ?? '',
        path: map['path'] as String? ?? '',
        title: map['title'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

extension RemoteServerListX on List<RemoteServer> {
  RemoteServer? byId(String id) => firstWhereOrNull((v) => v.id == id);
}
