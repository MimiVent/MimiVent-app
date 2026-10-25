/// App 与设备时序共用的时间选项和显示格式。
class TimeOption {
  const TimeOption(this.milliseconds, this.label);

  final int milliseconds;
  final String label;
}

const timeOptions = [
  TimeOption(0, '0 秒'),
  TimeOption(5000, '5 秒'),
  TimeOption(10000, '10 秒'),
  TimeOption(20000, '20 秒'),
  TimeOption(30000, '30 秒'),
  TimeOption(60000, '1 分钟'),
  TimeOption(120000, '2 分钟'),
  TimeOption(180000, '3 分钟'),
  TimeOption(300000, '5 分钟'),
  TimeOption(600000, '10 分钟'),
];

class DurationFormatter {
  const DurationFormatter._();

  static String clock(int milliseconds) {
    final seconds = (milliseconds / 1000).ceil();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  static String label(int milliseconds) {
    for (final option in timeOptions) {
      if (option.milliseconds == milliseconds) return option.label;
    }
    final seconds = (milliseconds / 1000).ceil();
    if (seconds >= 60) {
      final minutes = seconds ~/ 60;
      final remainder = seconds % 60;
      return '$minutes 分钟${remainder == 0 ? '' : ' $remainder 秒'}';
    }
    return '$seconds 秒';
  }
}
