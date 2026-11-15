// 本地持久化:默认打印设置、手动添加的打印机、上次使用的打印机、打印历史
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

  static Future<List<String>> loadManualPrinters() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_kPrinters) ?? <String>[];
  }

  static Future<void> saveManualPrinters(List<String> hosts) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kPrinters, hosts);
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
