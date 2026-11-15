// Word(.docx) / Excel(.xlsx) → PDF 简化排版转换器
// docx/xlsx 本质是 zip + xml,这里自实现解析,输出简化版式 PDF
// 说明:此为简化渲染(文本/表格/段落顺序),不保证与原 Office 排版像素级一致
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart' as xml;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class OfficeToPdf {
  /// 根据扩展名分发
  static Future<Uint8List> convert(String path) async {
    final ext = path.split('.').last.toLowerCase();
    final bytes = await File(path).readAsBytes();
    switch (ext) {
      case 'docx':
        return docxToPdf(bytes);
      case 'xlsx':
        return xlsxToPdf(bytes);
      case 'doc':
      case 'xls':
      case 'ppt':
      case 'pptx':
        throw UnsupportedError('暂不支持 .$ext 旧格式,请先用 WPS/Office 另存为 .docx/.xlsx');
      default:
        throw UnsupportedError('不支持的格式: .$ext');
    }
  }

  // ---------------- DOCX ----------------
  static Future<Uint8List> docxToPdf(Uint8List docxBytes) async {
    final archive = ZipDecoder().decodeBytes(docxBytes);
    final docEntry = archive.findFile('word/document.xml');
    if (docEntry == null) throw FormatException('无效的 docx:缺少 word/document.xml');
    final document = xml.XmlDocument.parse(utf8Decode(docEntry.content as List<int>));

    final blocks = <pw.Widget>[];
    final body = document.findAllElements('w:body').firstOrNull;
    if (body != null) {
      for (final el in body.childElements) {
        final tag = el.name.local;
        if (tag == 'p') {
          final text = _paragraphText(el);
          if (text.trim().isNotEmpty) {
            blocks.add(pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(text, style: _style(12)),
            ));
          }
        } else if (tag == 'tbl') {
          blocks.add(_docxTable(el));
          blocks.add(pw.SizedBox(height: 8));
        }
      }
    }
    if (blocks.isEmpty) {
      blocks.add(pw.Text('(文档内容为空或暂不支持该内容类型)', style: _style(12)));
    }
    return _buildPdf(blocks);
  }

  static String _paragraphText(xml.XmlElement p) {
    final buf = StringBuffer();
    for (final t in p.findAllElements('w:t')) {
      buf.write(t.innerText);
    }
    return buf.toString();
  }

  static pw.Widget _docxTable(xml.XmlElement tbl) {
    final rows = <List<String>>[];
    for (final tr in tbl.findElements('w:tr')) {
      final cells = <String>[];
      for (final tc in tr.findElements('w:tc')) {
        final buf = StringBuffer();
        for (final t in tc.findAllElements('w:t')) {
          buf.write(t.innerText);
        }
        cells.add(buf.toString());
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return pw.SizedBox();
    return _table(rows, fontSize: 10, borderWidth: 0.5);
  }

  // ---------------- XLSX ----------------
  static Future<Uint8List> xlsxToPdf(Uint8List xlsxBytes) async {
    final archive = ZipDecoder().decodeBytes(xlsxBytes);

    // 共享字符串表
    final shared = <String>[];
    final ssEntry = archive.findFile('xl/sharedStrings.xml');
    if (ssEntry != null) {
      final ssDoc = xml.XmlDocument.parse(utf8Decode(ssEntry.content as List<int>));
      for (final si in ssDoc.findAllElements('si')) {
        final buf = StringBuffer();
        for (final t in si.findAllElements('t')) {
          buf.write(t.innerText);
        }
        shared.add(buf.toString());
      }
    }

    // 工作表名与路径映射(简化:按 sheetN.xml 顺序)
    final sheetNames = <String>[];
    final wbEntry = archive.findFile('xl/workbook.xml');
    if (wbEntry != null) {
      final wbDoc = xml.XmlDocument.parse(utf8Decode(wbEntry.content as List<int>));
      for (final s in wbDoc.findAllElements('sheet')) {
        sheetNames.add(s.getAttribute('name') ?? 'Sheet');
      }
    }

    final blocks = <pw.Widget>[];
    final sheetFiles = archive.files
        .where((f) =>
            f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (var i = 0; i < sheetFiles.length; i++) {
      final name = i < sheetNames.length ? sheetNames[i] : sheetFiles[i].name;
      blocks.add(pw.Text('工作表:$name', style: _style(14, bold: true)));
      blocks.add(pw.SizedBox(height: 6));

      final sheetDoc =
          xml.XmlDocument.parse(utf8Decode(sheetFiles[i].content as List<int>));
      final rows = <List<String>>[];
      for (final row in sheetDoc.findAllElements('row')) {
        final cells = <String>[];
        for (final c in row.findElements('c')) {
          final type = c.getAttribute('t');
          final v = c.findElements('v').firstOrNull?.innerText ?? '';
          final inlineStrs = c.findElements('is');
          if (type == 's' && v.isNotEmpty) {
            final idx = int.tryParse(v) ?? -1;
            cells.add(idx >= 0 && idx < shared.length ? shared[idx] : v);
          } else if (type == 'inlineStr' && inlineStrs.isNotEmpty) {
            final buf = StringBuffer();
            for (final t in inlineStrs.first.findAllElements('t')) {
              buf.write(t.innerText);
            }
            cells.add(buf.toString());
          } else {
            cells.add(v);
          }
        }
        if (cells.any((e) => e.isNotEmpty)) rows.add(cells);
      }
      if (rows.isNotEmpty) {
        blocks.add(_table(rows, fontSize: 9));
      } else {
        blocks.add(pw.Text('(空工作表)', style: _style(11)));
      }
      blocks.add(pw.SizedBox(height: 12));
    }
    if (blocks.isEmpty) {
      blocks.add(pw.Text('(未找到工作表数据)', style: _style(11)));
    }
    return _buildPdf(blocks);
  }

  // ---------------- PDF 输出 ----------------
  static pw.Font? _cjkFont;

  /// 注入中文字体(由调用方从 assets 加载后传入)
  static void setFont(pw.Font font) => _cjkFont = font;

  /// 供自检确认字体已注入;未注入时中文会回落成方块
  static bool get hasCjkFont => _cjkFont != null;

  static pw.TextStyle _style(double size, {bool bold = false}) => pw.TextStyle(
        font: _cjkFont,
        fontSize: size,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        fontFallback: _cjkFont != null ? [_cjkFont!] : const [],
      );

  /// 统一表格构造。
  /// pdf 包的 TableHelper.fromTextArray 默认 headerCount=1,会把第一行当表头;
  /// 且 headerStyle 为 null 时回落到内置 Helvetica(无中文字形)→ 中文显示为方块。
  /// 这里关闭「首行表头」语义并给每一个单元格显式注入中文字体。
  static pw.Widget _table(
    List<List<String>> rows, {
    double fontSize = 9,
    double borderWidth = 0.4,
  }) {
    final cell = _style(fontSize);
    return pw.TableHelper.fromTextArray(
      data: rows,
      headerCount: 0,
      headerStyle: _style(fontSize, bold: true),
      cellStyle: cell,
      oddCellStyle: cell,
      border: pw.TableBorder.all(width: borderWidth),
      cellPadding: const pw.EdgeInsets.all(3),
    );
  }

  static Future<Uint8List> _buildPdf(List<pw.Widget> blocks) async {
    // theme 兜底:即使某处漏传 style,默认文本也走中文字体(不再回落 Helvetica)
    final theme = _cjkFont == null
        ? null
        : pw.ThemeData.withFont(
            base: _cjkFont,
            fontFallback: [_cjkFont!],
          );
    final doc = pw.Document(theme: theme);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => blocks,
    ));
    return doc.save();
  }

  static String utf8Decode(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
}
