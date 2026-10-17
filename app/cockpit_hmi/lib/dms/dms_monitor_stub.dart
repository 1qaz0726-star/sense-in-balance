// 網頁版（沒有 dart:io／dart:ffi）的 DriverMonitor：DMS 一律關閉。
import 'dms_monitor_state.dart';

export 'dms_monitor_state.dart';

class DriverMonitor extends DriverMonitorState {
  /// 網頁版不支援。
  static const bool supported = false;

  Future<void> start() async {}
  Future<void> stop() async {}
}
