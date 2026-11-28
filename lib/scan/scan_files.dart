// 扫描结果的本地落盘与系统分享
// Android:通过 pure_print/scan 原生通道取 App 私有缓存目录 + FileProvider 分享
// Windows:降级到系统临时目录(分享按钮不显示)
import 'dart:io';

import 'package:flutter/services.dart';

import 'escl_client.dart';

class ScanFiles {
  static const MethodChannel _channel = MethodChannel('pure_print/scan');

  static bool get canShare => Platform.isAndroid;

  static Future<Directory> _dir() async {
    if (Platform.isAndroid) {
      try {
        final p = await _channel.invokeMethod<String>('getScanDir');
        if (p != null && p.isNotEmpty) {
          final d = Directory(p);
          await d.create(recursive: true);
          return d;
        }
      } catch (_) {
        // 原生通道不可用时退回临时目录
      }
    }
    final d = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}pure_print_scans');
    await d.create(recursive: true);
    return d;
  }

  /// 保存扫描结果到私有缓存,返回绝对路径(可直接送去打印)
  static Future<String> save(ScanResult r) async {
    final d = await _dir();
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .replaceAll('T', '_');
    final f = File('${d.path}${Platform.pathSeparator}scan_$ts.${r.extension}');
    await f.writeAsBytes(r.bytes, flush: true);
    return f.absolute.path;
  }

  /// 调起系统分享面板(仅 Android)
  static Future<bool> share(String path, String mime) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareFile', <String, String>{
        'path': path,
        'mime': mime,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
