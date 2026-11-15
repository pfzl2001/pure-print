// 用 App 自身的 Dart IPP 客户端做实机验证(会打出一页带图案的测试纸)
// 运行: dart run tool/test_ipp.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:pure_print/ipp/ipp_client.dart';

Future<void> main() async {
  final host = Platform.environment['PUREPRINT_HOST'];
  if (host == null || host.isEmpty) {
    stderr.writeln('请设置 PUREPRINT_HOST,例如: '
        'PUREPRINT_HOST=192.168.1.100 dart run tool/test_ipp.dart');
    exit(64);
  }
  final client = IppClient();
  final printer = IppPrinter(host,
      port: 631, path: '/ipp/print', name: '局域网打印机');

  stdout.writeln('== 1. Dart 客户端能力探测 ==');
  final (caps, endpoint) = await client.getCapabilities(printer);
  stdout.writeln('协商端点: ${endpoint.endpoint}');
  stdout.writeln('型号: ${caps.makeAndModel}');
  stdout.writeln('支持格式: ${caps.documentFormats.join(", ")}');
  stdout.writeln('默认纸张: ${caps.mediaSizes.take(3).join(", ")}');

  stdout.writeln('\n== 2. 生成带内容的测试页 ==');
  final image = img.Image(width: 1240, height: 1754);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(image,
      x1: 60, y1: 60, x2: 1180, y2: 260,
      color: img.ColorRgb8(30, 90, 180));
  img.drawString(image, 'PurePrint DART TEST',
      font: img.arial48, x: 130, y: 130);
  final colors = [
    img.ColorRgb8(220, 40, 40),
    img.ColorRgb8(40, 160, 70),
    img.ColorRgb8(40, 90, 220),
    img.ColorRgb8(0, 0, 0),
    img.ColorRgb8(240, 190, 20),
  ];
  for (var idx = 0; idx < 5; idx++) {
    final x0 = 120 + idx * 205;
    img.fillRect(image,
        x1: x0, y1: 600, x2: x0 + 175, y2: 780, color: colors[idx]);
  }
  for (var y = 900; y < 1500; y += 80) {
    img.drawLine(image,
        x1: 120,
        y1: y,
        x2: 1120,
        y2: y,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 3);
  }
  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 88));
  stdout.writeln('测试页 JPEG: ${(jpeg.length / 1024).toStringAsFixed(0)} KB');

  stdout.writeln('\n== 3. 通过 App 客户端发送打印任务 ==');
  final (msg, used) = await client.printJob(
    endpoint,
    jpeg,
    format: 'image/jpeg',
    jobName: 'PurePrint dart test',
    copies: 1,
    color: true,
    duplex: false,
  );
  stdout.writeln('结果: $msg');
  stdout.writeln('实际端点: ${used.endpoint}');

  stdout.writeln('\n== 4. 查询设备状态 / 墨量 ==');
  final state = await client.getPrinterState(used);
  stdout.writeln('状态: ${state.summary}');
}
