import 'dart:convert';
import 'dart:io';

import 'package:aves/model/settings/settings.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

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

  Future<bool> exportAndShareTxt({String subject = 'Aves Remote Logs'}) async {
    final file = await _exportTxtToCacheFile();
    if (file != null) {
      final sharedFile = await appService.shareSingle(Uri.file(file.path).toString(), MimeTypes.plainText);
      if (sharedFile) return true;
    }
    final text = entries.join('\n');
    if (text.isEmpty) return false;
    return appService.shareText(text, subject: subject);
  }

  Future<File?> _exportTxtToCacheFile() async {
    try {
      final root = await storageService.getExternalCacheDirectory();
      final basePath = root.isNotEmpty ? root : Directory.systemTemp.path;
      final dir = Directory('$basePath${Platform.pathSeparator}remote${Platform.pathSeparator}logs');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _cleanupOldExportFiles(dir);
      final file = File(
        '${dir.path}${Platform.pathSeparator}aves-remote-logs-${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}${MimeTypes.extensionFor(MimeTypes.plainText) ?? '.txt'}',
      );
      await file.writeAsString(entries.join('\n'));
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupOldExportFiles(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && p.basename(entity.path).startsWith('aves-remote-logs-') && entity.path.toLowerCase().endsWith('.txt')) {
        files.add(entity);
      }
    }
    if (files.length <= _maxRetainedExportFiles) return;
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final file in files.skip(_maxRetainedExportFiles)) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static const int _maxRetainedExportFiles = 20;
}
