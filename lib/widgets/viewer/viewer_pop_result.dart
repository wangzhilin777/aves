import 'package:aves/model/entry/entry.dart';

class ViewerPopResult {
  final AvesEntry entry;
  final int? previewPositionMillis;

  const ViewerPopResult({
    required this.entry,
    this.previewPositionMillis,
  });
}
