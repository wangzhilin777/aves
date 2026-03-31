enum RemoteProtocol {
  webdav,
  ftp,
  sftp,
  smb,
}

extension RemoteProtocolX on RemoteProtocol {
  String get id => name;

  static RemoteProtocol? fromId(String? id) {
    if (id == null) return null;
    for (final v in RemoteProtocol.values) {
      if (v.id == id) return v;
    }
    return null;
  }
}
