// 纯 Dart eSCL 诊断工具:不依赖 Flutter 插件,可直接对真机跑一遍协议实现
//
// 用法(在项目根目录执行):
//   dart --packages=.dart_tool/package_config.json tool/escl_probe.dart [host] [--scan]
//
// 不带 --scan 时只读取 ScannerCapabilities / ScannerStatus(只读,不触发扫描);
// 带 --scan 时额外执行一次 100dpi 灰度平板扫描,取回 JPEG 但不落盘。
import 'dart:io';

import 'package:pure_print/scan/escl_client.dart';

Future<void> main(List<String> args) async {
  final host = args.isEmpty ? '192.168.1.7' : args[0];
  final doScan = args.contains('--scan');
  final client = EsclClient();
  final device = EsclDevice(
    host: host,
    port: 443,
    rs: 'eSCL',
    tls: true,
    name: 'PurePrint 诊断',
  );

  stdout.writeln('目标: $device');
  try {
    final (caps, used) = await client.probe(device);
    stdout.writeln('探测成功: ${caps.summary}');
    stdout.writeln('  端点      : ${used.uri("ScannerCapabilities")}');
    stdout.writeln('  厂商/型号 : ${caps.manufacturer} / ${caps.makeAndModel}');
    stdout.writeln('  序列号    : ${caps.serialNumber}');
    stdout.writeln('  色彩模式  : ${caps.colorModes.join(", ")}');
    stdout.writeln('  输出格式  : ${caps.documentFormats.join(", ")}');
    stdout.writeln('  分辨率    : ${caps.resolutions.join(", ")} dpi');
    stdout.writeln('  Intent    : ${caps.intents.join(", ")}');
    stdout.writeln('  内容类型  : ${caps.contentTypes.join(", ")}');
    stdout.writeln('  压缩系数  : ${caps.compressionMin}-${caps.compressionMax}'
        ' (默认 ${caps.compressionNormal})');
    stdout.writeln('  尺寸上限  : ${caps.maxWidth}×${caps.maxHeight} px');
    stdout.writeln('  设备状态  : ${await client.status(used)}');

    if (doScan) {
      final params = ScanParams()
        ..resolution = 100
        ..colorMode = 'Grayscale8'
        ..documentFormat = 'image/jpeg'
        ..intent = 'TextAndGraphic';
      stdout.writeln('--- 生成的 ScanSettings ---');
      stdout.writeln(client.buildSettings(caps, params));
      final r = await client.scan(
        used,
        params,
        caps: caps,
        onProgress: (m) => stdout.writeln('  > $m'),
      );
      final magic = r.bytes
          .take(2)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      stdout.writeln('扫描成功: ${r.sizeText} · ${r.width}×${r.height} · magic=$magic');
      if (magic != 'ffd8') throw EsclException('返回内容不是 JPEG');
    }
    stdout.writeln('ESCL_PROBE_OK');
  } catch (e) {
    stderr.writeln('ESCL_PROBE_FAILED: $e');
    exitCode = 1;
  }
}
