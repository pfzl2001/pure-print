// 接收 Android 端「分享到 / 用其他应用打开」导入的文件
// 对应原 APK 的微信文件导入能力,但全部用 Android 公开 API + 自有实现
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import '../print/print_service.dart';

/// 按扩展名判断可打印类型
ContentType? typeByExtension(String path) {
  final ext = path.split('.').last.toLowerCase();
  if (const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic']
      .contains(ext)) {
    return ContentType.photo;
  }
  if (ext == 'pdf') {
    return ContentType.pdf;
  }
  if (const ['docx', 'xlsx', 'doc', 'xls'].contains(ext)) {
    return ContentType.office;
  }
  return null;
}

class SharedDocument {
  final String path;
  final ContentType? type;
  const SharedDocument(this.path, this.type);
  String get name => path.split(Platform.pathSeparator).last;
  bool get supported => type != null;
}

/// 微信/QQ 分享出来的文件经常没有扩展名,这里按文件头嗅探并补出正确后缀
Future<SharedDocument> classifySharedFile(String path) async {
  final byExt = typeByExtension(path);
  if (byExt != null) return SharedDocument(path, byExt);

  Uint8List head;
  try {
    final raf = await File(path).open();
    final bytes = await raf.read(8);
    await raf.close();
    head = Uint8List.fromList(bytes);
  } catch (_) {
    return SharedDocument(path, null);
  }
  if (head.length < 4) return SharedDocument(path, null);

  // PDF: %PDF
  if (head[0] == 0x25 &&
      head[1] == 0x50 &&
      head[2] == 0x44 &&
      head[3] == 0x46) {
    return _withExt(path, '.pdf', ContentType.pdf);
  }
  // JPEG: FF D8 FF
  if (head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) {
    return _withExt(path, '.jpg', ContentType.photo);
  }
  // PNG: 89 50 4E 47
  if (head[0] == 0x89 &&
      head[1] == 0x50 &&
      head[2] == 0x4E &&
      head[3] == 0x47) {
    return _withExt(path, '.png', ContentType.photo);
  }
  // ZIP 容器:进一步判断是 docx 还是 xlsx
  if (head[0] == 0x50 && head[1] == 0x4B) {
    try {
      final bytes = await File(path).readAsBytes();
      final arc = ZipDecoder().decodeBytes(bytes);
      final names = arc.files.map((f) => f.name).toList();
      final isDocx = names.any((n) => n.startsWith('word/'));
      final isXlsx = names.any((n) => n.startsWith('xl/'));
      if (isDocx || isXlsx) {
        return await _withExt(
            path, isDocx ? '.docx' : '.xlsx', ContentType.office);
      }
    } catch (_) {}
  }
  return SharedDocument(path, null);
}

Future<SharedDocument> _withExt(
    String path, String ext, ContentType type) async {
  final target = File('$path$ext');
  if (!await target.exists()) {
    await File(path).copy(target.path);
  }
  return SharedDocument(target.path, type);
}

class ShareHandler {
  static const _channel = MethodChannel('pure_print/share');

  /// 热启动:应用已在后台,再次被分享唤起
  static void Function(List<String> paths)? onFiles;

  static Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedFiles' && call.arguments is List) {
        onFiles?.call(List<String>.from(call.arguments as List));
      }
    });
  }

  /// 冷启动:取出并清空MainActivity缓存的分享文件
  static Future<List<String>> takeInitial() async {
    try {
      final res = await _channel.invokeMethod('getInitialShare');
      await _channel.invokeMethod('clearInitialShare');
      if (res is List) return List<String>.from(res);
    } catch (_) {
      // 非 Android 平台或通道不可用时静默降级
    }
    return <String>[];
  }

  /// 当前是否已绑定到 WiFi(打印流量走局域网的前提)
  static Future<Map<String, dynamic>> wifiInfo() async {
    try {
      final res = await _channel.invokeMethod('getWifiInfo');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (_) {}
    return <String, dynamic>{'bound': false, 'ssid': ''};
  }
}
