import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/font_size_icon_theme.dart';
import 'package:aves/widgets/common/basic/popup/menu_row.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class RemoteLogsPage extends StatefulWidget {
  static const routeName = '/settings/remote/logs';

  const RemoteLogsPage({super.key});

  @override
  State<RemoteLogsPage> createState() => _RemoteLogsPageState();
}

class _RemoteLogsPageState extends State<RemoteLogsPage> with FeedbackMixin {
  @override
  Widget build(BuildContext context) {
    return AvesScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !settings.useTvLayout,
        title: const Text('Remote Logs'),
        actions: [
          PopupMenuButton<_LogAction>(
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _LogAction.copy,
                child: MenuRow(
                  text: 'Copy logs',
                  icon: Icon(AIcons.clipboard),
                ),
              ),
              PopupMenuItem(
                value: _LogAction.export,
                child: MenuRow(
                  text: 'Export TXT',
                  icon: Icon(AIcons.fileExport),
                ),
              ),
              const PopupMenuItem(
                value: _LogAction.exportAndShare,
                child: MenuRow(
                  text: 'Export & Share',
                  icon: Icon(AIcons.share),
                ),
              ),
              const PopupMenuItem(
                value: _LogAction.clear,
                child: MenuRow(
                  text: 'Clear logs',
                  icon: Icon(AIcons.clear),
                ),
              ),
            ],
            onSelected: _onActionSelected,
          ),
        ].map((v) => FontSizeIconTheme(child: v)).toList(),
      ),
      body: SafeArea(
        child: Selector<Settings, List<String>>(
          selector: (context, s) => s.remoteLogEntries,
          builder: (context, entries, child) {
            if (entries.isEmpty) {
              return const EmptyContent(
                icon: AIcons.description,
                text: 'No remote logs yet',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              separatorBuilder: (context, index) => const Divider(height: 12),
              itemBuilder: (context, index) {
                return SelectableText(entries[index]);
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _onActionSelected(_LogAction action) async {
    final l10n = context.l10n;
    switch (action) {
      case _LogAction.copy:
        await remoteMediaLogService.copyToClipboard();
        if (mounted) showFeedback(context, FeedbackType.info, l10n.genericSuccessFeedback);
      case _LogAction.export:
        final success = await remoteMediaLogService.exportTxt();
        if (mounted) {
          showFeedback(context, success == true ? FeedbackType.info : FeedbackType.warn, success == true ? l10n.genericSuccessFeedback : l10n.genericFailureFeedback);
        }
      case _LogAction.exportAndShare:
        final text = settings.remoteLogEntries.join('\n');
        final exported = await remoteMediaLogService.exportTxt();
        final shared = text.isNotEmpty && await appService.shareText(text, subject: 'Aves Remote Logs');
        if (mounted) {
          showFeedback(context, (exported == true || shared) ? FeedbackType.info : FeedbackType.warn, (exported == true || shared) ? l10n.genericSuccessFeedback : l10n.genericFailureFeedback);
        }
      case _LogAction.clear:
        await remoteMediaLogService.clear();
        if (mounted) showFeedback(context, FeedbackType.info, l10n.genericSuccessFeedback);
    }
  }
}

enum _LogAction { copy, export, exportAndShare, clear }
