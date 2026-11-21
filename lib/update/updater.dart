// 应用内更新:查询 GitHub Releases 最新版本 → 下载 APK → 校验 SHA-256 → 安装
// 只使用 dart:io HttpClient,不引入额外网络库;版本与缓存目录通过原生通道获取。
// 桌面端同样可查询版本,但只展示发布页信息,不会下载/安装 APK。
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

/// 固定仓库地址:只认这个仓库的发布,避免请求 injected URL
const String kReleaseApi =
    'https://api.github.com/repos/pfzl2001/pure-print/releases/latest';
const String kReleasePage =
    'https://github.com/pfzl2001/pure-print/releases/latest';

const String _kChannel = 'pure_print/update';
const String _kFallbackVersion = '1.8.2';

class UpdateInfo {
  final String tag;
  final String version;
  final String notes;
  final String apkUrl;
  final int size;
  final String checksum;

  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.size,
    required this.checksum,
  });

  String get sizeText => size <= 0
      ? '未知大小'
      : '${(size / 1048576).toStringAsFixed(1)} MB';
}

class AppUpdater {
  static const MethodChannel _channel = MethodChannel(_kChannel);

  /// 当前版本:Android 从原生 PackageManager 读取;
  /// 桌面端由 CI 通过 --dart-define=APP_VERSION=x.y.z 注入,本地开发用兜底值。
  static Future<String> currentVersion() async {
    if (Platform.isAndroid) {
      try {
        final v = await _channel.invokeMethod<String>('getAppVersion');
        if (v != null && v.isNotEmpty) return v;
      } on PlatformException catch (_) {}
    }
    return const String.fromEnvironment('APP_VERSION',
        defaultValue: _kFallbackVersion);
  }

  static int _parseVersion(String s) {
    final m = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(s);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 1000000 +
        int.parse(m.group(2)!) * 1000 +
        int.tryParse(m.group(3) ?? '0')!;
  }

  static bool isNewer(String remote, String local) =>
      _parseVersion(remote) > _parseVersion(local);

  static bool _trustedHost(String host) =>
      host == 'github.com' || host == 'objects.githubusercontent.com';

  /// 查询最新发布。网络异常、API 限流、资产缺失都会抛异常,由 UI 层展示。
  static Future<UpdateInfo> check() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse(kReleaseApi));
      req.headers
        ..set('User-Agent', 'PurePrint-App')
        ..set('Accept', 'application/vnd.github+json');
      final resp = await req.close();
      if (resp.statusCode == 403) {
        throw StateError('GitHub API 访问过于频繁（匿名限流），请稍后再试');
      }
      if (resp.statusCode != 200) {
        throw HttpException('GitHub API 返回 HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(await utf8.decoder.bind(resp).join())
          as Map<String, dynamic>;

      final tag = (data['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) throw StateError('发布信息中没有版本号');
      final assets = ((data['assets'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final apk = assets.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'),
        orElse: () => throw StateError('最新版本未提供 APK 安装包'),
      );
      final apkName = apk['name'] as String;
      final url = Uri.parse(apk['browser_download_url'] as String? ?? '');
      if (!_trustedHost(url.host)) {
        throw StateError('安装包下载地址不在可信域名下');
      }

      // 校验信息是可选的:拿不到时仍允许下载,只是跳过完整性校验
      var checksum = '';
      try {
        final sums = assets.firstWhere(
          (a) => a['name'] == 'SHA256SUMS.txt',
          orElse: () => <String, dynamic>{},
        );
        final sumsUrl = sums['browser_download_url'] as String?;
        if (sumsUrl != null && _trustedHost(Uri.parse(sumsUrl).host)) {
          final sreq = await client.getUrl(Uri.parse(sumsUrl));
          sreq.headers.set('User-Agent', 'PurePrint-App');
          final sresp = await sreq.close();
          if (sresp.statusCode == 200) {
            final body = await utf8.decoder.bind(sresp).join();
            for (final line in body.split('\n')) {
              final parts = line.trim().split(RegExp(r'\s{2,}'));
              if (parts.length == 2 && parts[1].trim() == apkName) {
                checksum = parts[0].trim();
                break;
              }
            }
          }
        }
      } catch (_) {}

      return UpdateInfo(
        tag: tag,
        version: tag.replaceFirst(RegExp(r'^v'), ''),
        notes: (data['body'] as String? ?? '').trim(),
        apkUrl: url.toString(),
        size: (apk['size'] as num?)?.toInt() ?? 0,
        checksum: checksum,
      );
    } finally {
      client.close();
    }
  }

  static bool _verified(List<int> bytes, String expected) {
    if (expected.isEmpty) return true;
    return sha256.convert(bytes).toString().toLowerCase() ==
        expected.toLowerCase();
  }

  /// 下载到应用私有缓存。已下载且校验通过的文件直接复用,避免重复流量。
  static Future<String> downloadApk(
    UpdateInfo info,
    void Function(int received, int total)? onProgress,
  ) async {
    var dirPath = '';
    if (Platform.isAndroid) {
      try {
        dirPath = await _channel.invokeMethod<String>('getCacheDir') ?? '';
      } on PlatformException catch (_) {}
    }
    if (dirPath.isEmpty) dirPath = Directory.systemTemp.path;

    final dir = Directory(
        '$dirPath${Platform.pathSeparator}updates')
      ..createSync(recursive: true);
    final file =
        File('${dir.path}${Platform.pathSeparator}pure_print-${info.version}.apk');

    if (await file.exists()) {
      if (_verified(await file.readAsBytes(), info.checksum)) return file.path;
      await file.delete();
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(info.apkUrl));
      req.headers.set('User-Agent', 'PurePrint-App');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('下载失败,HTTP ${resp.statusCode}');
      }
      final contentLength = resp.contentLength; // -1 表示服务端未给出长度
      final total = contentLength > 0 ? contentLength : info.size;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();

      if (!_verified(await file.readAsBytes(), info.checksum)) {
        await file.delete();
        throw StateError('APK 校验失败,已丢弃下载文件');
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  /// 只有 Android 能安装 APK;通过原生 FileProvider 调起系统安装器。
  static Future<void> installApk(String path) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }
}
