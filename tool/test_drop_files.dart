// 拖入文件整理逻辑的纯 Dart 单测(不依赖 Flutter)
// 运行: dart run tool/test_drop_files.dart
import 'dart:io';
import 'package:pure_print/print/drop_files.dart';
import 'package:pure_print/print/file_types.dart';

int failures = 0;
void check(bool ok, String msg) {
  print('${ok ? "PASS" : "FAIL"}  $msg');
  if (!ok) failures++;
}

void main() {
  // 1. 类型识别(大小写 / Windows 路径 / 无扩展名)
  check(contentTypeOf(r'D:\docs\a.PDF') == ContentType.pdf, 'Windows 路径 + 大写后缀 → PDF');
  check(contentTypeOf('/home/a/b.JpEg') == ContentType.photo, '混合大小写后缀 → 照片');
  check(contentTypeOf('report.docx') == ContentType.office, 'docx → 办公文档');
  check(contentTypeOf('sheet.XLSX') == ContentType.office, 'xlsx → 办公文档');
  check(contentTypeOf('notes.txt') == null, 'txt → 不支持');
  check(contentTypeOf(r'D:\noext') == null, '无扩展名 → 不支持');
  check(contentTypeOf(r'C:\a.b\folder') == null, '目录名带点不误判');

  // 2. 真实临时目录:文件夹展开 + 过滤 + 排序 + 顺序保持
  final tmp = Directory.systemTemp.createTempSync('pure_print_drop_test_');
  try {
    final dir = Directory('${tmp.path}${Platform.pathSeparator}docs');
    dir.createSync();
    final sub = Directory('${dir.path}${Platform.pathSeparator}sub');
    sub.createSync();
    File('${dir.path}${Platform.pathSeparator}a.pdf').writeAsStringSync('%PDF');
    File('${dir.path}${Platform.pathSeparator}b.PNG').writeAsStringSync('png');
    File('${dir.path}${Platform.pathSeparator}c.txt').writeAsStringSync('skip');
    File('${sub.path}${Platform.pathSeparator}d.docx').writeAsStringSync('doc');
    final outside = File('${tmp.path}${Platform.pathSeparator}z.pdf');
    outside.writeAsStringSync('%PDF');

    final r = mergeDroppedPaths([], [outside.path, dir.path]);
    check(r.added.length == 4, '拖入 1 文件 + 1 文件夹 → 新增 4 个可打印文件 (实际 ${r.added.length})');
    check(r.expandedDirs == 1, '展开 1 个文件夹');
    check(r.skipped.length == 1, '跳过 1 个 .txt (实际 ${r.skipped.length})');
    check(r.merged.first == outside.path, '保持拖入顺序:文件在前');
    check(r.added.any((p) => p.endsWith('d.docx')), '子文件夹中的 docx 被递归收集');
    check(r.summary.contains('展开 1 个文件夹'), 'summary 文案正确: ${r.summary}');

    // 3. 重复拖入 / 大小写与斜杠差异去重
    final again = mergeDroppedPaths(r.merged, [
      outside.path.toUpperCase(),
      outside.path.replaceAll('/', '\\'),
      dir.path,
    ]);
    check(again.added.isEmpty, '重复拖入(含大小写/斜杠差异)全部去重');
    check(again.merged.length == r.merged.length, '重复拖入不改变列表长度');

    // 4. 增量追加 + 空路径
    final extra = File('${tmp.path}${Platform.pathSeparator}new.xlsx');
    extra.writeAsStringSync('xlsx');
    final third = mergeDroppedPaths(r.merged, ['', extra.path]);
    check(third.added.length == 1 && third.added.first == extra.path, '增量追加只新增 1 个');
    check(third.merged.first == outside.path, '增量追加不破坏原有顺序');
  } finally {
    tmp.deleteSync(recursive: true);
  }

  print('');
  print(failures == 0 ? 'ALL_DROP_TESTS_PASS' : 'DROP_TESTS_FAILED($failures)');
  if (failures > 0) throw StateError('$failures 项拖放逻辑测试失败');
}
