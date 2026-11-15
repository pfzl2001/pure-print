// 文件类型识别(纯 Dart,不依赖 Flutter / 插件,便于独立单测与拖放逻辑复用)
enum ContentType { photo, pdf, office }

/// 文件选择器与文件夹展开时允许的后缀(不含点,小写)
const List<String> kPrintableExtensions = [
  'pdf',
  'docx', 'xlsx', 'doc', 'xls',
  'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif',
];

/// 按扩展名判断文件类型(分享进来的无扩展名文件由 share_handler 嗅探补后缀)
ContentType? contentTypeOf(String path) {
  // Windows 用反斜杠、其他平台用正斜杠,两种都兼容
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic']
      .contains(ext)) {
    return ContentType.photo;
  }
  if (ext == 'pdf') return ContentType.pdf;
  if (const ['docx', 'xlsx', 'doc', 'xls'].contains(ext)) {
    return ContentType.office;
  }
  return null;
}

String contentTypeLabel(ContentType t) => switch (t) {
      ContentType.photo => '照片',
      ContentType.pdf => 'PDF',
      ContentType.office => '办公文档',
    };
