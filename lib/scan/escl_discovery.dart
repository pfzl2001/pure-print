// mDNS 发现 _uscan._tcp / _uscans._tcp 扫描仪(Flutter 插件层)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'escl_client.dart';

/// mDNS 发现 _uscan._tcp / _uscans._tcp 扫描仪
class EsclDiscovery {
  final List<nsd.Discovery> _discoveries = [];
  final StreamController<EsclDevice> _controller =
      StreamController<EsclDevice>.broadcast();
  final Map<String, EsclDevice> _found = {};

  Stream<EsclDevice> get stream => _controller.stream;
  List<EsclDevice> get found => _found.values.toList();

  static String? _txt(Map<String, Uint8List?>? txt, String key) {
    if (txt == null) return null;
    for (final e in txt.entries) {
      if (e.key.toLowerCase() != key.toLowerCase()) continue;
      final v = e.value;
      if (v == null || v.isEmpty) return '';
      return utf8.decode(v, allowMalformed: true).trim();
    }
    return null;
  }

  Future<void> start() async {
    await stop();
    _found.clear();
    for (final type in <String>['_uscan._tcp', '_uscans._tcp']) {
      try {
        final d = await nsd.startDiscovery(type);
        _discoveries.add(d);
        d.addServiceListener((service, status) {
          if (status != nsd.ServiceStatus.found) return;
          final address = service.addresses
                  ?.where((a) => a.type == InternetAddressType.IPv4)
                  .firstOrNull
                  ?.address ??
              service.host;
          if (address == null) return;
          final port = service.port ?? (type == '_uscans._tcp' ? 443 : 80);
          final key = '$address:$port';
          if (_found.containsKey(key)) return;
          final rs = (_txt(service.txt, 'rs') ?? 'eSCL')
              .replaceAll('"', '')
              .replaceAll(RegExp(r'^/+|/+$'), '');
          final device = EsclDevice(
            host: address,
            port: port,
            rs: rs.isEmpty ? 'eSCL' : rs,
            name: service.name ?? '',
            // 该机型 _uscan 也指向 443/HTTPS,端口比服务类型更可靠
            tls: port == 443 || type == '_uscans._tcp',
            version: _txt(service.txt, 'vers') ?? '2.9',
          );
          _found[key] = device;
          _controller.add(device);
        });
      } catch (_) {
        // 某些平台对不存在的服务类型会直接报错,忽略即可
      }
    }
  }

  EsclDevice addManual(String host) {
    final key = '$host:443';
    final existing = _found[key];
    if (existing != null) return existing;
    final device = EsclDevice(host: host, name: '手动添加');
    _found[key] = device;
    _controller.add(device);
    return device;
  }

  Future<void> stop() async {
    final list = List<nsd.Discovery>.from(_discoveries);
    _discoveries.clear();
    for (final d in list) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
