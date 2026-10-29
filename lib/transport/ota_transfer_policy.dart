/// 根据设备报告的空闲队列槽计算下一次发送窗口。
///
/// 零槽必须保持为零，让调用方等待设备流控更新，不能强制发送一块。
int otaWindowSizeForCredits(int availableCredits, int maximumWindow) {
  if (availableCredits <= 0 || maximumWindow <= 0) return 0;
  return availableCredits < maximumWindow ? availableCredits : maximumWindow;
}

/// 进度偏移对应的字节总量：压缩包/差分包传输按包长度计，裸镜像按镜像长度计。
int otaTransferLength({
  required int imageLength,
  required int packageLength,
  required bool compressedPackage,
  required bool deltaPackage,
}) =>
    compressedPackage || deltaPackage ? packageLength : imageLength;
