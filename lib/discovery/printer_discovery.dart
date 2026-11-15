// 打印机局域网发现:mDNS (_ipp._tcp) + 手动添加
import 'dart:async';
import 'dart:io';
import 'package:nsd/nsd.dart' as nsd;
import '../ipp/ipp_client.dart';

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
        final dp = DiscoveredPrinter(
          IppPrinter(address, port: port, name: name),
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
