// 版式拼版纯 Dart 单测(不依赖 Flutter / pdfx)
// 覆盖:网格预设、纸张、横竖、页边距、间距、完整显示/铺满裁切、缩放、上下位置、边框
// 运行: dart run tool/test_layout.dart
import 'package:image/image.dart' as img;
import 'package:pure_print/print/sheet_layout.dart';

img.Image makePage(String label, {int w = 620, int h = 877}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(im,
      x1: 20, y1: 20, x2: w - 20, y2: 110, color: img.ColorRgb8(30, 90, 180));
  img.drawString(im, label, font: img.arial48, x: 60, y: 55);
  for (var y = 180; y < h - 40; y += 70) {
    img.drawLine(im,
        x1: 30, y1: y, x2: w - 30, y2: y,
        color: img.ColorRgb8(0, 0, 0), thickness: 2);
  }
  return im;
}

int failures = 0;
void check(bool ok, String msg) {
  print('${ok ? "PASS" : "FAIL"}  $msg');
  if (!ok) failures++;
}

void main() {
  final pages = [for (var i = 1; i <= 8; i++) makePage('P$i')];

  // 1. 网格预设 → 画布与格子尺寸
  for (final e in kGridPresets.entries) {
    final r = e.value[0], c = e.value[1];
    if (r == 0) continue;
    final l = SheetLayout(rows: r, cols: c, dpi: 100);
    final (cw, ch) = l.canvasSize;
    final (cellW, cellH) = l.cellSize;
    check(l.perSheet == r * c && cw > 0 && ch > 0 && cellW > 0 && cellH > 0,
        '${e.key} → 画布 ${cw}×${ch}px,格子 ${cellW}×${cellH}px');
  }

  // 2. 常用纸张尺寸(200dpi A4 ≈ 1654×2339)
  for (final e in kPaperSizesMm.entries) {
    final l = SheetLayout(
        paperWmm: e.value[0], paperHmm: e.value[1], dpi: 200);
    final (cw, ch) = l.canvasSize;
    final wantW = (e.value[0] / 25.4 * 200).round();
    final wantH = (e.value[1] / 25.4 * 200).round();
    check((cw - wantW).abs() <= 1 && (ch - wantH).abs() <= 1,
        '${e.key} → ${cw}×${ch}px (期望 ≈${wantW}×${wantH})');
  }

  // 3. 横版宽高互换
  final p = SheetLayout(orientation: 'portrait', dpi: 100);
  final land = SheetLayout(orientation: 'landscape', dpi: 100);
  check(land.canvasSize.$1 == p.canvasSize.$2 &&
            land.canvasSize.$2 == p.canvasSize.$1,
        '横版宽高互换 ${land.canvasSize.$1}×${land.canvasSize.$2}');

  // 4. 页边距 / 间距使格子变小
  final noMargin = SheetLayout(rows: 2, cols: 2, dpi: 100).cellSize;
  final withMargin = SheetLayout(
          rows: 2, cols: 2, marginMm: 10, gapMm: 5, dpi: 100)
      .cellSize;
  check(withMargin.$1 < noMargin.$1 && withMargin.$2 < noMargin.$2,
      '页边距/间距生效: ${noMargin.$1}×${noMargin.$2} → ${withMargin.$1}×${withMargin.$2}');

  // 5. 每种版式都能产出可解码的 JPEG
  final layouts = <String, SheetLayout>{
    '1up': const SheetLayout(dpi: 100),
    '2up': const SheetLayout(rows: 1, cols: 2, dpi: 100),
    '4up_border': const SheetLayout(
        rows: 2, cols: 2, marginMm: 8, gapMm: 4, border: true, dpi: 100),
    '8up': const SheetLayout(rows: 2, cols: 4, dpi: 100),
    'cover': const SheetLayout(
        rows: 1, cols: 2, fit: 'cover', scalePct: 120, dpi: 100),
    'offset': const SheetLayout(
        rows: 1, cols: 2, scalePct: 80, offsetPct: -30, dpi: 100),
    'landscape': const SheetLayout(
        orientation: 'landscape', rows: 3, cols: 2, dpi: 100),
    'custom_paper': const SheetLayout(
        paperWmm: 180, paperHmm: 250, rows: 2, cols: 1, dpi: 100),
  };
  for (final e in layouts.entries) {
    final bytes = composeSheet(pages.take(e.value.perSheet.clamp(1, 8)).toList(), e.value);
    final decoded = img.decodeJpg(bytes);
    final (cw, ch) = e.value.canvasSize;
    check(decoded != null && decoded.width == cw && decoded.height == ch,
        '${e.key} → ${bytes.length} B, ${decoded?.width}×${decoded?.height}px');
  }

  // 6. 铺满裁切与完整显示在同一缩放下应产生不同结果
  final a = composeSheet([pages.first],
      const SheetLayout(rows: 1, cols: 2, fit: 'contain', dpi: 100));
  final b = composeSheet([pages.first],
      const SheetLayout(rows: 1, cols: 2, fit: 'cover', dpi: 100));
  check(a.length != b.length, '完整显示 / 铺满裁切 输出不同 (${a.length} vs ${b.length} B)');

  // 7. 旧档位兼容
  check(gridFor(2).$1 == 1 && gridFor(2).$2 == 2 && gridFor(8).$2 == 4,
      '旧 1/2/4/8 档位换算兼容');

  print('');
  print(failures == 0 ? 'ALL_LAYOUT_TESTS_PASS' : 'LAYOUT_TESTS_FAILED($failures)');
  if (failures > 0) throw StateError('$failures 项版式测试失败');
}
