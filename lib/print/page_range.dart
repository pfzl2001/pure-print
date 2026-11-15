// 页码范围解析(纯 Dart,不依赖 Flutter,便于独立测试)
// 空串=全部;支持 "1-3"、"1,3,5"、"2-"、"1~3"、中文逗号/分号

int _max(int a, int b) => a > b ? a : b;
int _min(int a, int b) => a < b ? a : b;

List<int> parsePageRange(String spec, int total) {
  final trimmed = spec.trim();
  if (trimmed.isEmpty) return List.generate(total, (i) => i + 1);
  final set = <int>{};
  for (final part in trimmed.split(RegExp(r'[,，;；]'))) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^(\d+)\s*[-~]\s*(\d+)?$').firstMatch(t);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = m.group(2) == null ? total : int.parse(m.group(2)!);
      final lo = _min(a, b), hi = _max(a, b);
      for (var i = lo; i <= hi && i <= total; i++) {
        if (i >= 1) set.add(i);
      }
    } else {
      final n = int.tryParse(t);
      if (n != null && n >= 1 && n <= total) set.add(n);
    }
  }
  final list = set.toList()..sort();
  if (list.isEmpty) {
    throw ArgumentError('页码范围无效(文档共 $total 页),示例:1-3 或 1,3,5');
  }
  return list;
}

/// 按奇偶过滤页码,用于手动双面:
/// 先打偶数页(通常逆序)→ 翻面放回纸盒 → 再打奇数页
List<int> filterParity(List<int> pages, String parity) {
  if (parity == 'odd') return pages.where((p) => p.isOdd).toList();
  if (parity == 'even') return pages.where((p) => p.isEven).toList();
  return pages;
}
