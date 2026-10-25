import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme/mimivent_theme.dart';

class AmbientGlow extends StatelessWidget {
  const AmbientGlow({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 360,
        height: 360,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Color(0x3D3E765F), Color(0x003E765F)],
          ),
        ),
      );
}

/// 风机运行时给顶部 Logo 添加柔和的金色呼吸光。
class RunningLogoGlow extends StatefulWidget {
  const RunningLogoGlow({
    super.key,
    required this.isRunning,
    required this.size,
    required this.radius,
  });

  final bool isRunning;
  final double size;
  final double radius;

  @override
  State<RunningLogoGlow> createState() => RunningLogoGlowState();
}

class RunningLogoGlowState extends State<RunningLogoGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: MimiVentMotion.logoPulse,
    value: widget.isRunning ? .35 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.isRunning) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant RunningLogoGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRunning && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.isRunning && _pulse.isAnimating) {
      _pulse.animateTo(0, duration: const Duration(milliseconds: 260));
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final glow = widget.isRunning ? _pulse.value : 0.0;
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: const Color(0xFF203A32),
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: widget.isRunning
                  ? [
                      BoxShadow(
                        color:
                            MimiVentColors.amber.withOpacity(.28 + .18 * glow),
                        blurRadius: 14 + 12 * glow,
                        spreadRadius: 1 + 1.5 * glow,
                      ),
                      BoxShadow(
                        color:
                            MimiVentColors.amber.withOpacity(.12 + .1 * glow),
                        blurRadius: 26 + 10 * glow,
                        spreadRadius: 2 + glow,
                      ),
                    ]
                  : const [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: Image.asset('assets/images/mimivent_logo.png',
                  width: widget.size, height: widget.size, fit: BoxFit.cover),
            ),
          );
        },
      );
}

/// 蓝牙搜索/连接状态动画：设备周围扩散的脉冲环，复用在扫描弹窗中。
class BluetoothSearchPulse extends StatefulWidget {
  const BluetoothSearchPulse({
    super.key,
    required this.active,
    required this.connecting,
    required this.connected,
    this.size = 150,
  });

  final bool active;
  final bool connecting;
  final bool connected;
  final double size;

  @override
  State<BluetoothSearchPulse> createState() => BluetoothSearchPulseState();
}

class BluetoothSearchPulseState extends State<BluetoothSearchPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: MimiVentMotion.bluetoothPulse,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _pulse.repeat();
  }

  @override
  void didUpdateWidget(covariant BluetoothSearchPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.active && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => Stack(
            alignment: Alignment.center,
            children: [
              for (var index = 0; index < 3; index++) _pulseRing(index),
              Container(
                width: 62 * widget.size / 150,
                height: 62 * widget.size / 150,
                decoration: BoxDecoration(
                  color: const Color(0xFF29443B),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: MimiVentColors.mint.withOpacity(.3)),
                  boxShadow: [
                    BoxShadow(
                      color: MimiVentColors.mint.withOpacity(.12),
                      blurRadius: 22 * widget.size / 150,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  widget.connected
                      ? Icons.check_rounded
                      : widget.connecting
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_searching_rounded,
                  color: widget.connecting
                      ? MimiVentColors.amber
                      : MimiVentColors.mint,
                  size: 29 * widget.size / 150,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _pulseRing(int index) {
    final phase = (_pulse.value + index / 3) % 1;
    return Opacity(
      opacity: widget.active ? (1 - phase) * .58 : 0,
      child: Transform.scale(
        scale: .42 + phase * .7,
        child: Container(
          width: 116 * widget.size / 150,
          height: 116 * widget.size / 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: widget.connecting
                    ? MimiVentColors.amber
                    : MimiVentColors.mint),
          ),
        ),
      ),
    );
  }
}

/// 扫描到设备后在卡片边缘流动的高亮描边。
class MarqueeBorder extends StatefulWidget {
  const MarqueeBorder({
    super.key,
    required this.child,
    this.active = true,
    this.radius = 22,
  });

  final Widget child;
  final bool active;
  final double radius;

  @override
  State<MarqueeBorder> createState() => _MarqueeBorderState();
}

class _MarqueeBorderState extends State<MarqueeBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _motion.repeat();
  }

  @override
  void didUpdateWidget(covariant MarqueeBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!widget.active && _motion.isAnimating) {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _motion,
        child: widget.child,
        builder: (context, child) => CustomPaint(
          foregroundPainter: _MarqueeBorderPainter(
            progress: _motion.value,
            active: widget.active,
            radius: widget.radius,
          ),
          child: child,
        ),
      );
}

class _MarqueeBorderPainter extends CustomPainter {
  const _MarqueeBorderPainter({
    required this.progress,
    required this.active,
    required this.radius,
  });

  final double progress;
  final bool active;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active || size.isEmpty) return;

    const strokeWidth = 1.8;
    final rect = Offset.zero & size;
    final borderPath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(strokeWidth / 2),
          Radius.circular(radius),
        ),
      );
    final metric = borderPath.computeMetrics().first;
    final segmentLength = metric.length * .2;
    final start = metric.length * progress;
    final end = start + segmentLength;
    final segment = end <= metric.length
        ? metric.extractPath(start, end)
        : (Path()
          ..addPath(metric.extractPath(start, metric.length), Offset.zero)
          ..addPath(metric.extractPath(0, end - metric.length), Offset.zero));
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = MimiVentColors.mint.withOpacity(.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);
    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = MimiVentColors.mint.withOpacity(.78);

    canvas.drawPath(segment, glow);
    canvas.drawPath(segment, highlight);
  }

  @override
  bool shouldRepaint(covariant _MarqueeBorderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      oldDelegate.radius != radius;
}

class FanRotorGlyph extends StatelessWidget {
  const FanRotorGlyph({super.key, required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _FanRotorPainter(color),
      );
}

/// 状态卡片主风机：启动时从静止渐渐放大、加速，停止时平滑减速并缩回待机尺寸。
class FanStatusRotor extends StatefulWidget {
  const FanStatusRotor({
    super.key,
    required this.isRunning,
    required this.size,
  });

  final bool isRunning;
  final double size;

  @override
  State<FanStatusRotor> createState() => FanStatusRotorState();
}

class FanStatusRotorState extends State<FanStatusRotor>
    with TickerProviderStateMixin {
  late final AnimationController _motion;
  late final Ticker _rotationTicker;
  Duration _lastElapsed = Duration.zero;
  double _rotation = 0;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
      vsync: this,
      duration: MimiVentMotion.fanStart,
      value: widget.isRunning ? 1 : 0,
    )..addStatusListener(_handleMotionStatus);
    _rotationTicker = createTicker(_advanceRotation);
    if (widget.isRunning) _rotationTicker.start();
  }

  @override
  void didUpdateWidget(covariant FanStatusRotor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRunning == widget.isRunning) return;

    if (widget.isRunning) {
      if (!_rotationTicker.isActive) {
        _lastElapsed = Duration.zero;
        _rotationTicker.start();
      }
      _motion.animateTo(
        1,
        duration: MimiVentMotion.fanStart,
        curve: Curves.easeInCubic,
      );
    } else {
      _motion.animateTo(
        0,
        duration: MimiVentMotion.fanStop,
        // 停机初段保留大部分转速，之后再逐渐减速，表现风扇惯性。
        curve: Curves.easeInCubic,
      );
    }
  }

  void _advanceRotation(Duration elapsed) {
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (delta.inMicroseconds <= 0) return;

    // 角速度与启动进度绑定，因此图标放大的同时也逐渐加速。
    final power = math.pow(_motion.value, 1.65).toDouble();
    // 待机时转速为 0；停止过程随 motion 一起减速至完全静止。
    final revolutionsPerSecond = 1.5 * power;
    _rotation = (_rotation +
            delta.inMicroseconds /
                Duration.microsecondsPerSecond *
                revolutionsPerSecond *
                math.pi *
                2) %
        (math.pi * 2);
    setState(() {});
  }

  void _handleMotionStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_rotationTicker.isActive) {
      _rotation = 0;
      return;
    }
    if (status == AnimationStatus.dismissed) {
      _rotationTicker.stop();
      _lastElapsed = Duration.zero;
      _rotation = 0;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _rotationTicker.dispose();
    _motion
      ..removeStatusListener(_handleMotionStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          // 尺寸、颜色和转速共用同一进度，让缩回待机尺寸时刚好停转。
          final progress = math.pow(_motion.value, 1.65).toDouble();
          final scale = 1 + .5 * progress;
          final color =
              Color.lerp(MimiVentColors.mint, MimiVentColors.amber, progress)!;
          return Transform.rotate(
            angle: _rotation,
            child: Transform.scale(
              scale: scale,
              child: FanRotorGlyph(color: color, size: widget.size),
            ),
          );
        },
      );
}

class _FanRotorPainter extends CustomPainter {
  const _FanRotorPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = size.shortestSide / 40;
    final bladePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    for (var blade = 0; blade < 3; blade++) {
      canvas.save();
      canvas.rotate(blade * 2 * 3.141592653589793 / 3);
      final path = Path()
        ..moveTo(0, -4)
        ..cubicTo(1, -9, 5, -17, 5, -25)
        ..cubicTo(5, -31, 1, -34, -3, -30)
        ..cubicTo(-8, -24, -7, -13, -4, -4)
        ..close();
      canvas.drawPath(path, bladePaint);
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, 4.2, bladePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FanRotorPainter oldDelegate) =>
      oldDelegate.color != color;
}
