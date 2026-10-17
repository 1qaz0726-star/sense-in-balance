import 'package:cockpit_hmi/repair_collaboration_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('駕駛一句話摘要：只列待確認項，依固定順序', () {
    expect(
      driverOneLineSummary({
        'navVolume': 'keep',
        'mediaVolume': 'decrease',
      }, const {}),
      '音樂小一格，導航不變',
    );
    expect(
      driverOneLineSummary(
        {'rearFan': 'decrease', 'mediaVolume': 'increase'},
        {'rearFan': '此模擬座艙未提供介面'},
      ),
      '後座風此車不支援，音樂大一格',
    );
    expect(driverOneLineSummary(const {}, const {}), '沒有待確認的調整');
  });
}
