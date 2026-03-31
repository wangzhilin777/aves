import 'dart:convert';

import 'package:aves/model/settings/settings.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class RemoteMediaLogService {
  static const int _maxLogEntries = 1200;

  List<String> get entries => List.unmodifiable(settings.remoteLogEntries);

  Future<void> log(
    String topic,
    String message, {
    Map<String, Object?>? data,
    bool force = false,
  }) async {
    if (!force && !settings.remoteLogEnabled) return;

    final ts = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
    final dataText = data == null || data.isEmpty ? '' : ' ${jsonEncode(data)}';
    final next = '$ts [$topic] $message$dataText';
    final current = settings.remoteLogEntries;
    settings.remoteLogEntries = [
      ...current.skip((current.length + 1 - _maxLogEntries).clamp(0, current.length)),
      next,
    ];
  }

  Future<void> clear() async {
    settings.remoteLogEntries = [];
  }

  Future<void> copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: entries.join('\n')));
  }

  Future<bool?> exportTxt() {
    final fileName = 'aves-remote-logs-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}${MimeTypes.extensionFor(MimeTypes.plainText) ?? '.txt'}';
    final bytes = Uint8List.fromList(utf8.encode(entries.join('\n')));
    return storageService.createFile(fileName, MimeTypes.plainText, bytes);
  }
}
