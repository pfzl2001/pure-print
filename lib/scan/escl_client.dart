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

  Socket? _activeSocket;
  bool _cancelRequested = false;

  /// 取消正在进行的扫描(由 UI 的「取消扫描」按钮调用)。
  void cancel() {
    _cancelRequested = true;
    _activeSocket?.destroy();
  }

  /// 打印机普遍使用自签证书;且 eSCL 的 NextDocument 是长轮询,
  /// 默认 15s 的 idleTimeout 会掐断等待中的连接,必须放大。
  HttpClient _http() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 300)
      ..autoUncompress = false;
    c.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return c;
  }

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
      req.headers.set('Accept-Encoding', 'identity');
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
    } on HttpException catch (e) {
      throw EsclException('HTTP 连接异常: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// eSCL 的 NextDocument 用 chunked 流式返回:L3350 会立刻回 200 + 响应头,
  /// 然后边扫描边发送图像数据,**发完并不发 chunked 结束块、也不关闭连接**。
  /// 因此不能等 Stream 自然结束(fold/forEach 会一直挂起直到超时),
  /// 必须边收边判断文档结束标记:JPEG 看 FFD9、PDF 看 %%EOF,命中即主动结束。
  bool _documentComplete(Uint8List b, String format) {
    if (b.length < 4) return false;
    if (format == 'application/pdf') {
      final start = b.length > 1024 ? b.length - 1024 : 0;
      return latin1
          .decode(b.sublist(start), allowInvalid: true)
          .contains('%%EOF');
    }
    // JPEG 的 FFD9 只在文件结尾出现(熵编码里 FF 后必跟 00 做字节填充)。
    // 只扫尾部若干字节:既避开 O(n²) 全量扫描,又能容忍 chunk 边界 /
    // 打印机在 EOI 之后追加的 chunk 头字节。
    final start = b.length > 64 ? b.length - 64 : 0;
    for (var i = start; i + 1 < b.length; i++) {
      if (b[i] == 0xFF && b[i + 1] == 0xD9) return true;
    }
    return false;
  }

  /// 按分辨率估算兜底超时(实际靠文档结束标记提前返回)。
  /// L3350 在 200dpi 彩色 A4 全幅下实测波动很大:快时 16 秒,慢时超过
  /// 180 秒(扫描头归位/预热/并发任务都会影响),旧版 120 秒超时必然失败。
  /// 界面已提供「取消扫描」,兜底给足也不影响体验。
  Duration _scanTimeout(ScanParams p) => Duration(
        seconds: p.resolution >= 1200
            ? 900
            : p.resolution >= 600
                ? 600
                : p.resolution >= 300
                    ? 420
                    : 300,
      );

  int _indexOf(List<int> b, List<int> pat, int from) {
    for (var i = from; i + pat.length <= b.length; i++) {
      var ok = true;
      for (var j = 0; j < pat.length; j++) {
        if (b[i + j] != pat[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  /// 用原始 socket 取回 NextDocument。
  ///
  /// 该机型的 chunked 响应结束后不发终止块、也不在 keep-alive 下关连接,
  /// dart:io 的 HttpClientResponse 流会永久挂起(实测 120s/180s 都超时),
  /// 而 Python/系统打印栈能正常收尾。因此这里自己发 HTTP、自己解析 chunk,
  /// 并以 JPEG 的 FFD9 / PDF 的 %%EOF 作为结束条件,不再等待连接关闭。
  Future<Uint8List> _fetchDocument(
    Uri uri,
    String format, {
    required Duration totalTimeout,
    void Function(int received)? onChunk,
  }) async {
    final Socket socket;
    try {
      socket = uri.scheme == 'https'
          ? await SecureSocket.connect(
              uri.host,
              uri.port,
              onBadCertificate: (X509Certificate c) => true,
              timeout: const Duration(seconds: 8),
            )
          : await Socket.connect(uri.host, uri.port,
              timeout: const Duration(seconds: 8));
    } on SocketException catch (e) {
      throw EsclException('连接扫描仪失败: ${e.message}');
    }
    _activeSocket = socket;

    final raw = <int>[];
    final doc = BytesBuilder();
    var pos = 0;
    // 0 HTTP 头 / 1 chunk 大小行 / 2 chunk 数据 / 3 chunk 尾 CRLF
    // 4 Content-Length 响应体 / 5 无长度(靠连接关闭或 EOI)
    var state = 0;
    var chunkRemaining = 0;
    var contentLength = -1;

    final path = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    socket.write('GET $path HTTP/1.1\r\n'
        'Host: ${uri.authority}\r\n'
        'User-Agent: PurePrint/1.0\r\n'
        'Accept-Encoding: identity\r\n'
        'Connection: close\r\n\r\n');
    await socket.flush();

    // 增量状态机:打印机会把一个大 chunk 拆成多个 TCP 包、中间停顿很久,
    // 必须"到多少消费多少",不能等整块数据齐了才处理。
    bool parse() {
      while (true) {
        switch (state) {
          case 0:
            final i = _indexOf(raw, const [13, 10, 13, 10], pos);
            if (i < 0) return false;
            final head = latin1.decode(raw.sublist(0, i), allowInvalid: true);
            final status = int.tryParse(RegExp(r'HTTP/\d\.\d\s+(\d+)')
                        .firstMatch(head)
                        ?.group(1) ??
                    '0') ??
                0;
            if (status != 200) {
              throw EsclException('取回扫描图像失败 HTTP $status');
            }
            final lower = head.toLowerCase();
            final m = RegExp(r'content-length:\s*(\d+)').firstMatch(lower);
            contentLength = m == null ? -1 : int.parse(m.group(1)!);
            pos = i + 4;
            state = lower.contains('transfer-encoding: chunked')
                ? 1
                : (contentLength >= 0 ? 4 : 5);
            break;
          case 1:
            final e = _indexOf(raw, const [13, 10], pos);
            if (e < 0) return false;
            final line =
                latin1.decode(raw.sublist(pos, e), allowInvalid: true);
            final size =
                int.tryParse(line.split(';').first.trim(), radix: 16) ?? -1;
            pos = e + 2;
            if (size <= 0) return true;
            chunkRemaining = size;
            state = 2;
            break;
          case 2:
            if (pos >= raw.length) return false;
            final avail = raw.length - pos;
            final take = chunkRemaining < avail ? chunkRemaining : avail;
            doc.add(raw.sublist(pos, pos + take));
            pos += take;
            chunkRemaining -= take;
            onChunk?.call(doc.length);
            if (_documentComplete(doc.toBytes(), format)) return true;
            if (chunkRemaining > 0) return false;
            state = 3;
            break;
          case 3:
            if (raw.length - pos < 2) return false;
            pos += 2;
            state = 1;
            break;
          case 4:
            final need = contentLength - doc.length;
            if (need > 0) {
              final avail = raw.length - pos;
              if (avail <= 0) return false;
              final take = need < avail ? need : avail;
              doc.add(raw.sublist(pos, pos + take));
              pos += take;
              onChunk?.call(doc.length);
              if (doc.length < contentLength) return false;
            }
            return true;
          default:
            if (raw.length > pos) {
              doc.add(raw.sublist(pos));
              pos = raw.length;
              onChunk?.call(doc.length);
            }
            return _documentComplete(doc.toBytes(), format);
        }
      }
    }

    final done = Completer<Uint8List>();
    Timer? timer;
    StreamSubscription<List<int>>? sub;
    void finish([Object? error]) {
      if (done.isCompleted) return;
      timer?.cancel();
      sub?.cancel();
      socket.destroy();
      if (_cancelRequested) {
        done.completeError(EsclException('扫描已取消'));
      } else if (error != null) {
        done.completeError(error);
      } else {
        final b = doc.toBytes();
        if (b.isEmpty) {
          done.completeError(EsclException('扫描图像为空'));
        } else {
          done.complete(b);
        }
      }
    }

    sub = socket.listen(
      (d) {
        if (done.isCompleted) return;
        raw.addAll(d);
        try {
          if (parse()) finish();
        } catch (e) {
          finish(e);
        }
      },
      onError: (Object e) => finish(e is SocketException
          ? EsclException('网络连接失败: ${e.message}')
          : e),
      onDone: () => finish(),
      cancelOnError: true,
    );
    timer = Timer(totalTimeout, () {
      finish(TimeoutException('扫描超时', totalTimeout));
    });
    try {
      return await done.future;
    } on TimeoutException {
      throw EsclException('扫描超时 (GET ${uri.path})');
    } finally {
      timer.cancel();
      if (identical(_activeSocket, socket)) _activeSocket = null;
      socket.destroy();
    }
  }

  /// 清理打印机侧任务。DELETE 在本机型上可能要 8–10 秒,给足余量并重试一次,
  /// 否则残留 job 会让下次创建任务返回 503。
  Future<void> _deleteJob(Uri job) async {
    for (var i = 0; i < 2; i++) {
      try {
        await _send('DELETE', job, timeout: const Duration(seconds: 30));
        return;
      } catch (_) {}
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
    if (created.status == 503) {
      throw EsclException('扫描仪忙(可能有上次未完成的任务),请稍等几秒后重试');
    }
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

    _cancelRequested = false;
    try {
      onProgress?.call('正在扫描,请稍候(平板扫描通常 10–60 秒)...');
      final next = job.replace(path: '${job.path}/NextDocument');
      var lastLogged = 0;
      final bytes = await _fetchDocument(
        next,
        p.documentFormat,
        totalTimeout: _scanTimeout(p),
        onChunk: (n) {
          if (n - lastLogged >= 65536) {
            lastLogged = n;
            onProgress?.call('已接收 ${(n / 1024).toStringAsFixed(0)} KB…');
          }
        },
      );
      if (bytes.isEmpty) throw EsclException('扫描图像为空');
      onProgress?.call('已取回扫描结果 (${(bytes.length / 1024).toStringAsFixed(0)} KB)');
      return ScanResult(
        bytes: bytes,
        mimeType: p.documentFormat,
        width: (p.width ?? (8.2677 * p.resolution).round())
            .clamp(c.minWidth, c.maxWidth),
        height: (p.height ?? (11.6929 * p.resolution).round())
            .clamp(c.minHeight, c.maxHeight),
      );
    } finally {
      // 无论成功失败都清理任务,避免打印机侧堆积 job(残留会导致下次 503)
      await _deleteJob(job);
    }
  }
}
