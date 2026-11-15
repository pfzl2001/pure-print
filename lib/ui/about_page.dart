// 关于 / 法律声明 / 第三方开源许可
import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于与法律声明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _section('独立开发声明', const [
            '本应用为独立开发的局域网打印工具,使用 IPP (RFC 8011)、'
                'mDNS (RFC 6763)、AirPrint 等公开标准与操作系统公开 API 实现。',
            '未使用任何商业打印 App 的代码、dex、so、界面布局、图标、文案、'
                '商标、私有 SDK、密钥或服务端接口;不包含广告、统计或账号体系。',
          ]),
          _section('数据与权限', const [
            '文件只在本地处理,打印数据仅通过局域网直接发送给你自己选择的打印机 IP,'
                '不经过任何第三方服务器,不上传、不留存于云端。',
            'Android 仅申请 INTERNET、ACCESS_NETWORK_STATE、ACCESS_WIFI_STATE、'
                'CHANGE_WIFI_MULTICAST_STATE,用于局域网发现与打印通信;'
                '不申请通讯录、位置、短信、电话或外部存储等敏感权限。',
            '从其他应用「分享到」的文件会被复制到本应用私有缓存目录,'
                '仅用于本次打印,不对外共享。',
          ]),
          _section('商标与协议', const [
            'IPP / AirPrint / mDNS 等协议为公开标准;AirPrint、Epson、'
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
