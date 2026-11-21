// 关于 / 法律声明 / 第三方开源许可 / 应用内更新
import 'dart:io';
import 'package:flutter/services.dart' show PlatformException, rootBundle;
import 'package:material_ui/material_ui.dart';
import '../update/updater.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _localVersion = '读取中…';
  bool _checked = false;
  bool _checking = false;
  bool _downloading = false;
  UpdateInfo? _update;
  String? _error;
  int _received = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await AppUpdater.currentVersion();
    if (mounted) setState(() => _localVersion = v);
  }

  void _showTip(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _update = null;
      _checked = false;
    });
    try {
      final info = await AppUpdater.check();
      final local = await AppUpdater.currentVersion();
      if (!mounted) return;
      final newer = AppUpdater.isNewer(info.version, local);
      setState(() {
        _localVersion = local;
        _update = newer ? info : null;
        _checked = true;
      });
      if (!newer) _showTip('当前已是最新版本 $local');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = '系统通道错误: ${e.message ?? e.code}');
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst(RegExp(r'^[^:]+: '), '');
        setState(() => _error = msg);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final info = _update;
    if (info == null || _downloading) return;
    setState(() {
      _downloading = true;
      _received = 0;
      _total = info.size;
    });
    try {
      final path = await AppUpdater.downloadApk(info, (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total;
          });
        }
      });
      if (!mounted) return;
      if (Platform.isAndroid) {
        await AppUpdater.installApk(path);
      } else {
        _showTip('安装包已保存到 $path');
      }
    } on PlatformException catch (e) {
      if (mounted) _showTip('安装失败: ${e.message ?? e.code}');
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst(RegExp(r'^[^:]+: '), '');
        _showTip('下载失败: $msg');
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Widget _buildUpdateCard() => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update, size: 19),
                  const SizedBox(width: 8),
                  const Text('软件更新',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('当前 $_localVersion',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _checking || _downloading ? null : _check,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('检查更新'),
                  ),
                  if (_checking)
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_checked && _update == null && _error == null && !_checking)
                    Text('已是最新版本',
                        style: TextStyle(fontSize: 12, color: Colors.green[700])),
                  if (_update != null && !_downloading && Platform.isAndroid)
                    FilledButton.icon(
                      onPressed: _downloadAndInstall,
                      icon: const Icon(Icons.download, size: 16),
                      label: Text('下载并安装 ${_update!.version}'),
                    ),
                ],
              ),
              if (_update != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('发现新版本 ${_update!.tag} · ${_update!.sizeText}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 6),
                      Text(
                        _update!.notes.isEmpty
                            ? '（该发布未提供说明）'
                            : _update!.notes.substring(
                                0,
                                _update!.notes.length > 320
                                    ? 320
                                    : _update!.notes.length),
                        style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                      ),
                      if (!Platform.isAndroid) ...[
                        const SizedBox(height: 8),
                        SelectableText(kReleasePage,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.blue)),
                        Text('桌面端请从发布页下载后解压使用',
                            style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                      ],
                    ],
                  ),
                ),
              ],
              if (_downloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _total > 0
                      ? (_received / _total).clamp(0.0, 1.0).toDouble()
                      : null,
                ),
                const SizedBox(height: 6),
                Text(
                  '已下载 ${(_received / 1048576).toStringAsFixed(1)} MB'
                  '${_total > 0 ? " / ${(_total / 1048576).toStringAsFixed(1)} MB" : ""}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text('检查失败: $_error',
                    style: TextStyle(fontSize: 12, color: Colors.red[700])),
                const SizedBox(height: 4),
                Text('检查更新需要当前 WiFi 能访问互联网。若该 WiFi 仅用于连接打印机，'
                    '请连接到可上网的网络后重试。',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ],
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于与法律声明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildUpdateCard(),
          _section('独立开发声明', const [
            '本应用为独立开发的局域网打印工具,使用 IPP (RFC 8011)、'
                'mDNS (RFC 6763)、AirPrint 等公开标准与操作系统公开 API 实现。',
            '未使用任何商业打印 App 的代码、dex、so、界面布局、图标、文案、'
                '商标、私有 SDK、密钥或服务端接口;不包含广告、统计或账号体系。',
          ]),
          _section('数据与权限', const [
            '文件只在本地处理,打印数据仅通过局域网直接发送给你自己选择的打印机 IP,'
                '不经过任何第三方服务器,不上传、不留存于云端。',
            '应用内更新会访问本项目 GitHub Releases 查询版本并下载安装包,'
                '下载文件仅保存在应用私有缓存,经 SHA-256 校验后由系统安装器安装。',
            'Android 仅申请 INTERNET、ACCESS_NETWORK_STATE、ACCESS_WIFI_STATE、'
                'CHANGE_WIFI_MULTICAST_STATE、REQUEST_INSTALL_PACKAGES;'
                '不申请通讯录、位置、短信、电话或外部存储等敏感权限。',
            '从其他应用「分享到」的文件会被复制到本应用私有缓存目录,'
                '仅用于本次打印,不对外共享。',
          ]),
          _section('商标与协议', const [
            'IPP / mDNS / AirPrint 等协议为公开标准;AirPrint、Epson、'
                '以及各打印机品牌名称与商标归各自权利人所有。',
            '本应用仅实现协议互操作,不代表任何打印机厂商官方产品,也不提供官方背书。',
          ]),
          _section('开源与许可', const [
            '本项目源代码采用 Apache License 2.0 开源,详见仓库 LICENSE 文件。',
            '随附中文字体取自 AOSP (android-4.4.4_r2),同为 Apache-2.0;'
                '第三方依赖许可证全文见下方清单,由 tool/generate_notices.py 自动生成。',
          ]),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('查看第三方许可证全文'),
              subtitle: const Text('覆盖 pubspec.lock 中全部直接与传递依赖'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LicenseTextPage()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<String> lines) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...lines.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(s, style: const TextStyle(fontSize: 13, height: 1.45)),
                  )),
            ],
          ),
        ),
      );
}

/// 许可证全文按行懒加载渲染,避免一次性把上百 KB 文本塞进单个 Text
class LicenseTextPage extends StatelessWidget {
  const LicenseTextPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('第三方许可证全文')),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/licenses/THIRD_PARTY_NOTICES.txt'),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final lines = snap.data!.split('\n');
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (_, i) => SelectableText(
              lines[i].isEmpty ? ' ' : lines[i],
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 10.5, height: 1.35),
            ),
          );
        },
      ),
    );
  }
}
