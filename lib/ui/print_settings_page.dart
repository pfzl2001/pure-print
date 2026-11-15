// 单次打印设置页:选完文件/分享导入后进入,修改仅对本次打印生效
// 支持多个文件合并排版、多张纸预览
// 预览使用低分辨率限量缩略图(流式生成 + 后台 isolate),打印时按全分辨率重新渲染
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../ipp/ipp_client.dart';
import '../print/print_service.dart';
import '../print/system_print.dart';
import '../storage/app_store.dart';
import 'layout_editor.dart';

class PrintSettingsPage extends StatefulWidget {
  final List<String> filePaths;
  final IppPrinter printer;
  final PrintOptions defaults;
  final void Function(PrintOptions options) onSaveDefault;

  const PrintSettingsPage({
    super.key,
    required this.filePaths,
    required this.printer,
    required this.defaults,
    required this.onSaveDefault,
  });

  @override
  State<PrintSettingsPage> createState() => _PrintSettingsPageState();
}

class _PrintSettingsPageState extends State<PrintSettingsPage> {
  final _service = PrintService();
  late PrintOptions _options;
  late TextEditingController _rangeController;

  // 预览成品(低分辨率 JPEG),打印不复用这批数据。
  // 用 ValueNotifier 局部刷新,增量生成时不会反复重建整页设置控件
  final ValueNotifier<List<Uint8List>> _preview =
      ValueNotifier<List<Uint8List>>([]);
  final ValueNotifier<String> _previewStatus = ValueNotifier<String>('');
  int _totalSheets = 0;
  bool _previewTruncated = false;
  bool _previewStale = false;
  int _sheetIndex = 0;

  // 日志只刷新自己的区域,不再触发整页 setState
  final ValueNotifier<List<String>> _log = ValueNotifier<List<String>>([]);

  // 生成代号:设置变更 / 重新生成 / 退出页面时递增,用于丢弃过期结果
  int _generation = 0;

  bool _busy = false;
  bool _printing = false;
  bool _saveAsDefault = false;
  bool _done = false;
  bool _failed = false;
  int _totalKb = 0;

  @override
  void initState() {
    super.initState();
    _options = widget.defaults.copy()
      ..pageRange = ''
      ..parity = 'all'
      ..reverse = false;
    _rangeController = TextEditingController();
    _totalKb =
        widget.filePaths.fold<int>(0, (sum, p) {
          final f = File(p);
          return sum + (f.existsSync() ? f.lengthSync() : 0);
        }) ~/
        1024;
    // 预览完全按需:进入页面不渲染任何东西,由用户点击「生成预览」触发
  }

  @override
  void dispose() {
    _generation++; // 让仍在跑的排版任务自行退出
    _rangeController.dispose();
    _log.dispose();
    _preview.dispose();
    _previewStatus.dispose();
    super.dispose();
  }

  String get _title => widget.filePaths.length == 1
      ? widget.filePaths.first.split(Platform.pathSeparator).last
      : '${widget.filePaths.first.split(Platform.pathSeparator).last} 等 ${widget.filePaths.length} 个文件';

  String get _printerName =>
      widget.printer.name.isEmpty ? widget.printer.host : widget.printer.name;

  void _addLog(String msg) {
    if (!mounted) return;
    final next = [..._log.value, '[${TimeOfDay.now().format(context)}] $msg'];
    _log.value = next.length > 120 ? next.sublist(next.length - 120) : next;
  }

  void _markStale() {
    if (_preview.value.isEmpty && !_busy) return;
    _generation++;
    _previewStale = true;
    _previewStatus.value = '设置已更改,请重新生成预览';
  }

  /// 生成预览:低分辨率 + 限量 + 后台 isolate,不阻塞 UI
  Future<void> _generatePreview() async {
    if (_busy || _printing) return;
    final token = ++_generation;
    _options.pageRange = _rangeController.text.trim();
    setState(() {
      _busy = true;
      _sheetIndex = 0;
      _previewStale = false;
    });
    _preview.value = <Uint8List>[];
    _previewStatus.value = '正在生成第 1 张…';
    _log.value = <String>[];
    try {
      final result = await _service.buildPreviewSheets(
        widget.filePaths,
        _options,
        onProgress: _addLog,
        cancelled: () => token != _generation || !mounted,
        onSheet: (i, jpeg, total) {
          if (!mounted || token != _generation) return;
          // 首张到达即可查看,后续逐张追加,不触发整页重建
          _preview.value = [..._preview.value, jpeg];
          _previewStatus.value = i + 1 < total
              ? '已生成 ${i + 1} / $total 张,继续后台生成…'
              : '';
        },
      );
      if (!mounted || token != _generation) return;
      setState(() {
        _totalSheets = result.totalSheets;
        _previewTruncated = result.truncated;
        _sheetIndex = 0;
      });
      _previewStatus.value = '';
      _addLog(
        '✅ 预览已生成(${result.dpi} dpi): ${result.hint} · ${_options.layoutSummary}',
      );
    } on PreviewCancelledException {
      // 已被新任务、取消操作或页面退出取代,无需提示
    } catch (e) {
      _addLog('❌ 预览生成失败: $e');
    } finally {
      if (mounted && token == _generation) setState(() => _busy = false);
    }
  }

  /// 用户可随时中止后台预览,避免设置改了还在空耗 CPU
  void _cancelPreview() {
    _generation++;
    _previewStatus.value = '已取消预览';
    if (mounted) setState(() => _busy = false);
    _addLog('预览已取消');
  }

  Future<void> _record(bool success, String result) async {
    await AppStore.addHistory(
      PrintRecord(
        time: DateTime.now().toString().substring(0, 16),
        fileName: _title,
        printer: '$_printerName (${widget.printer.host})',
        result: result.length > 160 ? result.substring(0, 160) : result,
        success: success,
      ),
    );
  }

  Future<void> _startPrint() async {
    _options.pageRange = _rangeController.text.trim();
    if (_saveAsDefault) {
      widget.onSaveDefault(
        _options.copy()
          ..pageRange = ''
          ..parity = 'all'
          ..reverse = false,
      );
    }
    setState(() {
      _printing = true;
      _done = false;
      _failed = false;
    });
    _log.value = <String>[];
    _addLog('文件: $_title');
    _addLog('版式: ${_options.layoutSummary}');
    try {
      // 不复用低分辨率预览:由 printFiles 按 renderDpi 输出全部纸张
      _addLog('按 ${_options.renderDpi} dpi 全分辨率渲染全部页面…');
      final result = await _service.printFiles(
        widget.printer,
        widget.filePaths,
        _options,
        onProgress: _addLog,
      );
      _addLog('✅ $result');
      await _record(true, result);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      _addLog('❌ 打印失败: $e');
      await _record(false, '$e');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _systemPrint() async {
    _addLog('正在按全分辨率生成系统打印用 PDF...');
    try {
      final sheets = await _service.buildSheetsFromPaths(
        widget.filePaths,
        _options,
        onProgress: _addLog,
      );
      final pdfBytes = await _service.sheetsToPdf(sheets, _options);
      final ok = await SystemPrintService.printPdf(pdfBytes, '纯净打印 - $_title');
      _addLog(ok ? '✅ 已提交到系统打印队列' : '已取消系统打印');
    } catch (e) {
      _addLog('❌ 系统打印失败: $e');
    }
  }

  /// 预览区独立刷新:增量生成时只重绘这一块,不重建整页设置控件
  Widget _buildPreview() => ValueListenableBuilder<List<Uint8List>>(
    valueListenable: _preview,
    builder: (_, sheets, _) {
      if (sheets.isEmpty) {
        if (_busy) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text('正在生成第 1 张预览…', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(18),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.preview, size: 34, color: Colors.grey[400]),
                const SizedBox(height: 8),
                const Text('点击「生成预览」查看排版效果', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  '按需生成 · 首张秒出 · 可随时取消\n预览不会减慢打开页面的速度',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        );
      }
      final idx = _sheetIndex.clamp(0, sheets.length - 1);
      // 只按显示尺寸解码,避免把整张位图放进内存/GPU
      final raw = (420 * MediaQuery.devicePixelRatioOf(context)).round();
      final cacheWidth = raw < 240 ? 240 : (raw > 1400 ? 1400 : raw);
      return Column(
        children: [
          Container(
            height: 260,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(8),
            child: RepaintBoundary(
              child: Image.memory(
                sheets[idx],
                fit: BoxFit.contain,
                cacheWidth: cacheWidth,
                gaplessPlayback: true,
              ),
            ),
          ),
          ValueListenableBuilder<String>(
            valueListenable: _previewStatus,
            builder: (_, status, _) => status.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      status,
                      style: const TextStyle(fontSize: 11, color: Colors.blue),
                    ),
                  ),
          ),
          if (_previewStale)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '设置已更改,请重新生成预览',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          if (_previewTruncated && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '为保持流畅,仅预览 $_totalSheets 张中的 ${sheets.length} 张;打印仍输出全部',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: idx > 0
                    ? () => setState(() => _sheetIndex = idx - 1)
                    : null,
              ),
              Text(
                '第 ${idx + 1} / ${sheets.length} 张'
                '${_previewTruncated && !_busy ? " (共 $_totalSheets 张)" : ""}',
                style: const TextStyle(fontSize: 12),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: idx < sheets.length - 1
                    ? () => setState(() => _sheetIndex = idx + 1)
                    : null,
              ),
            ],
          ),
        ],
      );
    },
  );

  Widget _buildLog() => ValueListenableBuilder<List<String>>(
    valueListenable: _log,
    builder: (_, lines, _) {
      if (lines.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
          width: double.infinity,
          height: 150,
          padding: const EdgeInsets.all(10),
          color: Colors.grey[100],
          child: ListView.builder(
            itemCount: lines.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                lines[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('打印设置'),
        actions: [
          IconButton(
            icon: Icon(_busy ? Icons.close : Icons.preview),
            tooltip: _busy ? '取消预览' : '生成预览',
            onPressed: _printing
                ? null
                : (_busy ? _cancelPreview : _generatePreview),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.insert_drive_file),
                title: Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${widget.filePaths.length} 个文件 · $_totalKb KB · 合并为连续排版',
                ),
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.print),
                title: Text(_printerName),
                subtitle: Text('${widget.printer.host}:${widget.printer.port}'),
              ),
            ),
            const SizedBox(height: 10),
            _buildPreview(),
            const SizedBox(height: 6),
            Text(
              '版式设置(对齐网页多页合一工具)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LayoutEditor(
                  options: _options,
                  enabled: !_printing && !_busy,
                  onChange: (mutate) => setState(() {
                    mutate(_options);
                    _markStale();
                  }),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: PageSelectionEditor(
                  options: _options,
                  rangeController: _rangeController,
                  enabled: !_printing && !_busy,
                  onChange: (mutate) => setState(() {
                    mutate(_options);
                    _markStale();
                  }),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Text('份数'),
                        Expanded(
                          child: Slider(
                            value: _options.copies.toDouble(),
                            min: 1,
                            max: 10,
                            divisions: 9,
                            label: '${_options.copies}',
                            onChanged: _printing
                                ? null
                                : (v) => setState(
                                    () => _options.copies = v.round(),
                                  ),
                          ),
                        ),
                        Text('${_options.copies}'),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('彩色打印'),
                    value: _options.color,
                    onChanged: _printing
                        ? null
                        : (v) => setState(() => _options.color = v),
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('自动双面(需打印机支持)'),
                    value: _options.duplex,
                    onChanged: _printing
                        ? null
                        : (v) => setState(() => _options.duplex = v),
                  ),
                  SwitchListTile(
                    dense: true,
                    title: const Text('同时保存为默认设置'),
                    subtitle: const Text(
                      '下次沿用版式(不含页码范围/奇偶/逆序)',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: _saveAsDefault,
                    onChanged: _printing
                        ? null
                        : (v) => setState(() => _saveAsDefault = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _printing
                        ? null
                        : (_busy ? _cancelPreview : _generatePreview),
                    icon: Icon(_busy ? Icons.close : Icons.preview),
                    label: Text(_busy ? '取消预览' : '生成预览'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    // 预览是可选的:没预览也能直接打印,正在预览则先中止再打印
                    onPressed: _printing
                        ? null
                        : () async {
                            if (_busy) _cancelPreview();
                            await _startPrint();
                          },
                    icon: _printing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.print),
                    label: Text(_printing ? '打印中…' : '开始打印'),
                  ),
                ),
              ],
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _systemPrint,
                    child: const Text('改用系统打印服务(按当前版式)'),
                  ),
                ),
              ),
            if (_done)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('完成'),
                  ),
                ),
              ),
            _buildLog(),
          ],
        ),
      ),
    );
  }
}
