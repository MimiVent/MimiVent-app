import 'package:flutter_test/flutter_test.dart';
import 'package:mimivent_app/data/statistics_event_cache.dart';

void main() {
  test('does not discard cached events for an ambiguous empty response', () {
    final previous = [
      {'id': 4, 'time': 100, 'kind': 'fan_on'},
      {'id': 3, 'time': 90, 'kind': 'fan_off'},
    ];

    expect(
      StatisticsEventCache.shouldDiscardPrevious(
        previous: previous,
        incoming: const [],
        incomingTotal: 0,
        sameWindow: true,
        firstPage: true,
      ),
      isFalse,
    );
  });

  test('still discards cached events when a nonempty total proves shrinkage',
      () {
    final previous = [
      {'id': 4, 'time': 100, 'kind': 'fan_on'},
      {'id': 3, 'time': 90, 'kind': 'fan_off'},
    ];

    expect(
      StatisticsEventCache.shouldDiscardPrevious(
        previous: previous,
        incoming: const [],
        incomingTotal: 1,
        sameWindow: true,
        firstPage: true,
      ),
      isTrue,
    );
  });
}
