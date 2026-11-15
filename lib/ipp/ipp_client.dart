// IPP/1.1 (RFC 8011) 客户端 —— 针对 Epson L3350 实机验证
// 关键适配(2026-11-14 实测):
//  1) RFC 2817 就地 TLS 升级:OPTIONS * → 101 → 同一连接 TLS,否则打印机返回 426
//  2) 响应含两层 HTTP 头(外层 UPnP 200 + 内层 IPP 200),需定位 IPP magic
//  3) Print-Job 不能带 requesting-user-name,否则返回 0x0400
//  4) 请求头与正文分开发送并分块,避免嵌入式服务器缓冲区溢出
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class _Tag {
  static const int operationAttr = 0x01;
  static const int jobAttr = 0x02;
  static const int end = 0x03;
  static const int integer = 0x21;
  static const int boolean = 0x22;
  static const int enumValue = 0x23;
  static const int nameWithoutLanguage = 0x42;
  static const int keyword = 0x44;
  static const int uri = 0x45;
  static const int charset = 0x47;
  static const int naturalLang = 0x48;
  static const int mimeType = 0x49;
}

class IppException implements Exception {
  final String message;
  final int? statusCode;
  IppException(this.message, {this.statusCode});
  @override
  String toString() => 'IppException: $message';
}

/// 传输方式:升级型 Epson / 直接 IPPS / 明文 IPP
enum IppTransport { upgrade, tls, plain }

class IppPrinter {
  final String host;
  final int port;
  final String path;
  final String name;
  final IppTransport transport;
  IppPrinter(this.host,
      {this.port = 631,
      this.path = '/ipp/print',
      this.name = '',
      this.transport = IppTransport.upgrade});

  IppPrinter copyWith({int? port, String? path, IppTransport? transport}) =>
      IppPrinter(host,
          port: port ?? this.port,
          path: path ?? this.path,
          name: name,
          transport: transport ?? this.transport);

  /// printer-uri 始终使用 ipp:// 方案(实测 Epson 要求)
  String get printerUri => 'ipp://$host:$port$path';

  String get endpoint =>
      '${transport == IppTransport.tls ? 'https' : 'http'}://$host:$port$path'
      '${transport == IppTransport.upgrade ? ' (TLS升级)' : ''}';

  @override
  String toString() => '${name.isEmpty ? host : name} ($host:$port)';
}

class PrinterCapabilities {
  String makeAndModel = '';
  List<String> documentFormats = [];
  List<String> mediaSizes = [];
  List<String> colorModes = [];
  List<String> sides = [];
  bool get supportsPdf => documentFormats.contains('application/pdf');
  bool get supportsJpeg => documentFormats.contains('image/jpeg');
  bool get supportsPwgRaster => documentFormats.contains('image/pwg-raster');
  bool get supportsUrf => documentFormats.contains('image/urf');
  bool get supportsDuplex => sides.any((s) => s.startsWith('two-sided'));
  bool get supportsColor => colorModes.any((s) => s == 'color' || s == 'auto');
  @override
  String toString() =>
      'model=$makeAndModel, formats=[${documentFormats.join(", ")}], color=$supportsColor, duplex=$supportsDuplex';
}

/// 打印机实时状态(取自 IPP Get-Printer-Attributes 的标准属性)
class PrinterStateInfo {
  int state = 3; // RFC 8011: 3=idle, 4=processing, 5=stopped
  List<String> reasons = [];
  List<int> markerLevels = []; // 墨量百分比
  bool acceptingJobs = true;
  int queuedJobs = 0;

  String get label => switch (state) {
        3 => '空闲 / 就绪',
        4 => '正在打印',
        5 => '已暂停',
        _ => '状态 $state',
      };

  /// IPP marker-levels 用 -2 表示"未知",这类值不参与展示
  List<int> get knownMarkerLevels =>
      markerLevels.where((v) => v >= 0 && v <= 100).toList();

  String get summary => [
        label,
        if (queuedJobs > 0) '队列 $queuedJobs 个任务',
        if (knownMarkerLevels.isNotEmpty)
          '墨量 ${knownMarkerLevels.map((v) => "$v%").join(" / ")}',
        ...reasons.take(2),
        acceptingJobs ? '可接收任务' : '暂停接收任务',
      ].join(' · ');
}

class IppClient {
  int _requestId = 1;

  /// 查询设备状态、打印队列与墨量(marker-levels)
  Future<PrinterStateInfo> getPrinterState(IppPrinter printer) async {
    final body = _encode(
      operationId: 0x000B, // Get-Printer-Attributes
      printer: printer,
      // 实测 Epson 嵌入式 IPP 服务只接受已验证的 'all' 请求,
      // 传属性名列表时响应体不含 IPP 报文
      opStrings: {'requested-attributes': 'all'},
    );
    final (resp, _) = await _postWithFallback(printer, body);
    final (status, attrs) = _parse(resp);
    if (status > 0x00FF) {
      throw IppException(
          '查询设备状态失败 (IPP status=0x${status.toRadixString(16)})',
          statusCode: status);
    }
    final s = PrinterStateInfo();
    final st = attrs['printer-state']?.firstOrNull;
    if (st is int) s.state = st;
    s.reasons = attrs['printer-state-reasons']
            ?.map((e) => e.toString())
            .where((e) => e != 'none' && e.isNotEmpty)
            .toList() ??
        [];
    s.markerLevels = attrs['marker-levels']
            ?.map((e) {
              var v = e is int ? e : (int.tryParse(e.toString()) ?? -1);
              // IPP integer 是有符号 32 位;0xFFFFFFFE(-2) 表示"未知"
              if (v > 0x7FFFFFFF) v -= 0x100000000;
              return v;
            })
            .toList() ??
        [];
    final acc = attrs['printer-is-accepting-jobs']?.firstOrNull;
    if (acc is bool) s.acceptingJobs = acc;
    final q = attrs['queued-job-count']?.firstOrNull;
    if (q is int) s.queuedJobs = q;
    return s;
  }

  static void _str(BytesBuilder b, int tag, String n, String v) {
    final nb = utf8.encode(n), vb = utf8.encode(v);
    b.addByte(tag);
    b.add([nb.length >> 8, nb.length & 0xFF]);
    b.add(nb);
    b.add([vb.length >> 8, vb.length & 0xFF]);
    b.add(vb);
  }

  static void _int(BytesBuilder b, int tag, String n, int v) {
    final nb = utf8.encode(n);
    b.addByte(tag);
    b.add([nb.length >> 8, nb.length & 0xFF]);
    b.add(nb);
    b.add([0, 4]);
    b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  }

  Uint8List _encode({
    required int operationId,
    required IppPrinter printer,
    Map<String, String> opStrings = const {},
    Map<String, int> opInts = const {},
    Map<String, String> jobStrings = const {},
    Map<String, int> jobInts = const {},
  }) {
    final b = BytesBuilder();
    b.add([1, 1]);
    b.add([(operationId >> 8) & 0xFF, operationId & 0xFF]);
    final rid = _requestId++;
    b.add([(rid >> 24) & 0xFF, (rid >> 16) & 0xFF, (rid >> 8) & 0xFF, rid & 0xFF]);

    b.addByte(_Tag.operationAttr);
    _str(b, _Tag.charset, 'attributes-charset', 'utf-8');
    _str(b, _Tag.naturalLang, 'attributes-natural-language', 'en');
    _str(b, _Tag.uri, 'printer-uri', printer.printerUri);
    // 不发 requesting-user-name:Epson 会返回 0x0400
    opStrings.forEach((k, v) {
      final tag = k == 'document-format'
          ? _Tag.mimeType
          : (k == 'job-name' ? _Tag.nameWithoutLanguage : _Tag.keyword);
      _str(b, tag, k, v);
    });
    opInts.forEach((k, v) => _int(b, _Tag.integer, k, v));
    if (jobStrings.isNotEmpty || jobInts.isNotEmpty) {
      b.addByte(_Tag.jobAttr);
      jobStrings.forEach((k, v) => _str(b, _Tag.keyword, k, v));
      jobInts.forEach((k, v) => _int(b, _Tag.integer, k, v));
    }
    b.addByte(_Tag.end);
    return b.toBytes();
  }

  /// 从(可能含两层 HTTP 头的)响应中提取 IPP 报文体
  Uint8List _extractIpp(Uint8List resp) {
    for (var i = 0; i + 5 < resp.length; i++) {
      if (resp[i] == 13 &&
          resp[i + 1] == 10 &&
          resp[i + 2] == 13 &&
          resp[i + 3] == 10 &&
          resp[i + 4] == 0x01 &&
          resp[i + 5] == 0x01) {
        return Uint8List.sublistView(resp, i + 4);
      }
    }
    for (var i = 0; i + 3 < resp.length; i++) {
      if (resp[i] == 13 &&
          resp[i + 1] == 10 &&
          resp[i + 2] == 13 &&
          resp[i + 3] == 10) {
        return Uint8List.sublistView(resp, i + 4);
      }
    }
    throw IppException('响应中没有 IPP 报文');
  }

  (int, Map<String, List<Object>>) _parse(Uint8List data) {
    final payload = _extractIpp(data);
    if (payload.length < 8) throw IppException('IPP 响应太短');
    final status = (payload[2] << 8) | payload[3];
    final attrs = <String, List<Object>>{};
    int pos = 8;
    String? lastName;
    while (pos < payload.length) {
      final tag = payload[pos++];
      if (tag == _Tag.end) break;
      if (tag >= 0x01 && tag <= 0x0F) {
        lastName = null;
        continue;
      }
      if (pos + 2 > payload.length) break;
      final nameLen = (payload[pos] << 8) | payload[pos + 1];
      pos += 2;
      String? name;
      if (nameLen > 0) {
        name = utf8.decode(payload.sublist(pos, pos + nameLen),
            allowMalformed: true);
        pos += nameLen;
        lastName = name;
      } else {
        name = lastName;
      }
      if (name == null || pos + 2 > payload.length) break;
      final valueLen = (payload[pos] << 8) | payload[pos + 1];
      pos += 2;
      if (pos + valueLen > payload.length) break;
      final raw = payload.sublist(pos, pos + valueLen);
      pos += valueLen;
      Object value;
      switch (tag) {
        case _Tag.integer:
        case _Tag.enumValue:
          value = valueLen == 4
              ? (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3]
              : 0;
          break;
        case _Tag.boolean:
          value = raw.isNotEmpty && raw[0] == 1;
          break;
        default:
          value = utf8.decode(raw, allowMalformed: true);
      }
      attrs.putIfAbsent(name, () => []).add(value);
    }
    return (status, attrs);
  }

  // ---------------- RFC 2817 就地 TLS 升级 ----------------
  Future<Uint8List> _postUpgrade(IppPrinter p, Uint8List body) async {
    final socket = await Socket.connect(p.host, p.port,
        timeout: const Duration(seconds: 8));
    final buf = BytesBuilder();
    final ready = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) {
      buf.add(data);
      if (!ready.isCompleted &&
          latin1.decode(buf.toBytes(), allowInvalid: true).contains('\r\n\r\n')) {
        ready.complete();
        sub.pause();
      }
    }, onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });

    final options = 'OPTIONS * HTTP/1.1\r\nHost: ${p.host}:${p.port}\r\n'
        'Upgrade: TLS/1.0\r\nConnection: Upgrade\r\n'
        'Content-Length: 0\r\n\r\n';
    socket.add(utf8.encode(options));
    await socket.flush();
    await ready.future.timeout(const Duration(seconds: 8));
    final head = latin1.decode(buf.toBytes(), allowInvalid: true);
    if (!head.contains('101')) {
      socket.destroy();
      throw IppException('TLS 升级协商失败: ${head.split('\r\n').first}');
    }

    final secure = await SecureSocket.secure(socket,
            host: p.host, onBadCertificate: (_) => true)
        .timeout(const Duration(seconds: 12));

    final httpHead = 'POST ${p.path} HTTP/1.1\r\nHost: ${p.host}:${p.port}\r\n'
        'Content-Type: application/ipp\r\nContent-Length: ${body.length}\r\n'
        'Connection: close\r\n\r\n';
    secure.add(utf8.encode(httpHead));
    await secure.flush();
    await Future.delayed(const Duration(milliseconds: 120));
    for (var i = 0; i < body.length; i += 4096) {
      secure.add(body.sublist(i, math.min(i + 4096, body.length)));
      await secure.flush();
      await Future.delayed(const Duration(milliseconds: 8));
    }
    final resp = await secure
        .fold<BytesBuilder>(BytesBuilder(), (bb, d) => bb..add(d))
        .timeout(const Duration(seconds: 60));
    await secure.close();
    return resp.toBytes();
  }

  // ---------------- 普通 HTTP / 直接 HTTPS ----------------
  Future<Uint8List> _postHttp(IppPrinter p, Uint8List body, bool tls) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final scheme = tls ? 'https' : 'http';
      final req = await client
          .postUrl(Uri.parse('$scheme://${p.host}:${p.port}${p.path}'));
      req.headers.contentType = ContentType('application', 'ipp');
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      req.contentLength = body.length;
      req.add(body);
      final response = await req.close().timeout(const Duration(seconds: 60));
      final all = await response
          .fold<BytesBuilder>(BytesBuilder(), (bb, c) => bb..add(c));
      if (response.statusCode != 200) {
        throw IppException('HTTP ${response.statusCode}',
            statusCode: response.statusCode);
      }
      return all.toBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<(Uint8List, IppPrinter)> _postWithFallback(
      IppPrinter printer, Uint8List body) async {
    final endpoints = <IppPrinter>[];
    final seenEp = <String>{};
    void addEp(IppPrinter p) {
      if (seenEp.add('${p.port}|${p.path}')) endpoints.add(p);
    }
    addEp(printer);
    addEp(printer.copyWith(port: 631, path: '/ipp/print'));
    addEp(printer.copyWith(port: 631, path: '/ipp'));

    final errors = <String>[];
    var first = true;
    for (final ep in endpoints) {
      final modes = <IppTransport>[
        printer.transport,
        IppTransport.upgrade,
        IppTransport.tls,
        IppTransport.plain,
      ];
      final seenMode = <IppTransport>{};
      for (final mode in modes) {
        if (!seenMode.add(mode)) continue;
        if (!first) await Future.delayed(const Duration(milliseconds: 500));
        first = false;
        final p = ep.copyWith(transport: mode);
        try {
          final bytes = mode == IppTransport.upgrade
              ? await _postUpgrade(p, body)
              : await _postHttp(p, body, mode == IppTransport.tls);
          return (bytes, p);
        } catch (e) {
          errors.add('${p.endpoint} → $e');
        }
      }
    }
    throw IppException('所有连接方式均失败:\n  ${errors.join('\n  ')}');
  }

  // ---------------- 业务操作 ----------------
  Future<(PrinterCapabilities, IppPrinter)> getCapabilities(
      IppPrinter printer) async {
    final body = _encode(
      operationId: 0x000B,
      printer: printer,
      opStrings: {'requested-attributes': 'all'},
    );
    final (resp, used) = await _postWithFallback(printer, body);
    final (status, attrs) = _parse(resp);
    if (status > 0x00FF) {
      throw IppException(
          '查询打印机能力失败 (IPP status=0x${status.toRadixString(16)})',
          statusCode: status);
    }
    return (_toCaps(attrs), used);
  }

  PrinterCapabilities _toCaps(Map<String, List<Object>> a) {
    final c = PrinterCapabilities();
    c.makeAndModel = a['printer-make-and-model']?.firstOrNull?.toString() ??
        a['printer-name']?.firstOrNull?.toString() ??
        '';
    c.documentFormats =
        a['document-format-supported']?.map((e) => e.toString()).toList() ?? [];
    c.mediaSizes =
        a['media-supported']?.map((e) => e.toString()).toList() ?? [];
    c.colorModes = a['print-color-mode-supported']
            ?.map((e) => e.toString())
            .toList() ??
        [];
    c.sides = a['sides-supported']?.map((e) => e.toString()).toList() ?? [];
    return c;
  }

  Future<(String, IppPrinter)> printJob(
    IppPrinter printer,
    Uint8List documentData, {
    required String format,
    String jobName = 'PurePrint Job',
    int copies = 1,
    bool color = true,
    bool duplex = false,
    String media = 'iso_a4_210x297mm',
  }) async {
    final header = _encode(
      operationId: 0x0002,
      printer: printer,
      opStrings: {'job-name': jobName, 'document-format': format},
      jobStrings: {
        'media': media,
        'print-color-mode': color ? 'color' : 'monochrome',
        'sides': duplex ? 'two-sided-long-edge' : 'one-sided',
      },
      jobInts: {'copies': copies},
    );
    final body = Uint8List.fromList([...header, ...documentData]);
    final (resp, used) = await _postWithFallback(printer, body);
    final (status, attrs) = _parse(resp);
    if (status > 0x00FF) {
      final msg = attrs['status-message']?.firstOrNull?.toString() ?? '';
      throw IppException(
          '打印被拒绝 (IPP status=0x${status.toRadixString(16)})${msg.isNotEmpty ? ': $msg' : ''}',
          statusCode: status);
    }
    final jobId = attrs['job-id']?.firstOrNull?.toString() ?? '?';
    return ('任务已受理 (job-id=$jobId, ${used.endpoint})', used);
  }
}
