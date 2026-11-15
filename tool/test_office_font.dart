// 回归测试:办公文档(xlsx/docx)表格里的中文必须走中文字体,
// 不能回落到 pdf 包内置的 Helvetica(无中文字形,会渲染成方块)。
//
// 运行:dart run tool/test_office_font.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:pdf/widgets.dart' as pw;
import '../lib/office/office_to_pdf.dart';

var _checks = 0;

void check(bool ok, String label) {
  _checks++;
  if (!ok) throw StateError('FAIL: $label');
  print('PASS: $label');
}

void _add(Archive arc, String name, String text) {
  final data = utf8.encode(text);
  arc.addFile(ArchiveFile(name, data.length, data));
}

/// 构造一个含 4 列中文表头 + 中文数据的 xlsx(与用户截图场景一致)
Uint8List makeXlsx() {
  final arc = Archive();
  _add(
    arc,
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
  );
  _add(
    arc,
    'xl/sharedStrings.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<si><t>姓名</t></si><si><t>部门</t></si>'
        '<si><t>打印份数</t></si><si><t>备注</t></si>'
        '<si><t>张三</t></si><si><t>技术部</t></si>'
        '<si><t>2</t></si><si><t>中文测试</t></si></sst>',
  );
  _add(
    arc,
    'xl/worksheets/sheet1.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>'
        '<row r="1">'
        '<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>'
        '<c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c>'
        '</row>'
        '<row r="2">'
        '<c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c>'
        '<c r="C2" t="s"><v>6</v></c><c r="D2" t="s"><v>7</v></c>'
        '</row>'
        '</sheetData></worksheet>',
  );
  return Uint8List.fromList(ZipEncoder().encode(arc) as List<int>);
}

Uint8List makeDocx() {
  final arc = Archive();
  _add(
    arc,
    'word/document.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>中文标题</w:t></w:r></w:p>'
        '<w:tbl><w:tr>'
        '<w:tc><w:p><w:r><w:t>姓名</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>部门</w:t></w:r></w:p></w:tc>'
        '</w:tr><w:tr>'
        '<w:tc><w:p><w:r><w:t>李四</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>财务部</w:t></w:r></w:p></w:tc>'
        '</w:tr></w:tbl></w:body></w:document>',
  );
  return Uint8List.fromList(ZipEncoder().encode(arc) as List<int>);
}

int countToken(Uint8List pdf, String token) =>
    token.allMatches(latin1.decode(pdf, allowInvalid: true)).length;

Future<void> main() async {
  final xlsx = makeXlsx();
  final docx = makeDocx();

  // ---- 对照:未注入中文字体时,pdf 包必然使用内置 Helvetica ----
  final before = await OfficeToPdf.xlsxToPdf(xlsx);
  final helveticaBefore = countToken(before, '/Helvetica');
  print('未注入字体: ${before.length} B, /Helvetica x $helveticaBefore');
  check(before.isNotEmpty && before.length > 500, 'xlsx → PDF 正常生成');
  check(helveticaBefore > 0, '对照组:未注入字体时确实回落到 Helvetica');

  // ---- 注入开源中文字体 ----
  final fontFile = File(
      '${Directory.current.path}${Platform.pathSeparator}assets${Platform.pathSeparator}fonts${Platform.pathSeparator}DroidSansFallbackFull.ttf');
  final fontBytes = await fontFile.readAsBytes();
  OfficeToPdf.setFont(pw.Font.ttf(ByteData.sublistView(fontBytes)));
  check(OfficeToPdf.hasCjkFont, '中文字体已注入(Droid Sans Fallback)');

  final after = await OfficeToPdf.xlsxToPdf(xlsx);
  final helveticaAfter = countToken(after, '/Helvetica');
  final fontFile2 = countToken(after, '/FontFile2');
  print('注入字体后: ${after.length} B, /Helvetica x $helveticaAfter, '
      '/FontFile2 x $fontFile2');
  check(fontFile2 >= 1, 'PDF 内嵌了 TrueType 中文字体子集(/FontFile2)');
  // 只用到少量汉字,子集很小(实测约 1.5 KB),所以只断言体积有增长;
  // 「确实内嵌」由上面的 /FontFile2 断言保证
  check(after.length > before.length + 300, '中文字形子集嵌入后 PDF 体积增大');
  check(helveticaAfter == 0, 'xlsx 表格首行中文不再回落 Helvetica(不会变方块)');

  // ---- docx 表格同样不得回落 ----
  final docxPdf = await OfficeToPdf.docxToPdf(docx);
  final docxHelvetica = countToken(docxPdf, '/Helvetica');
  print('docx: ${docxPdf.length} B, /Helvetica x $docxHelvetica');
  check(countToken(docxPdf, '/FontFile2') >= 1, 'docx 表格内嵌中文字体子集');
  check(docxHelvetica == 0, 'docx 表格中文不再回落 Helvetica');

  print('ALL_OFFICE_FONT_TESTS_PASS ($_checks 项)');
}
