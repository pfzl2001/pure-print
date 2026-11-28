// 纯净打印 - 手机端主界面:打印机发现、分享导入、内容选择、默认设置、状态与记录
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../discovery/printer_discovery.dart';
import '../ipp/ipp_client.dart';
import '../print/print_service.dart';
import '../print/system_print.dart';
import '../share/share_handler.dart';
import '../storage/app_store.dart';
import 'about_page.dart';
import 'history_page.dart';
import 'layout_editor.dart';
import 'print_settings_page.dart';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _discovery = PrinterDiscovery();
  final _printService = PrintService();
  final List<DiscoveredPrinter> _printers = [];
  DiscoveredPrinter? _selected;
  String? _lastPrinterHost; // 仅用于恢复 mDNS 自动发现的设备
  bool _scanning = false;
  final _log = <String>[];

  final _options = PrintOptions();

  bool _wifiBound = false;
  String _ssid = '';
  List<String>? _pendingShare;

  @override
  void initState() {
    super.initState();
    _discovery.stream.listen((dp) {
      if (!mounted) return;
      setState(() {
        if (!_printers.any((p) => p.printer.host == dp.printer.host)) {
          _printers.add(dp);
        }
        // 「上次使用的打印机」只对 mDNS 自动发现的设备恢复;手动 IP 不落盘
        if (_selected == null &&
            dp.source == 'mDNS' &&
            _lastPrinterHost != null &&
            dp.printer.host == _lastPrinterHost) {
          _selected = dp;
        }
      });
    });
    ShareHandler.onFiles = _handleSharedFiles;
    _restoreLocalState();
    _startScan();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await ShareHandler.takeInitial();
      if (initial.isNotEmpty && mounted) await _handleSharedFiles(initial);
    });
  }

  Future<void> _restoreLocalState() async {
    final saved = await AppStore.loadOptions();
    if (!mounted) return;
    setState(() {
      _options.copies = saved.copies;
      _options.color = saved.color;
      _options.duplex = saved.duplex;
      _options.renderDpi = saved.renderDpi;
      _options.paper = saved.paper;
      _options.paperWmm = saved.paperWmm;
      _options.paperHmm = saved.paperHmm;
      _options.orientation = saved.orientation;
      _options.rows = saved.rows;
      _options.cols = saved.cols;
      _options.marginMm = saved.marginMm;
      _options.gapMm = saved.gapMm;
      _options.fit = saved.fit;
      _options.scalePct = saved.scalePct;
      _options.offsetPct = saved.offsetPct;
      _options.sheetBorder = saved.sheetBorder;
      // 页码范围/奇偶/逆序不跨文档继承
      _options.pageRange = '';
      _options.parity = 'all';
      _options.reverse = false;
    });

    // 手动添加的 IP 不再从磁盘恢复:进程结束后自然消失,不依赖退出回调。
    // 只保留 mDNS 设备的「上次使用」记忆,由发现流异步匹配后选中。
    final last = await AppStore.loadLastPrinter();
    if (mounted) _lastPrinterHost = last;

    final wifi = await ShareHandler.wifiInfo();
    if (!mounted) return;
    setState(() {
      _wifiBound = wifi['bound'] as bool? ?? false;
      _ssid = wifi['ssid'] as String? ?? '';
    });
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    try {
      await _discovery.start();
    } catch (e) {
      _addLog('扫描启动失败: $e(可尝试手动添加 IP)');
    }
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log.add('[${TimeOfDay.now().format(context)}] $msg'));
  }

  Future<void> _addManual() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加打印机'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '打印机 IP 地址',
            hintText: '例如 192.168.1.100',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('添加')),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    final dp = _discovery.addManual(ip);
    _addLog('已手动添加 $ip(仅本次运行有效,退出后自动清除),正在探测...');
    _selectPrinter(dp);
  }

  void _selectPrinter(DiscoveredPrinter dp) {
    setState(() => _selected = dp);
    // 手动输入的 IP 不写入磁盘,只有自动发现的设备才记忆
    if (dp.source == 'mDNS') {
      AppStore.saveLastPrinter(dp.printer.host);
    }
    _testConnection(dp);
    final pending = _pendingShare;
    if (pending != null) {
      _pendingShare = null;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _handleSharedFiles(pending);
      });
    }
  }

  /// 移除手动添加的打印机(带确认)。mDNS 自动发现的设备不提供删除:
  /// 它们会在下次扫描时重新出现,删除没有实际意义。
  Future<void> _removePrinter(DiscoveredPrinter dp) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除打印机'),
        content: Text('确定移除手动添加的 '
            '${dp.printer.host}:${dp.printer.port} 吗?\n\n'
            '手动添加的地址仅保存在本次运行期间,退出应用后会自动清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _discovery.removeManual(dp.printer.host, port: dp.printer.port);
    final wasSelected = _selected == dp;
    setState(() {
      _printers.removeWhere((p) =>
          p.source == '手动' &&
          p.printer.host == dp.printer.host &&
          p.printer.port == dp.printer.port);
      if (wasSelected) {
        _selected = _printers.isEmpty ? null : _printers.first;
      }
    });
    if (wasSelected) await AppStore.clearLastPrinter();
    _addLog('已移除手动添加的打印机 ${dp.printer.host}');
  }

  Future<void> _testConnection(DiscoveredPrinter dp) async {
    try {
      final (caps, endpoint) = await _printService.probe(dp.printer);
      _addLog('✅ 连接成功: ${caps.makeAndModel.isEmpty ? dp.printer.host : caps.makeAndModel}'
          ' · ${endpoint.transport == IppTransport.upgrade ? "TLS 升级加密" : (endpoint.transport == IppTransport.tls ? "IPPS 加密" : "IPP 明文")} ${endpoint.host}:${endpoint.port}${endpoint.path}');
      if (caps.documentFormats.isNotEmpty) {
        _addLog('支持格式: ${caps.documentFormats.join(", ")}');
      }
    } catch (e) {
      _addLog('❌ 连接失败: $e');
    }
  }

  Future<void> _showPrinterState() async {
    final dp = _selected;
    if (dp == null) return _showTip('请先选择打印机');
    try {
      final s = await _printService.probeState(dp.printer);
      _addLog('设备状态: ${s.summary}');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('打印机状态'),
          content: Text([
            '设备: ${dp.printer.name.isEmpty ? dp.printer.host : dp.printer.name}',
            s.summary,
            if (s.reasons.isNotEmpty) '原因: ${s.reasons.join(", ")}',
            if (s.knownMarkerLevels.isNotEmpty)
              '各色墨量: ${s.knownMarkerLevels.map((v) => "$v%").join(" / ")}'
            else
              '该机型未上报具体墨量(marker-levels 为未知值)',
          ].join('\n\n')),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    } catch (e) {
      _addLog('❌ 状态查询失败: $e');
    }
  }

  void _showTip(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  // ---------------- 分享导入(支持多文件) ----------------
  Future<void> _handleSharedFiles(List<String> paths) async {
    if (!mounted || paths.isEmpty) return;
    _addLog('收到 ${paths.length} 个分享文件,正在识别格式...');
    final usable = <SharedDocument>[];
    for (final p in paths) {
      final d = await classifySharedFile(p);
      if (d.supported) usable.add(d);
    }
    if (!mounted) return;
    if (usable.isEmpty) {
      _addLog('❌ 暂不支持该文件格式(支持 图片 / PDF / docx / xlsx)');
      _showTip('暂不支持该文件格式,可用「系统打印」兜底');
      return;
    }
    if (_selected == null) {
      if (_printers.isNotEmpty) {
        _selectPrinter(_printers.first);
      } else {
        _pendingShare = paths;
        _addLog('📥 文件已暂存,选好打印机后会自动继续');
        _showTip('请先选择或添加打印机,文件已暂存');
        return;
      }
    }
    _addLog('导入 ${usable.length} 个可打印文件,按选择顺序合并排版');
    await _openPrintSettings([for (final d in usable) d.path]);
  }

  // ---------------- 选文件 → 打印设置页 ----------------
  Future<void> _pickAndPrint(ContentType type) async {
    List<String> paths = [];
    if (type == ContentType.photo && !Platform.isWindows) {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x?.path != null) paths = [x!.path];
    } else {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: type == ContentType.pdf
            ? ['pdf']
            : type == ContentType.office
                ? ['docx', 'xlsx', 'doc', 'xls']
                : ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
      );
      paths = [for (final f in files) if (f.path != null) f.path!];
    }
    if (paths.isEmpty || !mounted) return;
    await _openPrintSettings(paths);
  }

  Future<void> _openPrintSettings(List<String> paths) async {
    final dp = _selected;
    if (dp == null) {
      _showTip('请先选择打印机');
      return;
    }
    if (dp.source == 'mDNS') {
      await AppStore.saveLastPrinter(dp.printer.host);
    }
    if (!mounted) return;
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PrintSettingsPage(
          filePaths: paths,
          printer: dp.printer,
          defaults: _options.copy(),
          onSaveDefault: _applyOptions,
        ),
      ),
    );
  }

  void _applyOptions(PrintOptions o) {
    setState(() {
      _options.copies = o.copies;
      _options.color = o.color;
      _options.duplex = o.duplex;
      _options.renderDpi = o.renderDpi;
      _options.paper = o.paper;
      _options.paperWmm = o.paperWmm;
      _options.paperHmm = o.paperHmm;
      _options.orientation = o.orientation;
      _options.rows = o.rows;
      _options.cols = o.cols;
      _options.marginMm = o.marginMm;
      _options.gapMm = o.gapMm;
      _options.fit = o.fit;
      _options.scalePct = o.scalePct;
      _options.offsetPct = o.offsetPct;
      _options.sheetBorder = o.sheetBorder;
      _options.pageRange = '';
      _options.parity = 'all';
      _options.reverse = false;
    });
    AppStore.saveOptions(_options);
    _addLog('已保存默认打印设置');
  }

  Future<void> _pickAndSystemPrint() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'xlsx', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (files.isEmpty || files.first.path == null) return;
    final path = files.first.path!;
    _addLog('使用系统打印服务: ${path.split(Platform.pathSeparator).last}');
    try {
      final ok = await SystemPrintService.printFile(path, path.split(Platform.pathSeparator).last);
      _addLog(ok ? '✅ 已提交到系统打印队列' : '已取消系统打印');
    } catch (e) {
      _addLog('❌ 系统打印失败: $e');
    }
  }

  Future<void> _openScanPage() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ScanPage(
          printer: _selected?.printer,
          defaults: _options.copy(),
          onSaveDefault: _applyOptions,
        ),
      ),
    );
  }

  @override
  void dispose() {
    ShareHandler.onFiles = null;
    _discovery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('纯净打印'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '默认打印设置',
            onPressed: _openSettings,
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'history') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage()));
              } else if (v == 'state') {
                await _showPrinterState();
              } else if (v == 'about') {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('打印历史')),
              PopupMenuItem(value: 'state', child: Text('设备状态 / 墨量')),
              PopupMenuItem(value: 'about', child: Text('关于与法律声明')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildPrinterSection(),
          const Divider(height: 1),
          _buildContentButtons(),
          const Divider(height: 1),
          _buildLogView(),
        ],
      ),
    );
  }

  Widget _buildPrinterSection() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('打印机', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              if (_scanning)
                const SizedBox(
                    width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const Spacer(),
              TextButton.icon(
                  onPressed: _addManual,
                  icon: const Icon(Icons.add),
                  label: const Text('手动添加')),
              TextButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新扫描')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text('手动添加的 IP 仅本次运行有效,退出应用后自动清除;也可在列表中单独移除',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ),
          if (!Platform.isWindows)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Row(
                children: [
                  Icon(_wifiBound ? Icons.wifi : Icons.wifi_off,
                      size: 15, color: _wifiBound ? Colors.green[700] : Colors.orange[800]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _wifiBound
                          ? 'WiFi${_ssid.isNotEmpty ? " · $_ssid" : ""} · 打印流量已绑定局域网'
                          : '未检测到 WiFi 绑定,打印可能失败;请连接打印机所在 WiFi',
                      style: TextStyle(
                          fontSize: 11,
                          color: _wifiBound ? Colors.green[700] : Colors.orange[800]),
                    ),
                  ),
                ],
              ),
            ),
          if (_printers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  _scanning ? '正在搜索局域网打印机...' : '未发现打印机,请确认与打印机在同一 WiFi,或手动添加 IP',
                  style: TextStyle(color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ...List.generate(_printers.length, (i) {
              final dp = _printers[i];
              final selected = _selected == dp;
              return Card(
                elevation: selected ? 2 : 0,
                color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
                child: ListTile(
                  leading: const Icon(Icons.print),
                  title: Text(dp.printer.name.isEmpty ? dp.printer.host : dp.printer.name),
                  subtitle: Text(
                      '${dp.printer.host}:${dp.printer.port}${dp.printer.path} · ${dp.source}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dp.source == '手动')
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          color: Colors.red[700],
                          tooltip: '移除手动添加的打印机',
                          onPressed: () => _removePrinter(dp),
                        ),
                      IconButton(
                        icon: const Icon(Icons.wifi_tethering),
                        tooltip: '测试连接',
                        onPressed: () => _selectPrinter(dp),
                      ),
                      if (selected) const Icon(Icons.check_circle, color: Colors.green),
                    ],
                  ),
                  onTap: () => _selectPrinter(dp),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildContentButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _contentButton(Icons.photo, '打印照片', ContentType.photo),
          _contentButton(Icons.picture_as_pdf, '打印 PDF', ContentType.pdf),
          _contentButton(Icons.description, '办公文档', ContentType.office),
          _contentButton(Icons.settings_applications, '系统打印', null),
          FilledButton.tonalIcon(
            onPressed: _openScanPage,
            icon: const Icon(Icons.document_scanner),
            label: const Text('扫描'),
          ),
        ],
      ),
    );
  }

  Widget _contentButton(IconData icon, String label, ContentType? type) {
    return FilledButton.tonalIcon(
      onPressed: () => type == null ? _pickAndSystemPrint() : _pickAndPrint(type),
      icon: Icon(icon),
      label: Text(label),
    );
  }

  Widget _buildLogView() {
    return Expanded(
      child: Container(
        width: double.infinity,
        color: Colors.grey[100],
        padding: const EdgeInsets.all(12),
        child: _log.isEmpty
            ? Center(
                child: Text('选择打印机和内容后,这里会显示打印进度\n'
                    '支持一次选择多个文件合并排版;也可从微信「分享到 纯净打印」',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[500])))
            : ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(_log[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
      ),
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 20, top: 0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('默认打印设置', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('作为每次打印的初始值,选完文件后仍可在打印页单独调整',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 8),
                LayoutEditor(
                  options: _options,
                  onChange: (mutate) => setSheet(() => mutate(_options)),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      AppStore.saveOptions(_options);
                      _addLog('已保存默认打印设置');
                      Navigator.pop(ctx);
                    },
                    child: const Text('保存默认设置'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
