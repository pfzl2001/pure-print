// 扫描页:发现 eSCL 扫描仪 → 读取能力 → 设置参数 → 扫描 → 预览 / 保存 / 送去打印
// 使用标准 eSCL(AirScan / Mopria)协议,不依赖任何厂商 SDK
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ipp/ipp_client.dart';
import '../print/print_service.dart';
import '../scan/escl_client.dart';
import '../scan/escl_discovery.dart';
import '../scan/scan_files.dart';
import 'print_settings_page.dart';

// 扫描设置记忆:下次进入扫描页自动恢复上次选择
const String _kPrefResolution = 'scan_resolution';
const String _kPrefColorMode = 'scan_color_mode';
const String _kPrefFormat = 'scan_document_format';
const String _kPrefIntent = 'scan_intent';
const String _kPrefCompression = 'scan_compression';

class ScanPage extends StatefulWidget {
  final IppPrinter? printer;
  final PrintOptions defaults;
  final void Function(PrintOptions options) onSaveDefault;

  const ScanPage({
    super.key,
    this.printer,
    required this.defaults,
    required this.onSaveDefault,
  });

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _discovery = EsclDiscovery();
  final _client = EsclClient();
  final List<EsclDevice> _devices = [];
  EsclDevice? _selected;
  EsclCapabilities? _caps;
  final _params = ScanParams();
  ScanResult? _result;
  String? _savedPath;

  final ValueNotifier<List<String>> _log = ValueNotifier<List<String>>([]);
  final TextEditingController _ipController = TextEditingController();
  bool _busy = false;
  bool _scanning = false;
  late final Future<void> _prefsReady;

  @override
  void initState() {
    super.initState();
    _prefsReady = _loadPrefs();
    _discovery.stream.listen((d) {
      if (!mounted) return;
      setState(() {
        if (!_devices.any((x) => x.host == d.host && x.port == d.port)) {
          _devices.add(d);
        }
      });
      if (_selected == null) _select(d);
    });
    _startDiscovery();
  }

  /// 启动时恢复上次保存的扫描设置。直接改 _params 即可,
  /// 后续 _select() 会用设备能力校验合法性(_syncParams)后再刷新界面。
  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      _params.resolution = p.getInt(_kPrefResolution) ?? _params.resolution;
      _params.colorMode = p.getString(_kPrefColorMode) ?? _params.colorMode;
      _params.documentFormat =
          p.getString(_kPrefFormat) ?? _params.documentFormat;
      _params.intent = p.getString(_kPrefIntent) ?? _params.intent;
      _params.compressionFactor =
          p.getInt(_kPrefCompression) ?? _params.compressionFactor;
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kPrefResolution, _params.resolution);
      await p.setString(_kPrefColorMode, _params.colorMode);
      await p.setString(_kPrefFormat, _params.documentFormat);
      await p.setString(_kPrefIntent, _params.intent);
      await p.setInt(_kPrefCompression, _params.compressionFactor);
    } catch (_) {}
  }

  Future<void> _resetSettings() async {
    setState(() {
      _params.resolution = 200;
      _params.colorMode = 'RGB24';
      _params.documentFormat = 'image/jpeg';
      _params.intent = 'TextAndGraphic';
      _params.compressionFactor = 2;
      final c = _caps;
      if (c != null) _syncParams(c);
    });
    await _savePrefs();
    _addLog('已恢复默认扫描设置');
  }

  void _cancelScan() {
    _client.cancel();
    _addLog('正在取消扫描…');
  }

  @override
  void dispose() {
    _discovery.dispose();
    _log.dispose();
    _ipController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    if (!mounted) return;
    final next = [..._log.value, '[${TimeOfDay.now().format(context)}] $msg'];
    _log.value = next.length > 120 ? next.sublist(next.length - 120) : next;
  }

  Future<void> _startDiscovery() async {
    _addLog('正在搜索局域网扫描仪 (_uscan / _uscans)...');
    await _discovery.start();
  }

  void _syncParams(EsclCapabilities c) {
    if (!c.resolutions.contains(_params.resolution)) {
      _params.resolution = c.resolutions.first;
    }
    if (!c.colorModes.contains(_params.colorMode)) {
      _params.colorMode = c.colorModes.first;
    }
    if (!c.documentFormats.contains(_params.documentFormat)) {
      _params.documentFormat = c.documentFormats.first;
    }
    if (!c.intents.contains(_params.intent)) {
      _params.intent = c.intents.first;
    }
  }

  Future<void> _select(EsclDevice d) async {
    if (_busy || _scanning) return;
    await _prefsReady;
    setState(() {
      _selected = d;
      _caps = null;
      _result = null;
      _savedPath = null;
      _busy = true;
    });
    _addLog('正在连接 ${d.label} ...');
    try {
      final (caps, used) = await _client.probe(d);
      if (!mounted) return;
      setState(() {
        _caps = caps;
        _selected = used;
      });
      _syncParams(caps);
      await _savePrefs();
      _addLog('✅ ${caps.summary}');
      _addLog('扫描设置: ${_params.resolution} dpi · '
          '${EsclCapabilities.colorLabel(_params.colorMode)} · '
          '${_params.documentFormat}');
      _addLog('端点: ${used.uri("ScannerCapabilities")}');
      final state = await _client.status(used);
      _addLog('设备状态: $state');
    } catch (e) {
      _addLog('❌ 连接失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManual() async {
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动添加扫描仪'),
        content: TextField(
          controller: _ipController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '扫描仪 IP 地址',
            hintText: '例如 192.168.1.7',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _ipController.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    _addLog('已手动添加 $ip');
    await _select(_discovery.addManual(ip));
  }

  Future<void> _startScan() async {
    final dev = _selected;
    if (dev == null) {
      _showTip('请先选择或添加扫描仪');
      return;
    }
    if (_scanning || _busy) return;
    setState(() {
      _scanning = true;
      _result = null;
      _savedPath = null;
    });
    _log.value = <String>[];
    _addLog('扫描仪: ${dev.label}');
    try {
      final r = await _client.scan(
        dev,
        _params,
        caps: _caps,
        onProgress: _addLog,
      );
      if (!mounted) return;
      final path = await ScanFiles.save(r);
      if (!mounted) return;
      setState(() {
        _result = r;
        _savedPath = path;
      });
      _addLog('✅ 扫描完成: ${r.sizeText} · ${r.width}×${r.height}');
      _addLog('已保存到: $path');
    } catch (e) {
      final msg = e.toString();
      _addLog(msg.contains('扫描已取消') ? '已取消扫描' : '❌ 扫描失败: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _sendToPrint() async {
    final path = _savedPath;
    if (path == null) return;
    final printer = widget.printer;
    if (printer == null) {
      _showTip('请先在首页选择打印机');
      return;
    }
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PrintSettingsPage(
          filePaths: [path],
          printer: printer,
          defaults: widget.defaults.copy(),
          onSaveDefault: widget.onSaveDefault,
        ),
      ),
    );
  }

  Future<void> _share() async {
    final path = _savedPath;
    final r = _result;
    if (path == null || r == null) return;
    final ok = await ScanFiles.share(path, r.mimeType);
    if (!ok) _addLog('分享未完成或已取消');
  }

  void _showTip(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Widget _buildDevices() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.scanner, size: 20),
                  const SizedBox(width: 8),
                  const Text('扫描仪', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (_busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  TextButton.icon(
                    onPressed: _addManual,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('手动添加'),
                  ),
                  TextButton.icon(
                    onPressed: _startDiscovery,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新扫描'),
                  ),
                ],
              ),
              if (_devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    '正在搜索…若长时间未发现,请确认与打印机在同一 WiFi,或手动添加 IP',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                )
              else
                ...List.generate(_devices.length, (i) {
                  final d = _devices[i];
                  final selected = _selected?.host == d.host;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 18,
                      color: selected ? Theme.of(context).colorScheme.primary : null,
                    ),
                    title: Text(d.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '${d.host}:${d.port} · ${d.tls ? "HTTPS" : "HTTP"} · rs=${d.rs}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onTap: () => _select(d),
                  );
                }),
              if (_caps != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '✅ ${_caps!.summary}',
                    style: TextStyle(fontSize: 12, color: Colors.green[800]),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) text,
    required void Function(T?) onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: DropdownButton<T>(
                value: items.contains(value) ? value : null,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final v in items)
                    DropdownMenuItem<T>(value: v, child: Text(text(v))),
                ],
                onChanged: _scanning || _busy ? null : onChanged,
              ),
            ),
          ],
        ),
      );

  Widget _buildSettings() {
    final c = _caps;
    final resolutions = c?.resolutions ?? const [100, 200, 300, 600, 1200];
    final modes = c?.colorModes ?? const ['RGB24', 'Grayscale8', 'BlackAndWhite1'];
    final formats = c?.documentFormats ?? const ['image/jpeg', 'application/pdf'];
    final intents = c?.intents ??
        const ['Document', 'TextAndGraphic', 'Photo', 'Preview'];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Row(
              children: [
                const Text('扫描设置',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _scanning || _busy ? null : _resetSettings,
                  icon: const Icon(Icons.restore, size: 16),
                  label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          _dropdown<int>(
            label: '分辨率',
            value: _params.resolution,
            items: resolutions,
            text: (v) => '$v dpi',
            onChanged: (v) {
              setState(() => _params.resolution = v ?? 200);
              _savePrefs();
            },
          ),
          _dropdown<String>(
            label: '色彩模式',
            value: _params.colorMode,
            items: modes,
            text: EsclCapabilities.colorLabel,
            onChanged: (v) {
              setState(() => _params.colorMode = v ?? 'RGB24');
              _savePrefs();
            },
          ),
          _dropdown<String>(
            label: '输出格式',
            value: _params.documentFormat,
            items: formats,
            text: (v) => v == 'application/pdf' ? 'PDF 文档' : 'JPEG 图片',
            onChanged: (v) {
              setState(() => _params.documentFormat = v ?? 'image/jpeg');
              _savePrefs();
            },
          ),
          _dropdown<String>(
            label: '内容类型',
            value: _params.intent,
            items: intents,
            text: (v) => switch (v) {
                  'Document' => '文档',
                  'TextAndGraphic' => '文字与图形',
                  'Photo' => '照片',
                  'Preview' => '预览',
                  _ => v,
                },
            onChanged: (v) {
              setState(() => _params.intent = v ?? 'TextAndGraphic');
              _savePrefs();
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
            child: Text(
              '平板扫描(Platen) · A4 全幅 · 请把原件放在扫描仪玻璃板上',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final r = _result;
    if (r == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '扫描结果 · ${r.sizeText} · ${r.width}×${r.height}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (r.isJpeg)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  r.bytes,
                  height: 240,
                  width: double.infinity,
                  fit: BoxFit.contain,
                ),
              )
            else
              Container(
                height: 100,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Center(
                  child: Icon(Icons.picture_as_pdf, size: 40, color: Colors.red),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sendToPrint,
                    icon: const Icon(Icons.print, size: 18),
                    label: const Text('送去打印'),
                  ),
                ),
                if (ScanFiles.canShare) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('分享/保存'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLog() => ValueListenableBuilder<List<String>>(
        valueListenable: _log,
        builder: (_, lines, _) {
          if (lines.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              width: double.infinity,
              height: 160,
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
      appBar: AppBar(title: const Text('扫描')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDevices(),
            const SizedBox(height: 8),
            _buildSettings(),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _scanning ? _cancelScan : (_busy ? null : _startScan),
                icon: Icon(_scanning ? Icons.close : Icons.document_scanner),
                label: Text(_scanning ? '取消扫描' : '开始扫描'),
              ),
            ),
            _buildResult(),
            _buildLog(),
          ],
        ),
      ),
    );
  }
}
