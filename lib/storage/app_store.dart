// 本地持久化:默认打印设置、上次使用的(mDNS 自动发现的)打印机、打印历史
// 手动按 IP 添加的打印机仅保存在本次会话内存中,不写入磁盘。
// 原因:移动端没有可靠的「应用退出」回调(系统可能直接终止进程),
// 只有不落盘才能真正等价于「关闭 App 后清除」。
// 全部数据只存在本机 SharedPreferences,不上传、不联网
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../print/print_service.dart';

class PrintRecord {
  final String time;
  final String fileName;
  final String printer;
  final String result;
  final bool success;

  const PrintRecord({
    required this.time,
    required this.fileName,
    required this.printer,
    required this.result,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
        'time': time,
        'fileName': fileName,
        'printer': printer,
        'result': result,
        'success': success,
      };

  factory PrintRecord.fromJson(Map<String, dynamic> m) => PrintRecord(
        time: m['time'] as String? ?? '',
        fileName: m['fileName'] as String? ?? '',
        printer: m['printer'] as String? ?? '',
        result: m['result'] as String? ?? '',
        success: m['success'] as bool? ?? false,
      );
}

class AppStore {
  static const _kOptions = 'print_options';
  static const _kPrinters = 'manual_printers';
  static const _kLastPrinter = 'last_printer';
  static const _kHistory = 'print_history';
  static const int maxHistory = 50;

  static Future<PrintOptions> loadOptions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kOptions);
    if (raw == null) return PrintOptions();
    try {
      return PrintOptions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return PrintOptions();
    }
  }

  static Future<void> saveOptions(PrintOptions o) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kOptions, jsonEncode(o.toJson()));
  }

  /// 清理旧版本落盘的手动 IP(一次性迁移,可重复调用)。
  /// 旧版本还会把手动 IP 写进「上次使用的打印机」,升级后的首次启动一并清掉。
  /// 新版本不再写 manual_printers,故该条件只在首次迁移时成立,
  /// 不会误删之后由 mDNS 自动发现设备写入的记忆。
  static Future<void> clearManualPrinters() async {
    final sp = await SharedPreferences.getInstance();
    final hadLegacy = sp.containsKey(_kPrinters);
    await sp.remove(_kPrinters);
    if (hadLegacy) await sp.remove(_kLastPrinter);
  }

  /// 清除「上次使用的打印机」,供用户主动清除桌面端已保存的 IP
  static Future<void> clearLastPrinter() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kLastPrinter);
  }

  static Future<String?> loadLastPrinter() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kLastPrinter);
  }

  static Future<void> saveLastPrinter(String host) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLastPrinter, host);
  }

  static Future<List<PrintRecord>> loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_kHistory) ?? <String>[];
    final out = <PrintRecord>[];
    for (final s in raw) {
      try {
        out.add(PrintRecord.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> addHistory(PrintRecord r) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_kHistory) ?? <String>[];
    raw.insert(0, jsonEncode(r.toJson()));
    if (raw.length > maxHistory) raw.removeRange(maxHistory, raw.length);
    await sp.setStringList(_kHistory, raw);
  }

  static Future<void> clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kHistory);
  }
}
