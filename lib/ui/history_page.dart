// 打印历史:仅保存在本机,可一键清空
import 'package:material_ui/material_ui.dart';
import '../storage/app_store.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<PrintRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppStore.loadHistory();
    if (!mounted) return;
    setState(() {
      _records = list;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空打印历史'),
        content: const Text('仅删除本机记录,不影响已打印的文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await AppStore.clearHistory();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('打印历史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空记录',
            onPressed: _records.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? Center(
                  child: Text('暂无打印记录',
                      style: TextStyle(color: Colors.grey[600])))
              : ListView.separated(
                  itemCount: _records.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _records[i];
                    return ListTile(
                      leading: Icon(
                        r.success ? Icons.check_circle : Icons.error_outline,
                        color: r.success ? Colors.green : Colors.red,
                      ),
                      title: Text(r.fileName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${r.time} · ${r.printer}\n${r.result}',
                          style: const TextStyle(fontSize: 11)),
                      isThreeLine: true,
                    );
                  },
                ),
    );
  }
}
