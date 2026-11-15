// 只测设备状态查询,不打印(避免浪费纸张)
// 运行: PUREPRINT_HOST=192.168.1.100 dart run tool/test_state.dart
import 'dart:io';
import 'package:pure_print/ipp/ipp_client.dart';

Future<void> main() async {
  final host = Platform.environment['PUREPRINT_HOST'];
  if (host == null || host.isEmpty) {
    stderr.writeln('请设置 PUREPRINT_HOST,例如: '
        'PUREPRINT_HOST=192.168.1.100 dart run tool/test_state.dart');
    exit(64);
  }
  final printer = IppPrinter(host,
      port: 631, path: '/ipp/print', name: '局域网打印机');
  final s = await IppClient().getPrinterState(printer);
  print('printer-state = ${s.state} (${s.label})');
  print('summary       = ${s.summary}');
  print('reasons       = ${s.reasons}');
  print('marker-levels = ${s.markerLevels}');
  print('accepting     = ${s.acceptingJobs}');
  print('queued        = ${s.queuedJobs}');
}
