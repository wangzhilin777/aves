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
  String _tr(BuildContext context, String en, String zh) => context.locale.startsWith('zh') ? zh : en;

  @override
  Widget build(BuildContext context) {
    final title = _tr(context, 'Remote Logs', '杩滅▼鏃ュ織');
    return AvesScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !settings.useTvLayout,
        title: Text(title),
        actions: [
          PopupMenuButton<_LogAction>(
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _LogAction.copy,
                child: MenuRow(
                  text: _tr(context, 'Copy logs', '澶嶅埗鏃ュ織'),
                  icon: const Icon(AIcons.clipboard),
                ),
              ),
              PopupMenuItem(
                value: _LogAction.export,
                child: MenuRow(
                  text: _tr(context, 'Export TXT', '瀵煎嚭 TXT'),
                  icon: Icon(AIcons.fileExport),
                ),
              ),
              PopupMenuItem(
                value: _LogAction.clear,
                child: MenuRow(
                  text: _tr(context, 'Clear logs', '娓呯┖鏃ュ織'),
                  icon: const Icon(AIcons.clear),
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
              return EmptyContent(
                icon: AIcons.description,
                text: _tr(context, 'No remote logs yet', '鏆傛棤杩滅▼鏃ュ織'),
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
      case _LogAction.clear:
        await remoteMediaLogService.clear();
        if (mounted) showFeedback(context, FeedbackType.info, l10n.genericSuccessFeedback);
    }
  }
}

enum _LogAction { copy, export, clear }
