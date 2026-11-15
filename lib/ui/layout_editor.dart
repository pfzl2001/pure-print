// 共享版式参数控件:Android 单次打印设置页 与 Windows 工作台复用
// 覆盖 Free2Convert「PDF 多页合一」的全部可调项
import 'package:material_ui/material_ui.dart';
import '../print/print_service.dart';

typedef ChangeOptions = void Function(void Function(PrintOptions o) mutate);

class LayoutEditor extends StatelessWidget {
  final PrintOptions options;
  final ChangeOptions onChange;
  final bool enabled;

  const LayoutEditor({
    super.key,
    required this.options,
    required this.onChange,
    this.enabled = true,
  });

  void _set(void Function(PrintOptions o) f) => onChange(f);

  Widget _line(String label, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 76, child: Text(label, style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      );

  Widget _dropdown<T>(T value, List<DropdownMenuItem<T>> items, ValueChanged<T?>? onChanged) =>
      DropdownButton<T>(
        value: value,
        items: items,
        isExpanded: true,
        isDense: true,
        onChanged: enabled ? onChanged : null,
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: Row(
          children: [
            SizedBox(width: 76, child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: Slider(
                value: value.clamp(min, max).toDouble(),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: enabled ? onChanged : null,
              ),
            ),
            SizedBox(
              width: 62,
              child: Text(
                '${value.toStringAsFixed(0)}$suffix',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final o = options;
    final preset = gridPresetLabel(o.rows, o.cols);
    final customGrid = preset == '自定义行列…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _line('纸张', _dropdown<String>(
          o.paper,
          kPaperLabels.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
              .toList(),
          (v) => _set((x) => x.paper = v!),
        )),
        if (o.paper == 'custom') ...[
          _slider(
              label: '自定义宽',
              value: o.paperWmm,
              min: 50,
              max: 500,
              divisions: 450,
              suffix: 'mm',
              onChanged: (v) => _set((x) => x.paperWmm = v.roundToDouble())),
          _slider(
              label: '自定义高',
              value: o.paperHmm,
              min: 50,
              max: 500,
              divisions: 450,
              suffix: 'mm',
              onChanged: (v) => _set((x) => x.paperHmm = v.roundToDouble())),
        ],
        _line('方向', _dropdown<String>(
          o.orientation,
          const [
            DropdownMenuItem(value: 'portrait', child: Text('竖版')),
            DropdownMenuItem(value: 'landscape', child: Text('横版')),
          ],
          (v) => _set((x) => x.orientation = v!),
        )),
        _line('网格', _dropdown<String>(
          preset,
          kGridPresets.keys
              .map((k) => DropdownMenuItem(value: k, child: Text(k)))
              .toList(),
          (v) => _set((x) {
            final g = kGridPresets[v]!;
            if (g[0] > 0) {
              x.rows = g[0];
              x.cols = g[1];
            }
          }),
        )),
        if (customGrid) ...[
          _line('行数', _dropdown<int>(
            o.rows,
            [for (var i = 1; i <= 8; i++) DropdownMenuItem(value: i, child: Text('$i 行'))],
            (v) => _set((x) => x.rows = v!),
          )),
          _line('列数', _dropdown<int>(
            o.cols,
            [for (var i = 1; i <= 8; i++) DropdownMenuItem(value: i, child: Text('$i 列'))],
            (v) => _set((x) => x.cols = v!),
          )),
        ],
        _line('适配', _dropdown<String>(
          o.fit,
          const [
            DropdownMenuItem(value: 'contain', child: Text('完整显示(不裁切)')),
            DropdownMenuItem(value: 'cover', child: Text('铺满裁切(无白边)')),
          ],
          (v) => _set((x) => x.fit = v!),
        )),
        _slider(
            label: '页边距',
            value: o.marginMm,
            min: 0,
            max: 30,
            divisions: 30,
            suffix: 'mm',
            onChanged: (v) => _set((x) => x.marginMm = v.roundToDouble())),
        _slider(
            label: '格间距',
            value: o.gapMm,
            min: 0,
            max: 20,
            divisions: 20,
            suffix: 'mm',
            onChanged: (v) => _set((x) => x.gapMm = v.roundToDouble())),
        _slider(
            label: '内容缩放',
            value: o.scalePct,
            min: 50,
            max: 150,
            divisions: 100,
            suffix: '%',
            onChanged: (v) => _set((x) => x.scalePct = v.roundToDouble())),
        _slider(
            label: '上下位置',
            value: o.offsetPct,
            min: -50,
            max: 50,
            divisions: 100,
            suffix: '%',
            onChanged: (v) => _set((x) => x.offsetPct = v.roundToDouble())),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: const Text('为每一格添加边框', style: TextStyle(fontSize: 13)),
          value: o.sheetBorder,
          onChanged: enabled ? (v) => _set((x) => x.sheetBorder = v) : null,
        ),
        _line('渲染质量', _dropdown<int>(
          o.renderDpi,
          const [
            DropdownMenuItem(value: 150, child: Text('150 dpi · 快速')),
            DropdownMenuItem(value: 200, child: Text('200 dpi · 标准')),
            DropdownMenuItem(value: 300, child: Text('300 dpi · 高质量')),
          ],
          (v) => _set((x) => x.renderDpi = v!),
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Text(
            o.layoutSummary,
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ),
      ],
    );
  }
}

/// 页码范围 / 奇偶页 / 逆序(手动双面)
class PageSelectionEditor extends StatelessWidget {
  final PrintOptions options;
  final ChangeOptions onChange;
  final TextEditingController rangeController;
  final bool enabled;

  const PageSelectionEditor({
    super.key,
    required this.options,
    required this.onChange,
    required this.rangeController,
    this.enabled = true,
  });

  void _set(void Function(PrintOptions o) f) => onChange(f);

  @override
  Widget build(BuildContext context) {
    final o = options;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: TextField(
            controller: rangeController,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: '页码范围(留空 = 全部)',
              hintText: '例如 1-3,5 或 2-',
              helperText: '合并后的连续页码;支持 1-3、1,3,5、1~3、2-',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _set((x) => x.pageRange = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              const SizedBox(width: 76, child: Text('页面', style: TextStyle(fontSize: 13))),
              Expanded(
                child: DropdownButton<String>(
                  value: o.parity,
                  isExpanded: true,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部页面')),
                    DropdownMenuItem(value: 'odd', child: Text('仅奇数页 (1,3,5…)')),
                    DropdownMenuItem(value: 'even', child: Text('仅偶数页 (2,4,6…)')),
                  ],
                  onChanged: enabled ? (v) => _set((x) => x.parity = v!) : null,
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: const Text('逆序打印', style: TextStyle(fontSize: 13)),
          subtitle: const Text('手动双面:先打偶数页(逆序),翻面后再打奇数页', style: TextStyle(fontSize: 11)),
          value: o.reverse,
          onChanged: enabled ? (v) => _set((x) => x.reverse = v) : null,
        ),
      ],
    );
  }
}
