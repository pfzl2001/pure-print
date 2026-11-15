// 页码范围单测 + PDF 生成链路 + 实机出纸验证(纯 Dart,不拉 Flutter 框架)
// 运行: PUREPRINT_HOST=192.168.1.100 dart run tool/test_pdf_range.dart
// 说明:App 内的 pdfx 光栅化由 flutter build 编译验证;这里用已实机验证的
//      IPP 客户端把"选中页"的等价 JPEG 打出来,确认只出一张且页码正确。
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:pure_print/ipp/ipp_client.dart';
import 'package:pure_print/print/page_range.dart';

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main() async {
  stdout.writeln('== 1. 页码范围解析 ==');
  const cases = <String, List<int>>{
    '': [1, 2, 3],
    '2': [2],
    '1-2': [1, 2],
    '2-': [2, 3],
    '1,3': [1, 3],
    '1~3': [1, 2, 3],
    '3-1': [1, 2, 3],
    '2，3': [2, 3],
  };
  for (final e in cases.entries) {
    final got = parsePageRange(e.key, 3);
    final ok = _same(got, e.value);
    stdout.writeln('${ok ? "PASS" : "FAIL"}  "${e.key}" -> $got');
    if (!ok) throw StateError('页码范围解析不符: "${e.key}"');
  }
  try {
    parsePageRange('9', 3);
    throw StateError('越界范围应被拒绝');
  } on ArgumentError catch (_) {
    stdout.writeln('PASS  越界范围被正确拒绝');
  }

  stdout.writeln('\n== 2. 生成 3 页测试 PDF ==');
  final doc = pw.Document();
  for (var i = 1; i <= 3; i++) {
    doc.addPage(pw.Page(
      build: (_) => pw.Center(
        child: pw.Text('PAGE $i of 3', style: pw.TextStyle(fontSize: 48)),
      ),
    ));
  }
  final pdfBytes = await doc.save();
  await File('tool/_test_3pages.pdf').writeAsBytes(pdfBytes);
  stdout.writeln('PDF: 3 页, ${pdfBytes.length} 字节 -> tool/_test_3pages.pdf');

  stdout.writeln('\n== 3. 实机打印:仅第 2 页 ==');
  final host = Platform.environment['PUREPRINT_HOST'];
  if (host == null || host.isEmpty) {
    stderr.writeln('请设置 PUREPRINT_HOST 后再运行实机打印部分');
    exit(64);
  }
  final client = IppClient();
  final printer = IppPrinter(host,
      port: 631, path: '/ipp/print', name: '局域网打印机');
  final (_, endpoint) = await client.getCapabilities(printer);
  final pages = parsePageRange('2', 3);
  for (final n in pages) {
    final im = img.Image(width: 1240, height: 1754);
    img.fill(im, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(im,
        x1: 60, y1: 60, x2: 1180, y2: 260,
        color: img.ColorRgb8(30, 90, 180));
    img.drawString(im, 'PAGE $n of 3',
        font: img.arial48, x: 150, y: 130);
    img.drawString(im, 'PurePrint PAGE RANGE TEST',
        font: img.arial48, x: 150, y: 500);
    img.drawString(im, 'Only this sheet should come out',
        font: img.arial48, x: 150, y: 620);
    for (var y = 800; y < 1400; y += 100) {
      img.drawLine(im,
          x1: 120, y1: y, x2: 1120, y2: y,
          color: img.ColorRgb8(0, 0, 0), thickness: 3);
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(im, quality: 90));
    final (msg, _) = await client.printJob(
      endpoint,
      jpeg,
      format: 'image/jpeg',
      jobName: 'PurePrint page-range test',
      copies: 1,
      color: true,
      duplex: false,
    );
    stdout.writeln('第 $n 页: $msg (${(jpeg.length / 1024).toStringAsFixed(0)} KB)');
  }
  stdout.writeln('\n完成:共应出 1 张纸,内容应为 PAGE 2 of 3');
}
