// 客户端版式拼版(纯 Dart,只依赖 image 包,可独立单测)
// 对齐 Free2Convert「PDF 多页合一」的排版能力:
//   自定义网格 / 纸张尺寸 / 横竖 / 页边距 mm / 间距 mm / 适配(完整|铺满)
//   内容缩放 % / 上下位置 % / 每格边框
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 常用纸张(mm)
const Map<String, List<double>> kPaperSizesMm = {
  'a4': [210, 297],
  'a3': [297, 420],
  'a5': [148, 210],
  'letter': [215.9, 279.4],
  'photo4x6': [101.6, 152.4],
};

/// UI 用纸张标签(顺序即下拉框顺序)
const Map<String, String> kPaperLabels = {
  'a4': 'A4 (210 × 297 mm)',
  'a3': 'A3 (297 × 420 mm)',
  'a5': 'A5 (148 × 210 mm)',
  'letter': 'Letter (8.5 × 11 in)',
  'photo4x6': '4 × 6 照片纸',
  'custom': '自定义尺寸…',
};

/// 网页常见的网格预设,label → (rows, cols)
const Map<String, List<int>> kGridPresets = {
  '1 × 1 (每页 1 版)': [1, 1],
  '1 × 2 (横向 2 版)': [1, 2],
  '2 × 1 (纵向 2 版)': [2, 1],
  '2 × 2 (每页 4 版)': [2, 2],
  '1 × 3 (横向 3 版)': [1, 3],
  '3 × 1 (纵向 3 版)': [3, 1],
  '2 × 3 (每页 6 版)': [2, 3],
  '3 × 2 (每页 6 版)': [3, 2],
  '2 × 4 (每页 8 版)': [2, 4],
  '自定义行列…': [0, 0],
};

/// 由预设 key 反查标签
String gridPresetLabel(int rows, int cols) {
  for (final e in kGridPresets.entries) {
    if (e.value[0] == rows && e.value[1] == cols) return e.key;
  }
  return '自定义行列…';
}

class SheetLayout {
  final String orientation; // portrait / landscape
  final double marginMm;
  final double gapMm;
  final int rows;
  final int cols;
  final String fit; // contain / cover
  final double scalePct;
  final double offsetPct;
  final bool border;
  final double paperWmm;
  final double paperHmm;
  final int dpi;

  const SheetLayout({
    this.orientation = 'portrait',
    this.marginMm = 0,
    this.gapMm = 0,
    this.rows = 1,
    this.cols = 1,
    this.fit = 'contain',
    this.scalePct = 100,
    this.offsetPct = 0,
    this.border = false,
    this.paperWmm = 210,
    this.paperHmm = 297,
    this.dpi = 200,
  });

  int get perSheet => math.max(1, rows) * math.max(1, cols);

  double px(double mm) => mm / 25.4 * dpi;

  /// 输出画布像素尺寸(横版即宽高互换)
  (int, int) get canvasSize {
    final w = math.max(1, px(paperWmm).round());
    final h = math.max(1, px(paperHmm).round());
    return orientation == 'landscape' ? (h, w) : (w, h);
  }

  /// 每个格子的像素尺寸(供 UI 预览/单测核对)
  (int, int) get cellSize {
    final (cw, ch) = canvasSize;
    final m = px(marginMm).round();
    final gap = px(gapMm).round();
    final cols = math.max(1, this.cols);
    final rows = math.max(1, this.rows);
    return (
      math.max(1, (math.max(1, cw - 2 * m) - gap * (cols - 1)) ~/ cols),
      math.max(1, (math.max(1, ch - 2 * m) - gap * (rows - 1)) ~/ rows),
    );
  }
}

/// 旧版固定档位的网格换算(保留兼容,新版 UI 已用 rows/cols)
(int, int) gridFor(int n) => switch (n) {
      2 => (1, 2),
      4 => (2, 2),
      8 => (2, 4),
      _ => (1, 1),
    };

void strokeRect(img.Image im, int x1, int y1, int x2, int y2) {
  final c = img.ColorRgb8(170, 170, 170);
  img.drawLine(im, x1: x1, y1: y1, x2: x2, y2: y1, color: c, thickness: 2);
  img.drawLine(im, x1: x1, y1: y2, x2: x2, y2: y2, color: c, thickness: 2);
  img.drawLine(im, x1: x1, y1: y1, x2: x1, y2: y2, color: c, thickness: 2);
  img.drawLine(im, x1: x2, y1: y1, x2: x2, y2: y2, color: c, thickness: 2);
}

/// 把若干页按网格拼到一张纸上,返回可直接发送的 JPEG
/// 预览与打印共用本函数,保证「所见即所得」
Uint8List composeSheet(List<img.Image> tiles, SheetLayout layout) {
  final (cw, ch) = layout.canvasSize;
  final canvas = img.Image(width: cw, height: ch);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

  final m = layout.px(layout.marginMm).round();
  final gap = layout.px(layout.gapMm).round();
  final cols = math.max(1, layout.cols);
  final rows = math.max(1, layout.rows);
  final areaW = math.max(1, cw - 2 * m);
  final areaH = math.max(1, ch - 2 * m);
  final cellW = math.max(1, (areaW - gap * (cols - 1)) ~/ cols);
  final cellH = math.max(1, (areaH - gap * (rows - 1)) ~/ rows);

  for (var i = 0; i < tiles.length; i++) {
    final col = i % cols;
    final row = i ~/ cols;
    final cx = m + col * (cellW + gap);
    final cy = m + row * (cellH + gap);
    final t = tiles[i];
    final baseScale = layout.fit == 'cover'
        ? math.max(cellW / t.width, cellH / t.height)
        : math.min(cellW / t.width, cellH / t.height);
    final s = baseScale * (layout.scalePct / 100);
    final tw = math.max(1, (t.width * s).round());
    final th = math.max(1, (t.height * s).round());
    var fitted = img.copyResize(t, width: tw, height: th);

    // 缩放超过格子时,以格子为中心裁切,避免串到相邻格
    if (tw > cellW || th > cellH) {
      final srcX = math.max(0, (tw - cellW) ~/ 2);
      final srcY = math.max(0, (th - cellH) ~/ 2);
      fitted = img.copyCrop(fitted,
          x: math.min(srcX, tw - 1),
          y: math.min(srcY, th - 1),
          width: math.min(cellW, tw),
          height: math.min(cellH, th));
    }
    final centeredY = cy + (cellH - fitted.height) ~/ 2;
    final shiftedY = centeredY + (cellH * layout.offsetPct / 100).round();
    final maxDy = math.max(cy, cy + cellH - fitted.height);
    final dy = shiftedY < cy ? cy : (shiftedY > maxDy ? maxDy : shiftedY);
    final dx = cx + (cellW - fitted.width) ~/ 2;
    img.compositeImage(canvas, fitted, dstX: dx, dstY: dy);
    if (layout.border) {
      strokeRect(canvas, cx, cy, cx + cellW, cy + cellH);
    }
  }
  return Uint8List.fromList(img.encodeJpg(canvas, quality: 92));
}
