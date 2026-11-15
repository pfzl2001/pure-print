// 拖入文件 / 文件选择器共用的路径整理逻辑(纯 Dart,可独立单测)
// 规则:文件夹展开成其中的可打印文件 → 过滤不支持格式 → 去重 → 保持拖入顺序
import 'dart:io';
import 'file_types.dart';

class DropMergeResult {
  /// 合并后的完整列表
  final List<String> merged;

  /// 本次真正新增的文件
  final List<String> added;

  /// 被跳过的路径(格式不支持 / 空路径 / 目录读取失败)
  final List<String> skipped;

  /// 被展开的文件夹数量
  final int expandedDirs;

  const DropMergeResult({
    required this.merged,
    required this.added,
    required this.skipped,
    required this.expandedDirs,
  });

  String get summary => '新增 ${added.length} 个文件'
      '${expandedDirs > 0 ? " (展开 $expandedDirs 个文件夹)" : ""}'
      '${skipped.isNotEmpty ? ",跳过 ${skipped.length} 个不支持项" : ""}';
}

/// Windows 路径大小写不敏感,统一成正斜杠小写做去重键
String normalizePathKey(String path) =>
    path.trim().replaceAll('"', '').replaceAll('\\', '/').toLowerCase();

const int _kMaxDropFiles = 200;
const int _kMaxDirDepth = 3;

void _collectFromDir(Directory dir, int depth, List<String> out) {
  if (depth > _kMaxDirDepth || out.length >= _kMaxDropFiles) return;
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    return;
  }
  entries.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  for (final e in entries) {
    if (out.length >= _kMaxDropFiles) return;
    if (e is Directory) {
      _collectFromDir(e, depth + 1, out);
    } else if (e is File) {
      out.add(e.path);
    }
  }
}

/// 把一批拖入路径合并进已有文件列表。
/// [current] 已有列表;[incoming] 本次拖入的路径(文件或文件夹,顺序即优先级)
DropMergeResult mergeDroppedPaths(
  List<String> current,
  Iterable<String> incoming,
) {
  final merged = List<String>.from(current);
  final seen = <String>{for (final p in current) normalizePathKey(p)};
  final added = <String>[];
  final skipped = <String>[];
  var expandedDirs = 0;

  for (final raw in incoming) {
    final path = raw.trim().replaceAll('"', '');
    if (path.isEmpty) {
      skipped.add(raw);
      continue;
    }
    final candidates = <String>[];
    final dir = Directory(path);
    if (dir.existsSync()) {
      expandedDirs++;
      _collectFromDir(dir, 1, candidates);
      if (candidates.isEmpty) skipped.add(path);
    } else {
      candidates.add(path);
    }
    for (final c in candidates) {
      if (contentTypeOf(c) == null) {
        skipped.add(c);
        continue;
      }
      if (seen.add(normalizePathKey(c))) {
        merged.add(c);
        added.add(c);
      }
    }
  }
  return DropMergeResult(
    merged: merged,
    added: added,
    skipped: skipped,
    expandedDirs: expandedDirs,
  );
}
