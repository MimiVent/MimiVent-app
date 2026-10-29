import 'dart:io';
import 'dart:typed_data';

/// 将 raw-deflate 数据解压到固定上限，超出包内声明的分块长度时立即中止。
Uint8List inflateRawDeflateBounded(
  List<int> compressed, {
  required int maximumOutputBytes,
}) {
  if (maximumOutputBytes < 0) {
    throw ArgumentError.value(maximumOutputBytes, 'maximumOutputBytes');
  }

  final sink = _BoundedBytesSink(maximumOutputBytes);
  ZLibDecoder(raw: true).startChunkedConversion(sink)
    ..add(compressed)
    ..close();
  return sink.takeBytes();
}

class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(this.maximumBytes);

  final int maximumBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _length = 0;

  @override
  void add(List<int> chunk) {
    if (chunk.length > maximumBytes - _length) {
      throw const FormatException('压缩块解压结果超过声明长度');
    }
    _length += chunk.length;
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
