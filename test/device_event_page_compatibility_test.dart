import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/models.dart';

void main() {
  test('读取明细截断标记，兼容未提供标记的旧固件', () {
    Map<String, dynamic> response() => {
          'events': <Object>[],
          'offset': 0,
          'nextOffset': 0,
          'total': 0,
          'hasMore': false,
        };
    final original = response();
    expect(
        DeviceEventPage.fromJson(original,
                requestedStart: 1700000000, requestedEnd: 1700003600)
            .eventsTruncated,
        isFalse);
    original['eventsTruncated'] = true;
    expect(
        DeviceEventPage.fromJson(original,
                requestedStart: 1700000000, requestedEnd: 1700003600)
            .eventsTruncated,
        isTrue);
  });

  test('uses requested time bounds when an older device omits them', () {
    final page = DeviceEventPage.fromJson(
      {
        'events': <Object>[],
        'offset': 0,
        'nextOffset': 0,
        'total': 0,
        'hasMore': false,
      },
      requestedStart: 1700000000,
      requestedEnd: 1700003600,
    );

    expect(page.start, 1700000000);
    expect(page.end, 1700003600);
  });
}
