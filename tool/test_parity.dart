// 奇偶页 / 逆序 逻辑单测(纯 Dart,不打印)
// 运行: dart run tool/test_parity.dart
import 'package:pure_print/print/page_range.dart';

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void check(String name, List<int> got, List<int> want) {
  final ok = _same(got, want);
  print('${ok ? "PASS" : "FAIL"}  $name -> $got (期望 $want)');
  if (!ok) throw StateError('解析不符: $name');
}

void main() {
  final base = parsePageRange('', 10); // 1..10
  check('全部', filterParity(base, 'all'), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  check('仅奇数页', filterParity(base, 'odd'), [1, 3, 5, 7, 9]);
  check('仅偶数页', filterParity(base, 'even'), [2, 4, 6, 8, 10]);
  check('范围1-6+奇数', filterParity(parsePageRange('1-6', 10), 'odd'), [1, 3, 5]);
  check('范围1-6+偶数', filterParity(parsePageRange('1-6', 10), 'even'), [2, 4, 6]);
  check('偶数+逆序', filterParity(base, 'even').reversed.toList(),
      [10, 8, 6, 4, 2]);
  print('\n全部通过');
}
