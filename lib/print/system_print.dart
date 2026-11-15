// 系统打印服务兜底:调用 Android/iOS 原生打印框架
// 原生框架内置成熟的 IPP/AirPrint 实现,兼容性最好,但会弹出系统打印对话框
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../office/office_to_pdf.dart';

class SystemPrintService {
  /// 直接打印 PDF 字节(弹系统打印面板,用户选择打印机)
  static Future<bool> printPdf(Uint8List pdfBytes, String jobName) async {
    return Printing.layoutPdf(
      name: jobName,
      onLayout: (_) => pdfBytes,
    );
  }

  /// 照片 → A4 页面 PDF 后走系统打印
  static Future<bool> printPhoto(String path, String jobName) async {
    final bytes = await File(path).readAsBytes();
    final doc = pw.Document();
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
    return printPdf(await doc.save(), jobName);
  }

  /// 办公文档 → 简化排版 PDF 后走系统打印
  static Future<bool> printOffice(String path, String jobName) async {
    // 确保中文字体已注入
    try {
      final data = await rootBundle.load('assets/fonts/DroidSansFallbackFull.ttf');
      OfficeToPdf.setFont(pw.Font.ttf(data));
    } catch (_) {}
    final pdfBytes = await OfficeToPdf.convert(path);
    return printPdf(pdfBytes, jobName);
  }

  /// 按扩展名自动分发
  static Future<bool> printFile(String path, String jobName) async {
    final ext = path.split('.').last.toLowerCase();
    if (ext == 'pdf') {
      return printPdf(await File(path).readAsBytes(), jobName);
    }
    if (['docx', 'xlsx', 'doc', 'xls'].contains(ext)) {
      return printOffice(path, jobName);
    }
    return printPhoto(path, jobName);
  }
}
