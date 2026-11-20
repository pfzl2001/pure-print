import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

import 'dev/selftest.dart';
import 'office/office_to_pdf.dart';
import 'share/share_handler.dart';
import 'storage/app_store.dart';
import 'ui/desktop_page.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 迁移旧版本数据:清除此前落盘的手动添加 IP 列表。
  // 新版本不再持久化手动打印机,启动时清一次即可移除历史残留。
  try {
    await AppStore.clearManualPrinters();
  } catch (_) {
    // 存储插件未就绪时不影响启动
  }

  // 预加载开源中文字体(Droid Sans Fallback, Apache-2.0),供办公文档转 PDF 使用
  try {
    final fontData =
        await rootBundle.load('assets/fonts/DroidSansFallbackFull.ttf');
    OfficeToPdf.setFont(pw.Font.ttf(fontData));
  } catch (_) {
    // 字体缺失时降级为默认字体(中文可能无法显示)
  }

  // Windows 原生 exe 端到端自检:PUREPRINT_SELFTEST=1 时跑完整链路后退出
  if (Platform.environment['PUREPRINT_SELFTEST'] == '1') {
    await runWindowsSelfTest();
    exit(0);
  }

  // 分享导入只在移动端注册(Windows 无对应原生通道)
  if (!Platform.isWindows) await ShareHandler.init();

  runApp(const PurePrintApp());
}

class PurePrintApp extends StatelessWidget {
  const PurePrintApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Platform.isWindows ? '纯净打印 · 多页合一工作台' : '纯净打印',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Platform.isWindows ? const DesktopPage() : const HomePage(),
    );
  }
}
