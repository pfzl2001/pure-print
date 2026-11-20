// Windows 桌面工作台:对齐 Free2Convert「PDF 多页合一」的完整流程
//   多个文件合并 → 逐张纸预览 → 纸张/网格/边距/间距/适配/缩放/位置 → 打印
// 全部在本机处理,不上传任何文件
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

import '../ipp/ipp_client.dart';
import '../print/print_service.dart';
import '../print/system_print.dart';
import '../storage/app_store.dart';
import 'about_page.dart';
import 'history_page.dart';
import 'layout_editor.dart';

class DesktopPage extends StatefulWidget {
  const DesktopPage({super.key});
  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage> {
  final _service = PrintService();
  // 默认留空,由用户填写或从本地设置恢复;不在源码里写死任何内网设备地址
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '631');
  final _rangeController = TextEditingController();

  final List<String> _files = [];
  // 低分辨率预览成品:按需、限量、流式生成、后台 isolate 拼版;打印不复用
  // ValueNotifier 让增量生成只重绘预览区,不重建三栏工作台
  final ValueNotifier<List<Uint8List>> _preview =
      ValueNotifier<List<Uint8List>>([]);
  final ValueNotifier<String> _previewStatus = ValueNotifier<String>('');
  int _totalSheets = 0;
  bool _previewTruncated = false;
  // 日志只刷新自己的区域,不再触发整页重建
  final ValueNotifier<List<String>> _log = ValueNotifier<List<String>>([]);
  late PrintOptions _options;
  int _sheetIndex = 0;
  int _generation = 0;
  bool _busy = false;
  bool _printing = false;
  bool _dragging = false;
  bool _dropEnabled = true;
  String _deviceInfo = '未测试连接';

  @override
  void initState() {
    super.initState();
    _options = PrintOptions();
    AppStore.loadOptions().then((o) {
      if (!mounted) return;
      setState(
        () => _options = o
          ..pageRange = ''
          ..parity = 'all'
          ..reverse = false,
      );
    });
    // 手动输入的 IP 不再持久化:关闭应用后不留痕,下次启动为空。
    // 需要复用地址时用户可自行填写,或点输入框右侧的清除按钮清空当前值。
  }

  @override
  void dispose() {
    _generation++; // 让仍在跑的排版任务自行退出
    _ipController.dispose();
    _portController.dispose();
    _rangeController.dispose();
    _log.dispose();
    _preview.dispose();
    _previewStatus.dispose();
    super.dispose();
  }

  IppPrinter get _printer => IppPrinter(
    _ipController.text.trim(),
    port: int.tryParse(_portController.text.trim()) ?? 631,
    name: '局域网打印机',
  );

  String _name(String p) => p.split(Platform.pathSeparator).last;

  void _addLog(String msg) {
    if (!mounted) return;
    final next = [..._log.value, '[${TimeOfDay.now().format(context)}] $msg'];
    _log.value = next.length > 120 ? next.sublist(next.length - 120) : next;
  }

  // ---------------- 文件列表(拖入 / 选择共用) ----------------
  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择一个或多个 PDF / 图片 / 办公文档(可多选,按顺序合并)',
      type: FileType.custom,
      allowedExtensions: kPrintableExtensions,
    );
    _addPaths([
      for (final f in picked)
        if (f.path != null) f.path!,
    ], '已选择');
  }

  /// 拖入或选择的文件统一走这里:展开文件夹、过滤格式、去重、保持顺序
  void _addPaths(List<String> paths, String source) {
    if (paths.isEmpty) return;
    final r = mergeDroppedPaths(_files, paths);
    if (r.added.isEmpty) {
      _addLog(
        '$source: 没有新增文件'
        '${r.skipped.isNotEmpty ? "(${r.skipped.length} 个不支持或已存在)" : "(都已存在)"}',
      );
      return;
    }
    setState(() {
      _files
        ..clear()
        ..addAll(r.merged);
      _markDirty();
    });
    for (final s in r.skipped.take(3)) {
      _addLog('跳过不支持的文件: ${_name(s)}');
    }
    _addLog('$source: ${r.summary};当前共 ${_files.length} 个文件');
  }

  void _onDropDone(DropDoneDetails details) {
    setState(() => _dragging = false);
    _addPaths([for (final f in details.files) f.path], '拖入');
  }

  /// 弹出二级页面时临时关闭拖放,避免隐藏的 DropTarget 抢事件
  Future<void> _openPage(Widget page) async {
    setState(() => _dropEnabled = false);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() => _dropEnabled = true);
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _files.length) return;
    final p = _files.removeAt(i);
    _files.insert(j, p);
    setState(() {});
    _markDirty();
  }

  void _remove(int i) {
    final p = _files.removeAt(i);
    setState(() {});
    _addLog('已移除 ${_name(p)}');
    _markDirty();
  }

  void _clearFiles() {
    _files.clear();
    _markDirty();
    setState(() {});
    _addLog('已清空文件列表');
  }

  /// 文件列表或版式变更后,预览作废并让进行中的任务自行退出
  void _markDirty() {
    _generation++;
    _preview.value = <Uint8List>[];
    _previewStatus.value = '';
    _totalSheets = 0;
    _previewTruncated = false;
    _sheetIndex = 0;
  }

  // ---------------- 预览 / 打印 ----------------
  /// 全分辨率、全页数成品:打印 / 系统打印 / 导出 PDF 使用
  Future<List<Uint8List>> _buildFullSheets() async {
    if (_files.isEmpty) throw ArgumentError('请先添加至少一个文件');
    _options.pageRange = _rangeController.text.trim();
    return _service.buildSheetsFromPaths(_files, _options, onProgress: _addLog);
  }

  Future<void> _generatePreview() async {
    if (_busy) return;
    _markDirty();
    final token = _generation;
    _options.pageRange = _rangeController.text.trim();
    setState(() => _busy = true);
    _log.value = <String>[];
    _preview.value = <Uint8List>[];
    _previewStatus.value = '正在生成第 1 张…';
    try {
      final result = await _service.buildPreviewSheets(
        _files,
        _options,
        onProgress: _addLog,
        cancelled: () => token != _generation || !mounted,
        onSheet: (i, jpeg, total) {
          if (!mounted || token != _generation) return;
          // 首张到达即可查看,后续逐张追加
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
        '✅ 预览已生成(${result.dpi} dpi): ${result.hint} · '
        '${_options.layoutSummary}',
      );
    } on PreviewCancelledException {
      // 已被新任务、取消操作或页面退出取代
    } catch (e) {
      _addLog('❌ 预览生成失败: $e');
    } finally {
      if (mounted && token == _generation) setState(() => _busy = false);
    }
  }

  /// 用户可随时中止后台预览
  void _cancelPreview() {
    _generation++;
    _previewStatus.value = '已取消预览';
    if (mounted) setState(() => _busy = false);
    _addLog('预览已取消');
  }

  Future<void> _record(bool ok, String msg) => AppStore.addHistory(
    PrintRecord(
      time: DateTime.now().toString().substring(0, 16),
      fileName: _files.isEmpty
          ? '无文件'
          : '${_name(_files.first)} 等 ${_files.length} 个',
      printer: '${_ipController.text.trim()}:${_portController.text.trim()}',
      result: msg.length > 160 ? msg.substring(0, 160) : msg,
      success: ok,
    ),
  );

  Future<void> _printDirect() async {
    if (_printing) return;
    _options.pageRange = _rangeController.text.trim();
    setState(() {
      _printing = true;
      _log.value = <String>[];
    });
    _addLog('版式: ${_options.layoutSummary}');
    try {
      // 手动输入的 IP 不写入磁盘
      // 不复用低分辨率预览:printFiles 内部按 renderDpi 输出全部纸张
      _addLog('按 ${_options.renderDpi} dpi 全分辨率渲染全部页面…');
      final result = await _service.printFiles(
        _printer,
        _files,
        _options,
        onProgress: _addLog,
      );
      _addLog('✅ $result —— 请查看打印机出纸');
      await _record(true, result);
    } catch (e) {
      _addLog('❌ 打印失败: $e');
      await _record(false, '$e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<Uint8List> _outputPdf() async {
    final sheets = await _buildFullSheets();
    return _service.sheetsToPdf(sheets, _options);
  }

  Future<void> _systemPrint() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _outputPdf();
      _addLog(
        '已生成 ${(bytes.length / 1024).toStringAsFixed(0)} KB 的排版 PDF,调起系统打印…',
      );
      final ok = await SystemPrintService.printPdf(bytes, '纯净打印 - 多页合一');
      _addLog(ok ? '✅ 已提交到系统打印队列' : '已取消系统打印');
    } catch (e) {
      _addLog('❌ 系统打印失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportPdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _outputPdf();
      final home = Platform.environment['USERPROFILE'] ?? '.';
      final dir = Directory('$home${Platform.pathSeparator}Desktop');
      final target = Directory(await dir.exists() ? dir.path : home);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:T.-]'), '')
          .substring(0, 14);
      final file = File(
        '${target.path}${Platform.pathSeparator}纯净打印-多页合一-$stamp.pdf',
      );
      await file.writeAsBytes(bytes);
      _addLog(
        '✅ 已导出: ${file.path} (${(bytes.length / 1024).toStringAsFixed(0)} KB)',
      );
    } catch (e) {
      _addLog('❌ 导出失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    _addLog('正在探测 ${_printer.host}:${_printer.port} ...');
    try {
      final (caps, ep) = await _service.probe(_printer);
      setState(
        () => _deviceInfo = caps.makeAndModel.isEmpty
            ? ep.host
            : caps.makeAndModel,
      );
      _addLog('✅ 连接成功: $_deviceInfo · ${ep.endpoint}');
    } catch (e) {
      setState(() => _deviceInfo = '连接失败');
      _addLog('❌ 连接失败: $e');
    }
  }

  Future<void> _showState() async {
    try {
      final s = await _service.probeState(_printer);
      _addLog('设备状态: ${s.summary}');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('打印机状态'),
          content: Text(
            [
              _deviceInfo,
              s.summary,
              if (s.reasons.isNotEmpty) '原因: ${s.reasons.join(", ")}',
              if (s.knownMarkerLevels.isNotEmpty)
                '各色墨量: ${s.knownMarkerLevels.map((v) => "$v%").join(" / ")}'
              else
                '该机型未上报具体墨量',
            ].join('\n\n'),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      _addLog('❌ 状态查询失败: $e');
    }
  }

  // ---------------- UI ----------------
  Widget _card(String title, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          child,
        ],
      ),
    ),
  );

  Widget _buildFilePanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Text(
            '文件 (${_files.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            tooltip: '添加文件(可多选)',
            onPressed: _pickFiles,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all, size: 20),
            tooltip: '清空',
            onPressed: _clearFiles,
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '按列表顺序合并为连续排版;可直接把文件/文件夹拖进窗口',
        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[300]!),
            borderRadius: BorderRadius.circular(6),
          ),
          child: _files.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '把文件拖到这里\n或点击右上角 + 添加\n支持 PDF / 图片 / Word / Excel,文件夹也可以',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) => ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 11,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                    title: Text(
                      _name(_files[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    subtitle: Text(
                      contentTypeLabel(
                        contentTypeOf(_files[i]) ?? ContentType.pdf,
                      ),
                      style: const TextStyle(fontSize: 10),
                    ),
                    trailing: SizedBox(
                      width: 104,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: () => _move(i, -1),
                            child: const Icon(Icons.arrow_upward, size: 16),
                          ),
                          InkWell(
                            onTap: () => _move(i, 1),
                            child: const Icon(Icons.arrow_downward, size: 16),
                          ),
                          InkWell(
                            onTap: () => _remove(i),
                            child: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    ],
  );

  /// 预览图只按显示尺寸解码:桌面预览区较大,取约 900 逻辑像素 × DPR
  static int _previewDecodeWidth(BuildContext context) {
    final w = (900 * MediaQuery.devicePixelRatioOf(context)).round();
    return w < 400 ? 400 : (w > 2000 ? 2000 : w);
  }

  Widget _buildPreviewBody(List<Uint8List> sheets) {
    if (sheets.isEmpty) {
      if (_busy) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 10),
              Text('正在生成第 1 张预览…', style: TextStyle(fontSize: 12)),
            ],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.preview, size: 44, color: Colors.grey[400]),
            const SizedBox(height: 10),
            const Text('点击「生成预览」查看排版效果', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            Text(
              '按需生成 · 首张秒出 · 打开页面不自动渲染\n预览与打印版式一致,预览使用低分辨率缩略图',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }
    final idx = _sheetIndex.clamp(0, sheets.length - 1);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: RepaintBoundary(
        child: Image.memory(
          sheets[idx],
          fit: BoxFit.contain,
          // 只按显示尺寸解码,避免把整张位图放进内存/GPU
          cacheWidth: _previewDecodeWidth(context),
          gaplessPlayback: true,
        ),
      ),
    );
  }

  /// 预览区独立刷新:增量生成时只重绘这一栏
  Widget _buildPreviewPanel() => ValueListenableBuilder<List<Uint8List>>(
    valueListenable: _preview,
    builder: (_, sheets, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('拼版预览', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: _printing
                  ? null
                  : (_busy ? _cancelPreview : _generatePreview),
              icon: Icon(_busy ? Icons.close : Icons.preview, size: 18),
              label: Text(
                _busy ? '取消预览' : '生成预览',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _sheetIndex > 0
                  ? () => setState(() => _sheetIndex--)
                  : null,
            ),
            Text(
              sheets.isEmpty
                  ? '0 / 0'
                  : '第 ${_sheetIndex + 1} / ${sheets.length} 张'
                        '${_previewTruncated && !_busy ? " (共 $_totalSheets 张)" : ""}',
              style: const TextStyle(fontSize: 12),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _sheetIndex < sheets.length - 1
                  ? () => setState(() => _sheetIndex++)
                  : null,
            ),
          ],
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
        if (_previewTruncated && !_busy)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '为保持流畅,仅预览 $_totalSheets 张中的 ${sheets.length} 张;打印仍输出全部',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: _buildPreviewBody(sheets),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 108,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(6),
            ),
            child: ValueListenableBuilder<List<String>>(
              valueListenable: _log,
              builder: (_, lines, _) => lines.isEmpty
                  ? const Text(
                      '操作日志',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    )
                  : ListView.builder(
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Text(
                        lines[i],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildSettingsPanel() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _card(
          '打印机(IPP 直连,本机局域网)',
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _ipController,
                        decoration: InputDecoration(
                          labelText: 'IP 地址',
                          hintText: '例如 192.168.1.100',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: '清除 IP 并删除已保存的地址',
                            onPressed: () {
                              _ipController.clear();
                              AppStore.clearLastPrinter();
                              setState(() => _deviceInfo = '未测试连接');
                            },
                          ),
                        ),
                        onChanged: (_) => setState(() => _deviceInfo = '未测试连接'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _deviceInfo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ),
                    TextButton(
                      onPressed: _testConnection,
                      child: const Text('测试连接'),
                    ),
                    TextButton(onPressed: _showState, child: const Text('状态')),
                  ],
                ),
              ],
            ),
          ),
        ),
        _card(
          '版式(多页合一)',
          LayoutEditor(
            options: _options,
            enabled: !_busy && !_printing,
            onChange: (mutate) => setState(() {
              mutate(_options);
              _markDirty();
            }),
          ),
        ),
        _card(
          '页面选择',
          PageSelectionEditor(
            options: _options,
            rangeController: _rangeController,
            enabled: !_busy && !_printing,
            onChange: (mutate) => setState(() {
              mutate(_options);
              _markDirty();
            }),
          ),
        ),
        _card(
          '打印选项',
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Text('份数', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: _options.copies.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: '${_options.copies}',
                        onChanged: (v) =>
                            setState(() => _options.copies = v.round()),
                      ),
                    ),
                    Text('${_options.copies}'),
                  ],
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: const Text('彩色打印', style: TextStyle(fontSize: 13)),
                value: _options.color,
                onChanged: (v) => setState(() => _options.color = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: const Text('自动双面', style: TextStyle(fontSize: 13)),
                value: _options.duplex,
                onChanged: (v) => setState(() => _options.duplex = v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '所有文件仅在本机处理,不上传服务器',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ),
        FilledButton.icon(
          onPressed: (_busy || _printing || _files.isEmpty)
              ? null
              : _printDirect,
          icon: _printing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.print),
          label: Text(_printing ? '正在打印…' : '直接打印到 IPP 打印机'),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_busy || _files.isEmpty) ? null : _systemPrint,
                icon: const Icon(Icons.print_disabled, size: 16),
                label: const Text('系统打印', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_busy || _files.isEmpty) ? null : _exportPdf,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('导出 PDF', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: () async {
            await AppStore.saveOptions(_options);
            _addLog('✅ 已保存为默认版式设置');
          },
          icon: const Icon(Icons.bookmark_add, size: 16),
          label: const Text('保存当前版式为默认'),
        ),
      ],
    ),
  );

  /// 拖拽悬停时的整窗高亮提示
  Widget _buildDropOverlay() => Positioned.fill(
    child: IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.13),
            border: Border.all(color: Colors.blue, width: 3),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, size: 68, color: Colors.blue[700]),
                const SizedBox(height: 12),
                Text(
                  '松开即可加入打印列表',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[800],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '支持 PDF / 图片 / Word / Excel,也可以直接拖入整个文件夹',
                  style: TextStyle(fontSize: 13, color: Colors.blue[700]),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: _dropEnabled,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _onDropDone,
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: const Text('纯净打印 · 多页合一工作台'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '打印历史',
                  onPressed: () => _openPage(const HistoryPage()),
                ),
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  tooltip: '关于与法律声明',
                  onPressed: () => _openPage(const AboutPage()),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 250, child: _buildFilePanel()),
                  const SizedBox(width: 10),
                  Expanded(child: _buildPreviewPanel()),
                  const SizedBox(width: 10),
                  SizedBox(width: 330, child: _buildSettingsPanel()),
                ],
              ),
            ),
          ),
          if (_dragging) _buildDropOverlay(),
        ],
      ),
    );
  }
}
