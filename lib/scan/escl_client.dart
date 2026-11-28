// eSCL / AirScan (Mopria) 扫描客户端 —— 纯 Dart 实现,不依赖任何厂商 SDK
//
// 已在 EPSON L3350 Series (eSCL 2.9, mopria-certified-scan 1.5) 实机验证:
//   mDNS : _uscan._tcp / _uscans._tcp, TXT rs=eSCL, SRV -> EPSON224466.local:443
//   GET  : https://<host>/eSCL/ScannerCapabilities -> 200 text/xml
//   GET  : https://<host>/eSCL/ScannerStatus       -> 200 (<pwg:State>Idle)
//   POST : https://<host>/eSCL/ScanJobs            -> 201 + Location
//   GET  : <Location>/NextDocument                 -> 200 image/jpeg
//   DELETE <Location>                             -> 200
//
// 关键点:该机型 _uscan 服务实际走 HTTPS:443 且使用自签证书,因此需要
// badCertificateCallback 放行,并按 scheme/port 做候选回退,不能只按服务类型判断。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

class EsclException implements Exception {
  final String message;
  EsclException(this.message);
  @override
  String toString() => 'EsclException: $message';
}

/// 一台支持 eSCL 的扫描设备
class EsclDevice {
  final String host;
  final int port;
  final String rs; // TXT 里的资源根路径,例如 "eSCL"
  final String name;
  final bool tls;
  final String version;

  const EsclDevice({
    required this.host,
    this.port = 443,
    this.rs = 'eSCL',
    this.name = '',
    this.tls = true,
    this.version = '2.9',
  });

  EsclDevice copyWith({
    int? port,
    String? rs,
    bool? tls,
    String? name,
    String? version,
  }) =>
      EsclDevice(
        host: host,
        port: port ?? this.port,
        rs: rs ?? this.rs,
        name: name ?? this.name,
        tls: tls ?? this.tls,
        version: version ?? this.version,
      );

  String get basePath {
    final r = rs.replaceAll(RegExp(r'^/+|/+$'), '');
    return r.isEmpty ? '/eSCL' : '/$r';
  }

  Uri uri(String leaf) => Uri(
        scheme: tls ? 'https' : 'http',
        host: host,
        port: port,
        path: '$basePath/$leaf',
      );

  String get label => name.isEmpty ? host : name;

  @override
  String toString() =>
      '$label (${tls ? "https" : "http"}://$host:$port$basePath)';
}

/// ScannerCapabilities 解析结果
class EsclCapabilities {
  String version = '2.9';
  String makeAndModel = '';
  String serialNumber = '';
  String manufacturer = '';
  int minWidth = 96;
  int maxWidth = 2550;
  int minHeight = 96;
  int maxHeight = 3510;
  List<String> colorModes = const ['RGB24', 'Grayscale8', 'BlackAndWhite1'];
  List<String> documentFormats = const ['image/jpeg', 'application/pdf'];
  List<int> resolutions = const [100, 200, 300, 600, 1200];
  List<String> intents = const [
    'Document',
    'TextAndGraphic',
    'Photo',
    'Preview',
  ];
  List<String> contentTypes = const ['Photo', 'Text', 'TextAndPhoto'];
  int compressionMin = 1;
  int compressionMax = 3;
  int compressionNormal = 2;

  bool get supportsPdf => documentFormats.contains('application/pdf');
  bool get supportsJpeg => documentFormats.contains('image/jpeg');

  static String colorLabel(String mode) => switch (mode) {
        'RGB24' => '彩色',
        'Grayscale8' => '灰度',
        'BlackAndWhite1' => '黑白',
        _ => mode,
      };

  String get summary => [
        makeAndModel.isEmpty ? '未知型号' : makeAndModel,
        'eSCL $version',
        '分辨率 ${resolutions.join("/")} dpi',
        '$maxWidth×$maxHeight px',
      ].join(' · ');
}

/// 一次扫描的参数
class ScanParams {
  int resolution = 200;
  String colorMode = 'RGB24';
  String documentFormat = 'image/jpeg';
  String intent = 'TextAndGraphic';
  int compressionFactor = 2;
  // 为空时按 A4 全幅自动换算并夹到设备允许范围
  int? width;
  int? height;

  ScanParams copy() => ScanParams()
    ..resolution = resolution
    ..colorMode = colorMode
    ..documentFormat = documentFormat
    ..intent = intent
    ..compressionFactor = compressionFactor
    ..width = width
    ..height = height;
}

class ScanResult {
  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;

  ScanResult({
    required this.bytes,
    required this.mimeType,
    this.width = 0,
    this.height = 0,
  });

  bool get isJpeg => mimeType == 'image/jpeg';
  bool get isPdf => mimeType == 'application/pdf';
  String get extension => isPdf ? 'pdf' : 'jpg';
  String get sizeText => '${(bytes.length / 1024).toStringAsFixed(0)} KB';
}

class _Resp {
  final int status;
  final HttpHeaders headers;
  final Uint8List body;
  _Resp(this.status, this.headers, this.body);
}

// ---------------- XML 辅助(按 localName 匹配,忽略命名空间前缀) ----------------
Iterable<XmlElement> _els(XmlNode root, String local) =>
    root.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

String _one(XmlNode root, String local, [String fallback = '']) => _els(root, local)
    .map((e) => e.innerText.trim())
    .firstWhere((s) => s.isNotEmpty, orElse: () => fallback);

List<String> _many(XmlNode root, String local) => _els(root, local)
    .map((e) => e.innerText.trim())
    .where((s) => s.isNotEmpty)
    .toSet()
    .toList();

int _int(XmlNode root, String local, int fallback) =>
    int.tryParse(_one(root, local)) ?? fallback;

class EsclClient {
  /// 同一 host 上一次成功连通的 scheme/port,后续请求复用,避免每次都回退探测
  final Map<String, EsclDevice> _resolved = {};

  EsclDevice? resolved(String host) => _resolved[host];

  HttpClient _http() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    // 打印机普遍使用自签证书,必须放行
    ..badCertificateCallback = (cert, host, port) => true;

  Future<_Resp> _send(
    String method,
    Uri uri, {
    List<int>? body,
    String? contentType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = _http();
    try {
      final req = await client.openUrl(method, uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'PurePrint/1.0');
      if (contentType != null) {
        req.headers.contentType = ContentType.parse(contentType);
      }
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final resp = await req.close().timeout(timeout);
      final bytes = await resp
          .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
          .timeout(timeout);
      return _Resp(resp.statusCode, resp.headers, bytes.toBytes());
    } on SocketException catch (e) {
      throw EsclException('网络连接失败(${uri.host}:${uri.port}): ${e.message}');
    } on TimeoutException {
      throw EsclException('请求超时 ($method ${uri.path})');
    } on HandshakeException catch (e) {
      throw EsclException('TLS 握手失败: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  EsclCapabilities _parseCaps(String xmlText) {
    final doc = XmlDocument.parse(xmlText);
    final c = EsclCapabilities();
    c.version = _one(doc, 'Version', '2.9');
    c.makeAndModel = _one(doc, 'MakeAndModel');
    c.serialNumber = _one(doc, 'SerialNumber');
    c.manufacturer = _one(doc, 'Manufacturer');
    c.minWidth = _int(doc, 'MinWidth', 96);
    c.maxWidth = _int(doc, 'MaxWidth', 2550);
    c.minHeight = _int(doc, 'MinHeight', 96);
    c.maxHeight = _int(doc, 'MaxHeight', 3510);

    final modes = _many(doc, 'ColorMode');
    if (modes.isNotEmpty) c.colorModes = modes;
    final formats = _many(doc, 'DocumentFormat');
    if (formats.isNotEmpty) c.documentFormats = formats;
    final dpi = _many(doc, 'XResolution')
        .map(int.tryParse)
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    if (dpi.isNotEmpty) c.resolutions = dpi;
    final intents = _many(doc, 'Intent');
    if (intents.isNotEmpty) c.intents = intents;
    final types = _many(doc, 'ContentType');
    if (types.isNotEmpty) c.contentTypes = types;

    // CompressionFactorSupport 内的 Min/Max/Normal 与其它 Support 块同名,
    // 必须限定父节点,不能全局取第一个。
    final cfs = _els(doc, 'CompressionFactorSupport').firstOrNull;
    if (cfs != null) {
      c.compressionMin = _int(cfs, 'Min', 1);
      c.compressionMax = _int(cfs, 'Max', 3);
      c.compressionNormal = _int(cfs, 'Normal', 2);
    }
    return c;
  }

  Future<EsclCapabilities> _caps(EsclDevice d) async {
    final r = await _send('GET', d.uri('ScannerCapabilities'));
    if (r.status != 200) {
      throw EsclException('读取扫描仪能力失败 HTTP ${r.status} @ ${d.uri('ScannerCapabilities')}');
    }
    return _parseCaps(utf8.decode(r.body, allowMalformed: true));
  }

  /// 探测设备,返回 (能力, 实际可用的 scheme/port 组合)。
  /// 候选顺序:发现时推断 → 取反 scheme → 强制 443/HTTPS → 强制 80/HTTP。
  Future<(EsclCapabilities, EsclDevice)> probe(EsclDevice d) async {
    final candidates = <EsclDevice>[];
    void add(EsclDevice x) {
      if (!candidates.any((c) => c.tls == x.tls && c.port == x.port)) {
        candidates.add(x);
      }
    }

    add(d);
    add(d.copyWith(tls: !d.tls));
    add(d.copyWith(port: 443, tls: true));
    add(d.copyWith(port: 80, tls: false));

    Object? last;
    for (final cand in candidates) {
      try {
        final caps = await _caps(cand);
        _resolved[d.host] = cand;
        return (caps, cand);
      } catch (e) {
        last = e;
      }
    }
    throw EsclException('无法连接扫描仪 $d: $last');
  }

  Future<String> status(EsclDevice d) async {
    final dev = _resolved[d.host] ?? d;
    final r = await _send('GET', dev.uri('ScannerStatus'));
    if (r.status != 200) {
      throw EsclException('读取扫描仪状态失败 HTTP ${r.status}');
    }
    final doc = XmlDocument.parse(utf8.decode(r.body, allowMalformed: true));
    return _one(doc, 'State', 'Unknown');
  }

  /// 生成 eSCL ScanSettings XML(已按 L3350 实机验证)
  String buildSettings(EsclCapabilities c, ScanParams p) {
    // A4 = 210×297mm = 8.2677×11.6929 inch
    final w = (p.width ?? (8.2677 * p.resolution).round())
        .clamp(c.minWidth, c.maxWidth);
    final h = (p.height ?? (11.6929 * p.resolution).round())
        .clamp(c.minHeight, c.maxHeight);
    final compression = p.compressionFactor
        .clamp(c.compressionMin, c.compressionMax);
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<scan:ScanSettings '
        'xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" '
        'xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">'
        '<pwg:Version>${c.version}</pwg:Version>'
        '<scan:Intent>${p.intent}</scan:Intent>'
        '<pwg:ScanRegions pwg:MustHonor="true"><pwg:ScanRegion>'
        '<pwg:ScanRegionStartX>0</pwg:ScanRegionStartX>'
        '<pwg:ScanRegionStartY>0</pwg:ScanRegionStartY>'
        '<pwg:ScanRegionWidth>$w</pwg:ScanRegionWidth>'
        '<pwg:ScanRegionHeight>$h</pwg:ScanRegionHeight>'
        '</pwg:ScanRegion></pwg:ScanRegions>'
        '<pwg:InputSource>Platen</pwg:InputSource>'
        '<pwg:ColorMode>${p.colorMode}</pwg:ColorMode>'
        '<pwg:DocumentFormat>${p.documentFormat}</pwg:DocumentFormat>'
        '<scan:XResolution>${p.resolution}</scan:XResolution>'
        '<scan:YResolution>${p.resolution}</scan:YResolution>'
        '<scan:CompressionFactor>$compression</scan:CompressionFactor>'
        '</scan:ScanSettings>';
  }

  /// 执行一次扫描:创建任务 → 取回 NextDocument → 删除任务
  Future<ScanResult> scan(
    EsclDevice d,
    ScanParams p, {
    EsclCapabilities? caps,
    void Function(String)? onProgress,
  }) async {
    EsclCapabilities c;
    EsclDevice dev;
    if (caps != null && _resolved.containsKey(d.host)) {
      c = caps;
      dev = _resolved[d.host]!;
    } else {
      onProgress?.call('读取扫描仪能力...');
      final probed = await probe(d);
      c = probed.$1;
      dev = probed.$2;
    }

    final xml = buildSettings(c, p);
    onProgress?.call('创建扫描任务 (${p.resolution} dpi · '
        '${EsclCapabilities.colorLabel(p.colorMode)} · ${p.documentFormat})...');
    final created = await _send(
      'POST',
      dev.uri('ScanJobs'),
      body: utf8.encode(xml),
      contentType: 'text/xml; charset=utf-8',
      timeout: const Duration(seconds: 30),
    );
    if (created.status != 201 && created.status != 200) {
      final detail = utf8.decode(created.body, allowMalformed: true);
      throw EsclException('创建扫描任务失败 HTTP ${created.status}'
          '${detail.isNotEmpty ? ': $detail' : ''}');
    }
    final loc = created.headers.value('location');
    if (loc == null || loc.isEmpty) {
      throw EsclException('扫描任务已创建但未返回 Location');
    }
    final parsed = Uri.parse(loc);
    final job = parsed.hasScheme
        ? parsed
        : Uri(
            scheme: dev.tls ? 'https' : 'http',
            host: dev.host,
            port: dev.port,
            path: loc,
          );

    try {
      onProgress?.call('正在扫描,请稍候(平板扫描通常 10–30 秒)...');
      final next = job.replace(path: '${job.path}/NextDocument');
      final got = await _send(
        'GET',
        next,
        timeout: const Duration(seconds: 120),
      );
      if (got.status != 200) {
        throw EsclException('取回扫描图像失败 HTTP ${got.status}');
      }
      if (got.body.isEmpty) throw EsclException('扫描图像为空');
      onProgress?.call('已取回扫描结果 (${(got.body.length / 1024).toStringAsFixed(0)} KB)');
      return ScanResult(
        bytes: got.body,
        mimeType: p.documentFormat,
        width: (p.width ?? (8.2677 * p.resolution).round())
            .clamp(c.minWidth, c.maxWidth),
        height: (p.height ?? (11.6929 * p.resolution).round())
            .clamp(c.minHeight, c.maxHeight),
      );
    } finally {
      // 无论成功失败都清理任务,避免打印机侧堆积 job
      try {
        await _send('DELETE', job, timeout: const Duration(seconds: 10));
      } catch (_) {}
    }
  }
}
