// 打印机局域网发现:mDNS (_ipp._tcp) + 手动添加
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;
import '../ipp/ipp_client.dart';

/// 读取 mDNS TXT 记录里的字符串值(Android NSD 返回 Uint8List)。
/// IPP Everywhere 用 `rp` 广播 IPP 资源路径,例如 "ipp/print"。
String? _txtValue(Map<String, Uint8List?>? txt, String key) {
  if (txt == null) return null;
  for (final e in txt.entries) {
    if (e.key.toLowerCase() != key.toLowerCase()) continue;
    final v = e.value;
    if (v == null || v.isEmpty) return '';
    return utf8.decode(v, allowMalformed: true).trim();
  }
  return null;
}

/// 把 TXT 里的 rp 规范化成以 / 开头的 HTTP 路径。
String _normalizeIppPath(String? rp) {
  if (rp == null) return '/ipp/print';
  var p = rp.replaceAll('"', '').trim();
  if (p.isEmpty) return '/ipp/print';
  if (!p.startsWith('/')) p = '/$p';
  return p;
}

class DiscoveredPrinter {
  final IppPrinter printer;
  final String source; // 'mDNS' 或 '手动'
  DiscoveredPrinter(this.printer, this.source);
}

class PrinterDiscovery {
  nsd.Discovery? _discovery;
  final _controller = StreamController<DiscoveredPrinter>.broadcast();
  final _found = <String, DiscoveredPrinter>{};

  Stream<DiscoveredPrinter> get stream => _controller.stream;
  List<DiscoveredPrinter> get found => _found.values.toList();

  /// 开始 mDNS 扫描 _ipp._tcp 服务
  Future<void> start() async {
    await stop();
    _found.clear();
    _discovery = await nsd.startDiscovery('_ipp._tcp');
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        final host = service.host;
        if (host == null) return;
        // 有些打印机广播的 host 是主机名,优先取第一个 IPv4 地址
        final address = service.addresses
                ?.where((a) => a.type == InternetAddressType.IPv4)
                .firstOrNull
                ?.address ??
            host;
        final port = service.port ?? 631;
        final key = '$address:$port';
        if (_found.containsKey(key)) return;
        final name = service.name ?? '未知打印机';
        // 关键修复:以前一律硬编码 /ipp/print,忽略了打印机在 TXT 里广播的 rp。
        // 路径不对时嵌入式 Web 服务器会返回 200 + 空 body / HTML 管理页,
        // 旧逻辑误判为连接成功,表现就是「搜得到却连不上」。
        final path = _normalizeIppPath(_txtValue(service.txt, 'rp'));
        final tls = _txtValue(service.txt, 'TLS');
        final transport = (tls == '1' || tls?.toLowerCase() == 'true')
            ? IppTransport.tls
            : IppTransport.upgrade;
        final dp = DiscoveredPrinter(
          IppPrinter(address,
              port: port, path: path, name: name, transport: transport),
          'mDNS',
        );
        _found[key] = dp;
        _controller.add(dp);
      }
    });
  }

  /// 手动按 IP 添加
  DiscoveredPrinter addManual(String host, {int port = 631, String? path}) {
    final key = '$host:$port';
    final existing = _found[key];
    if (existing != null) return existing;
    final dp = DiscoveredPrinter(
      IppPrinter(host, port: port, path: path ?? '/ipp/print', name: '手动添加'),
      '手动',
    );
    _found[key] = dp;
    _controller.add(dp);
    return dp;
  }

  /// 移除手动添加的打印机(仅本次会话;不影响 mDNS 发现结果)
  void removeManual(String host, {int port = 631}) {
    final key = '$host:$port';
    final existing = _found[key];
    if (existing == null || existing.source != '手动') return;
    _found.remove(key);
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) await nsd.stopDiscovery(d);
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
