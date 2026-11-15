// 打印编排服务:任意内容 → 页图像 → 客户端拼版 → 打印机
// 对齐 Free2Convert「PDF 多页合一」:多个文档合并成连续排版
// 预览与打印共用 buildSheetsFromPages(),保证所见即所得
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' as pdfcore;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../ipp/ipp_client.dart';
import '../office/office_to_pdf.dart';
import 'file_types.dart';
import 'page_range.dart';
import 'sheet_layout.dart';

export 'drop_files.dart';
export 'file_types.dart';
export 'page_range.dart';
export 'sheet_layout.dart';

// ---------------- 流式排版管线 ----------------
// 旧实现把整份文档的每一页都解码成 img.Image 常驻内存,再在主 isolate 同步拼版:
// 内存占用 O(页数) × 单页位图(200dpi A4 约 11.6 MB),且 UI 线程被位图运算独占。
// 新实现:页引用(共享 PDF 字节) → 按需逐页渲染成 JPEG 字节 → 后台 isolate 拼版
// → 主 isolate 只保留最终 JPEG。峰值内存 O(每张纸的页数),UI 全程可响应。

/// 预览专用光栅化分辨率。版式几何与打印完全一致,只降低像素密度。
/// 72dpi 的 A4 约 595×842px,已远高于预览控件的显示尺寸,但比 200dpi 少约 7.7 倍像素。
const int kPreviewDpi = 72;

/// 预览 JPEG 质量:仅用于屏幕显示,不影响打印成品
const int kPreviewJpegQuality = 70;

/// 预览最多生成的纸张数。打印始终输出全部页数。
const int kMaxPreviewSheets = 20;

/// 增量预览回调:(第几张(0 起), 该张 JPEG, 本次计划生成的总张数)
typedef PreviewSheetCallback = void Function(
  int index,
  Uint8List jpeg,
  int total,
);

/// 预览被主动取消(用户重新生成、修改设置或退出页面)
class PreviewCancelledException implements Exception {
  const PreviewCancelledException();
  @override
  String toString() => '预览已取消';
}

class PreviewResult {
  final List<Uint8List> sheets;
  final int totalSheets;
  final bool truncated;
  final int dpi;

  const PreviewResult({
    required this.sheets,
    required this.totalSheets,
    required this.truncated,
    required this.dpi,
  });

  String get hint => truncated
      ? '仅预览前 ${sheets.length} / $totalSheets 张(打印输出全部 $totalSheets 张)'
      : '共 $totalSheets 张';
}

/// 单个逻辑页的引用:只持有文档字节与页码,不持有解码后的位图。
/// 同一文档的所有页共享同一份 bytes,不会随页数复制。
class _PageRef {
  final Uint8List bytes;
  final int page; // PDF 内 1 起;照片固定为 0
  final bool isPhoto;
  final String source;

  const _PageRef(this.bytes, this.page, this.isPhoto, this.source);
}

/// 轻量第一遍:统计页数,不做任何光栅化
Future<List<_PageRef>> _collectPageRefs(
  List<String> paths,
  void Function(String)? onProgress,
) async {
  final refs = <_PageRef>[];
  for (final path in paths) {
    final name = path.split(Platform.pathSeparator).last;
    final type = contentTypeOf(path);
    if (type == null) throw ArgumentError('暂不支持的文件格式: $name');
    final raw = await File(path).readAsBytes();
    if (type == ContentType.photo) {
      refs.add(_PageRef(raw, 0, true, path));
      continue;
    }
    final bytes = type == ContentType.pdf
        ? raw
        : await OfficeToPdf.convert(path);
    final doc = await pdfx.PdfDocument.openData(bytes);
    int count;
    try {
      count = doc.pagesCount;
    } finally {
      await doc.close();
    }
    for (var i = 1; i <= count; i++) {
      refs.add(_PageRef(bytes, i, false, path));
    }
    onProgress?.call('$name: $count 页');
  }
  if (refs.isEmpty) throw ArgumentError('所选文档没有可打印的页');
  return refs;
}

/// 只渲染当前需要的那一页,返回压缩后的 JPEG 字节(位图不留在主 isolate)
Future<Uint8List> _renderPageJpeg(
  _PageRef ref,
  double scale,
  int quality,
  Map<String, pdfx.PdfDocument> docs,
) async {
  if (ref.isPhoto) return ref.bytes;
  var doc = docs[ref.source];
  if (doc == null) {
    doc = await pdfx.PdfDocument.openData(ref.bytes);
    docs[ref.source] = doc;
  }
  final page = await doc.getPage(ref.page);
  try {
    final rendered = await page.render(
      width: page.width * scale,
      height: page.height * scale,
      format: pdfx.PdfPageImageFormat.jpeg,
      quality: quality,
      backgroundColor: '#FFFFFF',
    );
    if (rendered == null) throw Exception('第 ${ref.page} 页渲染失败');
    return Uint8List.fromList(rendered.bytes);
  } finally {
    await page.close();
  }
}

/// 在后台 isolate 完成「解码 + 缩放 + 合成 + JPEG 编码」。
/// 主 isolate 不再承担任何 CPU 密集型位图运算。
/// 跨 isolate 只传 Uint8List 与原始类型,保证 AOT 运行时消息一定可传递。
Future<Uint8List> _composeInIsolate(List<Uint8List> tiles, SheetLayout layout) {
  final params = <String, Object?>{
    'orientation': layout.orientation,
    'marginMm': layout.marginMm,
    'gapMm': layout.gapMm,
    'rows': layout.rows,
    'cols': layout.cols,
    'fit': layout.fit,
    'scalePct': layout.scalePct,
    'offsetPct': layout.offsetPct,
    'border': layout.border,
    'paperWmm': layout.paperWmm,
    'paperHmm': layout.paperHmm,
    'dpi': layout.dpi,
  };
  return Isolate.run(() => _composeFromParams(tiles, params));
}

Uint8List _composeFromParams(List<Uint8List> tiles, Map<String, Object?> p) {
  final images = <img.Image>[];
  for (final b in tiles) {
    final im = img.decodeImage(b);
    if (im == null) throw FormatException('拼版页图像解码失败');
    images.add(im);
  }
  final layout = SheetLayout(
    orientation: p['orientation']! as String,
    marginMm: p['marginMm']! as double,
    gapMm: p['gapMm']! as double,
    rows: p['rows']! as int,
    cols: p['cols']! as int,
    fit: p['fit']! as String,
    scalePct: p['scalePct']! as double,
    offsetPct: p['offsetPct']! as double,
    border: p['border']! as bool,
    paperWmm: p['paperWmm']! as double,
    paperHmm: p['paperHmm']! as double,
    dpi: p['dpi']! as int,
  );
  return composeSheet(images, layout);
}

typedef _SheetBatch = ({
  List<Uint8List> sheets,
  int totalSheets,
  bool truncated,
});

/// 预览与打印共用的唯一流式排版实现。
/// [maxSheets] 为空表示输出全部(打印);非空表示只生成前 N 张(预览)。
Future<_SheetBatch> _buildSheetsStreaming(
  List<String> paths,
  PrintOptions o, {
  required int dpi,
  required int jpegQuality,
  int? maxSheets,
  bool Function()? cancelled,
  void Function(String)? onProgress,
  PreviewSheetCallback? onSheet,
}) async {
  final refs = await _collectPageRefs(paths, onProgress);
  var indices = parsePageRange(o.pageRange, refs.length);
  indices = filterParity(indices, o.parity);
  if (indices.isEmpty) {
    throw ArgumentError('按所选页码范围与奇偶设置,没有可打印的页');
  }
  if (o.reverse) indices = indices.reversed.toList();

  final per = math.max(1, o.rows * o.cols);
  final totalSheets = (indices.length + per - 1) ~/ per;
  final limit = maxSheets == null
      ? totalSheets
      : math.min(totalSheets, maxSheets);
  final layout = (o.copy()..renderDpi = dpi).sheetLayout;
  final scale = dpi / 72.0;
  final docs = <String, pdfx.PdfDocument>{};
  final sheets = <Uint8List>[];

  try {
    for (var s = 0; s < limit; s++) {
      if (cancelled?.call() ?? false) throw const PreviewCancelledException();
      final tiles = <Uint8List>[];
      for (var k = 0; k < per; k++) {
        if (cancelled?.call() ?? false) throw const PreviewCancelledException();
        final pos = s * per + k;
        if (pos >= indices.length) break;
        tiles.add(
          await _renderPageJpeg(
            refs[indices[pos] - 1],
            scale,
            jpegQuality,
            docs,
          ),
        );
      }
      final jpeg = await _composeInIsolate(tiles, layout);
      sheets.add(jpeg);
      // 首张完成即刻回调,UI 可以马上显示,不必等整份文档生成完
      onSheet?.call(s, jpeg, limit);
      if ((s + 1) % 5 == 0 || s + 1 == limit) {
        onProgress?.call('排版进度 ${s + 1} / $limit 张');
      }
      // 主动让出事件循环,保证 UI 可以绘制进度并响应取消
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    for (final d in docs.values) {
      await d.close();
    }
  }
  onProgress?.call(
    '排版完成: ${indices.length} 页 → $totalSheets 张纸'
    '${limit < totalSheets ? " (本次生成前 $limit 张)" : ""}',
  );
  return (
    sheets: sheets,
    totalSheets: totalSheets,
    truncated: limit < totalSheets,
  );
}

class PrintOptions {
  int copies = 1;
  bool color = true;
  bool duplex = false;
  int renderDpi = 200;
  String pageRange = '';
  String parity = 'all'; // all / odd / even
  bool reverse = false;

  // ---- 版式(对齐网页工具) ----
  String paper = 'a4'; // a4/a3/a5/letter/photo4x6/custom
  double paperWmm = 210, paperHmm = 297; // 自定义纸张
  String orientation = 'portrait';
  int rows = 1, cols = 1; // 自定义网格
  double marginMm = 0, gapMm = 0;
  String fit = 'contain'; // contain / cover
  double scalePct = 100, offsetPct = 0;
  bool sheetBorder = false;

  PrintOptions copy() => PrintOptions()
    ..copies = copies
    ..color = color
    ..duplex = duplex
    ..renderDpi = renderDpi
    ..pageRange = pageRange
    ..parity = parity
    ..reverse = reverse
    ..paper = paper
    ..paperWmm = paperWmm
    ..paperHmm = paperHmm
    ..orientation = orientation
    ..rows = rows
    ..cols = cols
    ..marginMm = marginMm
    ..gapMm = gapMm
    ..fit = fit
    ..scalePct = scalePct
    ..offsetPct = offsetPct
    ..sheetBorder = sheetBorder;

  (double, double) get paperMm {
    if (paper == 'custom') return (paperWmm, paperHmm);
    final p = kPaperSizesMm[paper] ?? kPaperSizesMm['a4']!;
    return (p[0], p[1]);
  }

  String get ippMedia => switch (paper) {
    'a3' => 'iso_a3_297x420mm',
    'a5' => 'iso_a5_148x210mm',
    'letter' => 'na_letter_8.5x11in',
    'photo4x6' => 'na_index-4x6_4x6in',
    _ => 'iso_a4_210x297mm',
  };

  SheetLayout get sheetLayout {
    final (w, h) = paperMm;
    return SheetLayout(
      orientation: orientation,
      marginMm: marginMm,
      gapMm: gapMm,
      rows: rows,
      cols: cols,
      fit: fit,
      scalePct: scalePct,
      offsetPct: offsetPct,
      border: sheetBorder,
      paperWmm: w,
      paperHmm: h,
      dpi: renderDpi,
    );
  }

  String get layoutSummary {
    final (w, h) = paperMm;
    final pw = orientation == 'landscape' ? h : w;
    final ph = orientation == 'landscape' ? w : h;
    return '${paper == 'custom' ? '自定义' : (kPaperLabels[paper] ?? paper)} '
        '${pw.toStringAsFixed(0)}×${ph.toStringAsFixed(0)}mm · '
        '${orientation == 'landscape' ? '横版' : '竖版'} · '
        '$rows×$cols (${rows * cols} 版/张) · '
        '${fit == 'cover' ? '铺满裁切' : '完整显示'} · '
        '边距${marginMm.toStringAsFixed(0)}mm/间距${gapMm.toStringAsFixed(0)}mm · '
        '缩放${scalePct.toStringAsFixed(0)}% · '
        '位置${offsetPct.toStringAsFixed(0)}%'
        '${sheetBorder ? ' · 边框' : ''}';
  }

  Map<String, dynamic> toJson() => {
    'copies': copies,
    'color': color,
    'duplex': duplex,
    'renderDpi': renderDpi,
    'pageRange': pageRange,
    'parity': parity,
    'reverse': reverse,
    'paper': paper,
    'paperWmm': paperWmm,
    'paperHmm': paperHmm,
    'orientation': orientation,
    'rows': rows,
    'cols': cols,
    'marginMm': marginMm,
    'gapMm': gapMm,
    'fit': fit,
    'scalePct': scalePct,
    'offsetPct': offsetPct,
    'sheetBorder': sheetBorder,
  };

  /// 兼容旧版本保存的 media / margin / pagesPerSheet 字段
  static PrintOptions fromJson(Map<String, dynamic> m) {
    num n(String k, num d) => (m[k] as num?) ?? d;
    String s(String k, String d) => m[k] as String? ?? d;
    bool b(String k, bool d) => m[k] as bool? ?? d;
    final o = PrintOptions()
      ..copies = n('copies', 1).toInt()
      ..color = b('color', true)
      ..duplex = b('duplex', false)
      ..renderDpi = n('renderDpi', 200).toInt()
      ..pageRange = s('pageRange', '')
      ..parity = s('parity', 'all')
      ..reverse = b('reverse', false)
      ..paper = s('paper', 'a4')
      ..paperWmm = n('paperWmm', 210).toDouble()
      ..paperHmm = n('paperHmm', 297).toDouble()
      ..orientation = s('orientation', 'portrait')
      ..rows = n('rows', 1).toInt()
      ..cols = n('cols', 1).toInt()
      ..marginMm = n('marginMm', 0).toDouble()
      ..gapMm = n('gapMm', 0).toDouble()
      ..fit = s('fit', 'contain')
      ..scalePct = n('scalePct', 100).toDouble()
      ..offsetPct = n('offsetPct', 0).toDouble()
      ..sheetBorder = b('sheetBorder', false);

    // ---- 旧字段迁移 ----
    if (!m.containsKey('paper') && m['media'] is String) {
      o.paper = switch (m['media'] as String) {
        'iso_a3_297x420mm' => 'a3',
        'iso_a5_148x210mm' => 'a5',
        'na_letter_8.5x11in' => 'letter',
        'na_index-4x6_4x6in' => 'photo4x6',
        _ => 'a4',
      };
    }
    if (!m.containsKey('marginMm') && m['margin'] is String) {
      o.marginMm = switch (m['margin'] as String) {
        'narrow' => 5,
        'normal' => 10,
        'wide' => 18,
        _ => 0,
      };
    }
    if (!m.containsKey('rows') && m['pagesPerSheet'] is num) {
      final (c, r) = gridFor((m['pagesPerSheet'] as num).toInt());
      o.rows = r;
      o.cols = c;
    }
    o.rows = o.rows.clamp(1, 8).toInt();
    o.cols = o.cols.clamp(1, 8).toInt();
    o.renderDpi = o.renderDpi.clamp(72, 600).toInt();
    return o;
  }
}

class PrintService {
  final IppClient _client = IppClient();

  Future<(PrinterCapabilities, IppPrinter)> probe(IppPrinter printer) =>
      _client.getCapabilities(printer);

  Future<PrinterStateInfo> probeState(IppPrinter printer) =>
      _client.getPrinterState(printer);

  /// 把多个文件(PDF / 办公文档 / 图片)按顺序渲染成连续的页图像
  Future<List<img.Image>> renderPages(
    List<String> paths,
    PrintOptions o, {
    void Function(String)? onProgress,
  }) async {
    final scale = o.renderDpi / 72.0;
    final pages = <img.Image>[];
    for (final path in paths) {
      final name = path.split(Platform.pathSeparator).last;
      final type = contentTypeOf(path);
      if (type == null) throw ArgumentError('暂不支持的文件格式: $name');
      if (type == ContentType.photo) {
        onProgress?.call('读取图片 $name ...');
        final im = img.decodeImage(await File(path).readAsBytes());
        if (im == null) throw FormatException('无法识别的图片: $name');
        pages.add(im);
        continue;
      }
      onProgress?.call('渲染 $name ...');
      final bytes = type == ContentType.pdf
          ? await File(path).readAsBytes()
          : await OfficeToPdf.convert(path);
      final doc = await pdfx.PdfDocument.openData(bytes);
      try {
        for (var i = 1; i <= doc.pagesCount; i++) {
          final page = await doc.getPage(i);
          try {
            final rendered = await page.render(
              width: page.width * scale,
              height: page.height * scale,
              format: pdfx.PdfPageImageFormat.jpeg,
              quality: 92,
              backgroundColor: '#FFFFFF',
            );
            if (rendered == null) throw Exception('$name 第 $i 页渲染失败');
            final im = img.decodeJpg(rendered.bytes);
            if (im == null) throw Exception('$name 第 $i 页图像解码失败');
            pages.add(im);
          } finally {
            await page.close();
          }
        }
      } finally {
        await doc.close();
      }
    }
    if (pages.isEmpty) throw ArgumentError('所选文档没有可打印的页');
    onProgress?.call('已载入 ${paths.length} 个文件 / 共 ${pages.length} 页');
    return pages;
  }

  /// 页图像 → 按页码/奇偶/逆序筛选 → 按网格拼成一张张纸
  /// 这是预览与打印唯一的排版入口
  List<Uint8List> buildSheetsFromPages(
    List<img.Image> pages,
    PrintOptions o, {
    void Function(String)? onProgress,
  }) {
    var indices = parsePageRange(o.pageRange, pages.length);
    indices = filterParity(indices, o.parity);
    if (indices.isEmpty) {
      throw ArgumentError('按所选页码范围与奇偶设置,没有可打印的页');
    }
    if (o.reverse) indices = indices.reversed.toList();

    final per = math.max(1, o.rows * o.cols);
    final layout = o.sheetLayout;
    final sheets = <Uint8List>[];
    for (var i = 0; i < indices.length; i += per) {
      final group = indices.sublist(i, math.min(i + per, indices.length));
      final tiles = [for (final n in group) pages[n - 1]];
      sheets.add(composeSheet(tiles, layout));
    }
    onProgress?.call(
      '排版完成: ${indices.length} 页 → ${sheets.length} 张纸 '
      '(${o.rows}×${o.cols} 网格)',
    );
    return sheets;
  }

  /// 全分辨率、全页数输出:打印与导出 PDF 使用。
  /// 同样走流式管线,但不受预览张数上限限制,质量保持 renderDpi。
  Future<List<Uint8List>> buildSheetsFromPaths(
    List<String> paths,
    PrintOptions o, {
    void Function(String)? onProgress,
    bool Function()? cancelled,
  }) async {
    final batch = await _buildSheetsStreaming(
      paths,
      o,
      dpi: o.renderDpi,
      jpegQuality: 92,
      maxSheets: null,
      cancelled: cancelled,
      onProgress: onProgress,
    );
    return batch.sheets;
  }

  /// 预览专用:低分辨率、限量、可取消。
  /// 版式(纸张/网格/边距/适配/缩放/页码/奇偶/逆序)与打印完全一致,
  /// 仅光栅化精度不同;打印时会按 renderDpi 重新全质量渲染。
  Future<PreviewResult> buildPreviewSheets(
    List<String> paths,
    PrintOptions o, {
    void Function(String)? onProgress,
    bool Function()? cancelled,
    PreviewSheetCallback? onSheet,
    int dpi = kPreviewDpi,
    int maxSheets = kMaxPreviewSheets,
  }) async {
    final batch = await _buildSheetsStreaming(
      paths,
      o,
      dpi: dpi,
      jpegQuality: kPreviewJpegQuality,
      maxSheets: maxSheets,
      cancelled: cancelled,
      onProgress: onProgress,
      onSheet: onSheet,
    );
    return PreviewResult(
      sheets: batch.sheets,
      totalSheets: batch.totalSheets,
      truncated: batch.truncated,
      dpi: dpi,
    );
  }

  /// 兼容旧接口:已有 PDF 字节流时直接排版
  Future<List<Uint8List>> buildSheets(
    List<Uint8List> pdfDocs,
    PrintOptions o, {
    void Function(String)? onProgress,
  }) async {
    final scale = o.renderDpi / 72.0;
    final pages = <img.Image>[];
    for (final bytes in pdfDocs) {
      final doc = await pdfx.PdfDocument.openData(bytes);
      try {
        for (var i = 1; i <= doc.pagesCount; i++) {
          final page = await doc.getPage(i);
          try {
            final rendered = await page.render(
              width: page.width * scale,
              height: page.height * scale,
              format: pdfx.PdfPageImageFormat.jpeg,
              quality: 92,
              backgroundColor: '#FFFFFF',
            );
            if (rendered == null) throw Exception('页面渲染失败');
            final im = img.decodeJpg(rendered.bytes);
            if (im == null) throw Exception('页面图像解码失败');
            pages.add(im);
          } finally {
            await page.close();
          }
        }
      } finally {
        await doc.close();
      }
    }
    return buildSheetsFromPages(pages, o, onProgress: onProgress);
  }

  /// 把已经拼好的纸张打包成 PDF(供系统打印 / 导出,不上传)
  Future<Uint8List> sheetsToPdf(List<Uint8List> sheets, PrintOptions o) async {
    final (w, h) = o.paperMm;
    final width =
        (o.orientation == 'landscape' ? h : w) * pdfcore.PdfPageFormat.mm;
    final height =
        (o.orientation == 'landscape' ? w : h) * pdfcore.PdfPageFormat.mm;
    final fmt = pdfcore.PdfPageFormat(width, height);
    final doc = pw.Document();
    for (final jpeg in sheets) {
      doc.addPage(
        pw.Page(
          pageFormat: fmt,
          margin: const pw.EdgeInsets.all(0),
          build: (_) => pw.SizedBox(
            width: width,
            height: height,
            child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.fill),
          ),
        ),
      );
    }
    return doc.save();
  }

  /// 打印一个或多个文件(按选择顺序合并成连续排版)
  /// [sheets] 传入预览已生成的成品,确保「所见即所得」且避免二次渲染
  Future<String> printFiles(
    IppPrinter printer,
    List<String> paths,
    PrintOptions options, {
    void Function(String)? onProgress,
    List<Uint8List>? sheets,
  }) async {
    if (paths.isEmpty) throw ArgumentError('没有选择文件');
    onProgress?.call('正在连接打印机...');
    final (caps, endpoint) = await _client.getCapabilities(printer);
    onProgress?.call(
      '已连接: ${caps.makeAndModel.isEmpty ? endpoint.host : caps.makeAndModel}'
      ' (${endpoint.transport == IppTransport.upgrade ? "TLS 升级" : "IPP"} ${endpoint.host}:${endpoint.port})',
    );

    final output =
        sheets ??
        await buildSheetsFromPaths(paths, options, onProgress: onProgress);
    final name = paths.first.split(Platform.pathSeparator).last;
    final jobIds = <String>[];
    for (var i = 0; i < output.length; i++) {
      onProgress?.call(
        '发送第 ${i + 1}/${output.length} 张 (${(output[i].length / 1024).toStringAsFixed(0)} KB)...',
      );
      final (accepted, _) = await _client.printJob(
        endpoint,
        output[i],
        format: 'image/jpeg',
        jobName: '$name - 第${i + 1}张',
        copies: options.copies,
        color: options.color,
        duplex: options.duplex,
        media: options.ippMedia,
      );
      final m = RegExp(r'job-id=(\d+)').firstMatch(accepted);
      if (m != null) jobIds.add(m.group(1)!);
      onProgress?.call(accepted);
    }
    final ids = jobIds.isEmpty ? '' : ' · job-id=${jobIds.join(",")}';
    return '打印完成 (${output.length} 张纸 / ${paths.length} 个文档)$ids';
  }

  Future<String> printFile(
    IppPrinter printer,
    String path,
    PrintOptions options, {
    void Function(String)? onProgress,
  }) => printFiles(printer, [path], options, onProgress: onProgress);
}
