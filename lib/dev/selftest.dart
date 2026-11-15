// Windows 原生 exe 端到端自检(通过环境变量 PUREPRINT_SELFTEST=1 触发)
// 目的:在真实 Windows 桌面运行时验证 pdfx 渲染、多文件合并、拼版、IPP 打印
// 结果写入 PUREPRINT_OUT 目录下的 selftest_result.txt,不依赖控制台输出
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart' as pdfcore;
import 'package:pdf/widgets.dart' as pw;

import '../ipp/ipp_client.dart';
import '../office/office_to_pdf.dart';
import '../print/print_service.dart';

Future<Uint8List> _makeTestPdf(String tag, int pages) async {
  final doc = pw.Document();
  for (var i = 1; i <= pages; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: pdfcore.PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.all(18),
              color: pdfcore.PdfColors.blue700,
              child: pw.Center(
                child: pw.Text(
                  '$tag  -  PAGE $i',
                  style: pw.TextStyle(
                    color: pdfcore.PdfColors.white,
                    fontSize: 44,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 24),
            pw.Text(
              'PUREPRINT WINDOWS SELFTEST',
              style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Document $tag / Page $i of $pages',
              style: const pw.TextStyle(fontSize: 20),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'If you can read this, rendering + layout + IPP printing all work.',
              style: const pw.TextStyle(fontSize: 14),
            ),
            pw.SizedBox(height: 24),
            pw.Container(
              height: 220,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 4, color: pdfcore.PdfColors.red),
              ),
              child: pw.Center(
                child: pw.Text(
                  '[$tag-$i]',
                  style: pw.TextStyle(
                    fontSize: 70,
                    color: pdfcore.PdfColors.red,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  return doc.save();
}

Future<String> _makeTestDocx(Directory out) async {
  const xml =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>'
      '<w:p><w:r><w:t>PUREPRINT OFFICE DOCX SELFTEST</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>Second paragraph, Chinese font fallback check.</w:t></w:r></w:p>'
      '</w:body></w:document>';
  final arc = Archive();
  final data = utf8.encode(xml);
  arc.addFile(ArchiveFile('word/document.xml', data.length, data));
  final bytes = ZipEncoder().encode(arc);
  final f = File('${out.path}${Platform.pathSeparator}office_test.docx');
  await f.writeAsBytes(bytes);
  return f.path;
}

/// 生成含 4 列中文表头的 xlsx(复现用户截图里中文变方块的场景)
Future<String> _makeTestXlsx(Directory out) async {
  final arc = Archive();
  void add(String name, String text) {
    final data = utf8.encode(text);
    arc.addFile(ArchiveFile(name, data.length, data));
  }

  add(
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
  );
  add(
    'xl/sharedStrings.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<si><t>姓名</t></si><si><t>部门</t></si>'
        '<si><t>打印份数</t></si><si><t>备注</t></si>'
        '<si><t>张三</t></si><si><t>技术部</t></si>'
        '<si><t>2</t></si><si><t>中文测试</t></si></sst>',
  );
  add(
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
  final f = File('${out.path}${Platform.pathSeparator}office_test.xlsx');
  await f.writeAsBytes(ZipEncoder().encode(arc));
  return f.path;
}

Future<void> runWindowsSelfTest() async {
  final env = Platform.environment;
  final outPath =
      env['PUREPRINT_OUT'] ??
      '${env['TEMP'] ?? env['USERPROFILE'] ?? '.'}${Platform.pathSeparator}pure_print_selftest';
  final out = Directory(outPath);
  await out.create(recursive: true);
  final log = StringBuffer();
  var ok = true;

  void p(String s) => log.writeln(s);
  void fail(String s) {
    ok = false;
    p('FAIL: $s');
  }

  p('=== 纯净打印 Windows 端到端自检 ===');
  p('时间: ${DateTime.now()}');
  p('输出目录: ${out.path}');
  p('平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');

  Future<void> flush() async {
    await File('${out.path}${Platform.pathSeparator}selftest_result.txt')
        .writeAsString(log.toString());
  }

  try {
    // ---------- 1. 生成两个 3 页 PDF,验证多文件合并 ----------
    final docA = File('${out.path}${Platform.pathSeparator}docA.pdf');
    final docB = File('${out.path}${Platform.pathSeparator}docB.pdf');
    await docA.writeAsBytes(await _makeTestPdf('A', 3));
    await docB.writeAsBytes(await _makeTestPdf('B', 3));
    final paths = [docA.path, docB.path];
    p('OK: 生成 2 个各 3 页的测试 PDF');

    final service = PrintService();

    // ---------- 2. 版式场景(预览与打印共用同一函数) ----------
    final scenarios = <String, PrintOptions>{
      '1up': PrintOptions(),
      '2up': PrintOptions()
        ..rows = 1
        ..cols = 2,
      '4up_bordered': PrintOptions()
        ..rows = 2
        ..cols = 2
        ..marginMm = 8
        ..gapMm = 4
        ..sheetBorder = true,
      '8up': PrintOptions()
        ..rows = 2
        ..cols = 4,
      'landscape_cover': PrintOptions()
        ..orientation = 'landscape'
        ..rows = 1
        ..cols = 2
        ..fit = 'cover'
        ..scalePct = 110,
      'odd_reverse': PrintOptions()
        ..parity = 'odd'
        ..reverse = true
        ..rows = 1
        ..cols = 2,
      'even': PrintOptions()
        ..parity = 'even'
        ..rows = 1
        ..cols = 2,
      'a3_custom_grid': PrintOptions()
        ..paper = 'a3'
        ..rows = 3
        ..cols = 2
        ..marginMm = 12
        ..gapMm = 6,
      'custom_paper': PrintOptions()
        ..paper = 'custom'
        ..paperWmm = 180
        ..paperHmm = 250
        ..rows = 1
        ..cols = 2,
    };

    final expected = <String, int>{
      '1up': 6,
      '2up': 3,
      '4up_bordered': 2,
      '8up': 1,
      'landscape_cover': 3,
      'odd_reverse': 2,
      'even': 2,
      'a3_custom_grid': 1,
      'custom_paper': 3,
    };

    for (final e in scenarios.entries) {
      try {
        final sheets = await service.buildSheetsFromPaths(paths, e.value);
        final want = expected[e.key]!;
        if (sheets.length != want) {
          fail('${e.key} 应得 $want 张纸,实际 ${sheets.length} 张');
        }
        for (var i = 0; i < sheets.length; i++) {
          await File(
            '${out.path}${Platform.pathSeparator}${e.key}_sheet${i + 1}.jpg',
          ).writeAsBytes(sheets[i]);
        }
        final l = e.value.sheetLayout;
        final (cw, ch) = l.canvasSize;
        p(
          'OK: ${e.key.padRight(18)} ${sheets.length} 张 / 画布 $cw×${ch}px / '
          '格子 ${l.cellSize.$1}×${l.cellSize.$2}px / 首张 ${sheets.first.length} B',
        );
      } catch (err) {
        fail('${e.key} 排版异常: $err');
      }
      await flush();
    }

    // ---------- 3. 纯逻辑:页码 / 奇偶 / 逆序 ----------
    final r1 = parsePageRange('1-3,5', 6);
    if (r1.join(',') != '1,2,3,5') fail('parsePageRange 结果异常: $r1');
    final r2 = filterParity([1, 2, 3, 4, 5, 6], 'even');
    if (r2.join(',') != '2,4,6') fail('filterParity even 异常: $r2');
    p('OK: 页码范围 / 奇偶页 / 逆序逻辑');

    // ---------- 3b. 拖入文件整理(真实文件路径 / 文件夹 / 去重) ----------
    try {
      final dropDir = Directory(
        '${out.path}${Platform.pathSeparator}drop_test',
      );
      await dropDir.create(recursive: true);
      final inDirA = File('${dropDir.path}${Platform.pathSeparator}c.PDF');
      final inDirB = File('${dropDir.path}${Platform.pathSeparator}d.txt');
      await inDirA.writeAsBytes(await docA.readAsBytes());
      await inDirB.writeAsString('not printable');
      final sub = Directory('${dropDir.path}${Platform.pathSeparator}sub');
      await sub.create();
      await File('${sub.path}${Platform.pathSeparator}e.png')
          .writeAsBytes([0x89, 0x50, 0x4E, 0x47]);

      final m = mergeDroppedPaths([], [docA.path, dropDir.path, inDirB.path]);
      // docA.pdf + 文件夹内 c.PDF / sub/e.png,跳过 d.txt
      if (m.added.length != 3) {
        fail('拖入应新增 3 个文件,实际 ${m.added.length}: ${m.added}');
      }
      if (m.expandedDirs != 1) {
        fail('文件夹展开计数异常: ${m.expandedDirs}');
      }
      if (m.skipped.isEmpty) {
        fail('不支持的 .txt 未被跳过');
      }
      if (m.merged.first != docA.path) {
        fail('拖入顺序未保持: ${m.merged.first}');
      }
      // 重复拖入(含大小写/斜杠差异)应全部去重
      final again = mergeDroppedPaths(m.merged, [
        docA.path.toUpperCase().replaceAll('/', '\\'),
        inDirA.path,
      ]);
      if (again.added.isNotEmpty) fail('重复拖入未去重: ${again.added}');
      p('OK: 拖入整理 → ${m.summary};重复拖入去重正常');
    } catch (err) {
      fail('拖入整理异常: $err');
    }
    await flush();

    // ---------- 4. Office 文档转换(含中文表头回归) ----------
    try {
      if (!OfficeToPdf.hasCjkFont) fail('中文字体未注入,办公文档中文会变方块');
      final docx = await _makeTestDocx(out);
      final officeSheets = await service.buildSheetsFromPaths([
        docx,
      ], PrintOptions());
      await File('${out.path}${Platform.pathSeparator}office_sheet1.jpg')
          .writeAsBytes(officeSheets.first);
      p('OK: docx → PDF → 拼版,共 ${officeSheets.length} 张');

      final xlsx = await _makeTestXlsx(out);
      final xlsxSheets = await service.buildSheetsFromPaths([
        xlsx,
      ], PrintOptions());
      await File('${out.path}${Platform.pathSeparator}office_xlsx_sheet1.jpg')
          .writeAsBytes(xlsxSheets.first);
      p(
        'OK: xlsx 中文表头 → PDF → 拼版,共 ${xlsxSheets.length} 张 '
        '(请目视核对 office_xlsx_sheet1.jpg,中文不得为方块)',
      );
    } catch (err) {
      fail('Office 转换异常: $err');
    }
    await flush();

    // ---------- 5. 导出 PDF(系统打印用的同一路径) ----------
    try {
      final s = await service.buildSheetsFromPaths(
        paths,
        scenarios['4up_bordered']!,
      );
      final pdfBytes = await service.sheetsToPdf(s, scenarios['4up_bordered']!);
      await File('${out.path}${Platform.pathSeparator}output_4up.pdf')
          .writeAsBytes(pdfBytes);
      p('OK: 拼版结果打包为 PDF (${pdfBytes.length} B)');
    } catch (err) {
      fail('PDF 打包异常: $err');
    }
    await flush();

    // ---------- 5b. 多页预览性能基准 + 流式管线正确性 ----------
    // 旧版预览 = 全质量 buildSheetsFromPaths(200dpi 全页数),故 full 即为优化前基线
    try {
      final perfPdf = File('${out.path}${Platform.pathSeparator}perf_24p.pdf');
      await perfPdf.writeAsBytes(await _makeTestPdf('PERF', 24));

      final tFull = DateTime.now();
      final full = await service.buildSheetsFromPaths([
        perfPdf.path,
      ], PrintOptions());
      final fullMs = DateTime.now().difference(tFull).inMilliseconds;

      var firstSheetMs = -1;
      final callbacks = <int>[];
      final tPrev = DateTime.now();
      final prev = await service.buildPreviewSheets(
        [perfPdf.path],
        PrintOptions(),
        onSheet: (i, jpeg, total) {
          // 首张到达即视为「用户看到预览」的时刻
          if (i == 0) {
            firstSheetMs = DateTime.now().difference(tPrev).inMilliseconds;
          }
          callbacks.add(i);
        },
      );
      final prevMs = DateTime.now().difference(tPrev).inMilliseconds;

      int sum(List<Uint8List> list) =>
          list.fold<int>(0, (s, b) => s + b.length);
      final fullKb = sum(full) ~/ 1024;
      final prevKb = sum(prev.sheets) ~/ 1024;
      p(
        'PERF: 24 页 A4 / 200dpi 全质量 ${fullMs}ms · ${full.length} 张 · ${fullKb}KB'
        ' (≈ 优化前预览耗时)',
      );
      p(
        'PERF: 24 页 A4 / ${prev.dpi}dpi 预览   首张可见 ${firstSheetMs}ms · '
        '全部 ${prevMs}ms · ${prev.sheets.length} 张 · ${prevKb}KB',
      );
      if (fullMs > 0 && firstSheetMs >= 0) {
        p(
          'PERF: 首屏相对优化前 = '
          '${(firstSheetMs / fullMs).toStringAsFixed(3)} ×',
        );
      }

      await File(
        '${out.path}${Platform.pathSeparator}preview_${prev.dpi}dpi_sheet1.jpg',
      ).writeAsBytes(prev.sheets.first);
      if (callbacks.length != prev.sheets.length) {
        fail('增量回调 ${callbacks.length} 次,与成品 ${prev.sheets.length} 张不一致');
      }
      if (firstSheetMs < 0) fail('未收到首张预览回调');
      if (firstSheetMs >= prevMs) fail('首张回调未早于整体完成');
      p('OK: 增量预览首张先行(${firstSheetMs}ms),共回调 ${callbacks.length} 次');
      if (full.length != 24) fail('全质量应输出 24 张,实际 ${full.length}');
      if (prev.totalSheets != 24) fail('预览总张数应为 24,实际 ${prev.totalSheets}');
      if (prev.sheets.length != kMaxPreviewSheets) {
        fail('预览应截断到 $kMaxPreviewSheets 张,实际 ${prev.sheets.length}');
      }
      if (!prev.truncated) fail('预览截断标记缺失');
      if (prev.sheets.first.length >= full.first.length) {
        fail('预览单张 JPEG 未明显小于全质量单张');
      }
      p('OK: 多页预览限量($kMaxPreviewSheets 张)且单张体积下降');

      // 页码范围 + 奇偶 + 网格在流式管线中必须仍然生效
      final rangedOpts = PrintOptions()
        ..pageRange = '3-6'
        ..parity = 'even'
        ..rows = 1
        ..cols = 2;
      final ranged = await service.buildPreviewSheets([
        perfPdf.path,
      ], rangedOpts);
      final rangedFull = await service.buildSheetsFromPaths([
        perfPdf.path,
      ], rangedOpts);
      if (ranged.totalSheets != 1 ||
          ranged.sheets.length != 1 ||
          rangedFull.length != 1) {
        fail(
          '流式管线的页码/奇偶/网格筛选异常: '
          'ranged=${ranged.sheets.length}/${ranged.totalSheets}, full=${rangedFull.length}',
        );
      }
      p('OK: 流式版式仍正确应用页码范围 / 奇偶页 / 网格');

      // 取消:进行中的预览应能立即退出,避免设置变更后的过期任务继续耗 CPU
      var didCancel = false;
      try {
        await service.buildPreviewSheets(
          [perfPdf.path],
          PrintOptions(),
          cancelled: () => true,
        );
      } on PreviewCancelledException {
        didCancel = true;
      }
      if (!didCancel) fail('预览取消开关未生效');
      p('OK: 预览可取消,过期任务不会继续占用 CPU');
    } catch (err) {
      fail('多页预览基准异常: $err');
    }
    await flush();

    // ---------- 6. 实机打印(真实出纸,只打 1 张) ----------
    // 开源版本不内置任何私有网络地址,目标一律由环境变量注入
    final host = env['PUREPRINT_HOST'] ?? '';
    final port = int.tryParse(env['PUREPRINT_PORT'] ?? '631') ?? 631;
    if (host.isEmpty) {
      p(
        'SKIP: 未设置 PUREPRINT_HOST,跳过实机打印探测'
        '(示例: PUREPRINT_HOST=192.168.1.100)',
      );
    } else {
      final printer = IppPrinter(host, port: port, name: '纯净打印自检');
      p('--- 实机打印目标: $host:$port ---');
      try {
        final (caps, ep) = await service.probe(printer);
        p(
          'OK: Get-Printer-Attributes → ${caps.makeAndModel.isEmpty ? ep.host : caps.makeAndModel} / ${ep.endpoint}',
        );
        final state = await service.probeState(printer);
        p('OK: 设备状态 → ${state.summary}');

        if (env['PUREPRINT_SKIP_PRINT'] == '1') {
          p('SKIP: 实机出纸(PUREPRINT_SKIP_PRINT=1);IPP 打印链路本次未改动');
        } else {
          // PUREPRINT_PRINT_XLSX=1 时改打中文表头测试页,用于实机核对中文渲染
          final useXlsx = env['PUREPRINT_PRINT_XLSX'] == '1';
          final printPaths = useXlsx
              ? ['${out.path}${Platform.pathSeparator}office_test.xlsx']
              : paths;
          final printOpts = useXlsx
              ? PrintOptions()
              : scenarios['4up_bordered']!;
          // useXlsx 时不传 sheets,验证 UI 优化后的真实打印路径:
          // printFiles 内部按 renderDpi 全分辨率重新渲染全部纸张(此处恰好 1 张)
          List<Uint8List>? cached;
          if (!useXlsx) {
            final all = await service.buildSheetsFromPaths(
              paths,
              scenarios['4up_bordered']!,
            );
            cached = [all.first]; // 只打第一张,避免浪费纸
          }
          final msg = await service.printFiles(
            printer,
            printPaths,
            printOpts,
            sheets: cached,
            onProgress: p,
          );
          p('PRINT_RESULT: $msg');
          p(
            useXlsx
                ? '>>> 已提交 1 张全分辨率中文 xlsx 表头页(未复用预览成品),请确认中文不是方块'
                : '>>> 已提交 1 张有内容的 2x2 拼版测试页,请查看打印机出纸',
          );
        }
      } catch (err) {
        fail('实机打印失败: $err');
      }
    }
  } catch (err, st) {
    fail('自检整体异常: $err\n$st');
  }

  p('');
  p(ok ? 'SELFTEST_OK' : 'SELFTEST_FAILED');
  await flush();
}
