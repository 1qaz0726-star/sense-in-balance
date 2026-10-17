import 'package:cockpit_hmi/main_repair_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('主控 IP 換成駕駛端連線網址，連線埠與路徑沿用預設', () {
    final url = monitorUrlForHost(' 192.168.43.120 ')!;
    expect(url.host, '192.168.43.120');
    expect(url.scheme, 'ws');
    expect(url.port, 8767);
    expect(url.path, '/repair');
  });

  test('不是 IPv4 一律拒絕', () {
    for (final bad in ['', 'abc', '192.168.1', '256.1.1.1', 'ws://1.2.3.4']) {
      expect(monitorUrlForHost(bad), isNull, reason: bad);
    }
  });
}
