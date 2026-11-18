/// Book source management page.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_ui.dart';
import '../feature_pages.dart' show ArchiveFeaturePage, FeatureEntry, featurePadding;
import 'book_source_model.dart';
import 'book_source_store.dart';
import 'custom_source_repository.dart';

class BookSourcePage extends StatefulWidget {
  const BookSourcePage({
    super.key,
    required this.store,
    this.repository,
  });

  final BookSourceStore store;
  final CustomSourceRepository? repository;

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  List<BookSource> _sources = const [];
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _sources = widget.store.sources);

  Future<void> _importFromClipboard() async {
    setState(() => _busy = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        _show('剪贴板为空，请先复制书源 JSON');
        return;
      }
      final count = await widget.store.importJson(text);
      _reload();
      _show(count > 0 ? '成功导入 $count 个书源' : '未识别到有效书源，请检查 JSON 格式');
    } catch (e) {
      _show('导入失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从网络导入书源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '书源订阅地址 (返回 Legado JSON)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true || controller.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final repo = widget.repository;
      if (repo == null) {
        _show('网络导入暂不可用');
        return;
      }
      final result = await repo.fetchSourceSubscription(controller.text.trim());
      final count = await widget.store.importJson(result);
      _reload();
      _show(count > 0 ? '成功导入 $count 个书源' : '订阅地址未返回有效书源');
    } catch (e) {
      _show('导入失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    setState(() => _message = message);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _toggle(BookSource source, bool enabled) async {
    await widget.store.setEnabled(source.key, enabled);
    _reload();
  }

  Future<void> _delete(BookSource source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除「${source.bookSourceName}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.remove(source.key);
    _reload();
  }

  Future<void> _test(BookSource source) async {
    final repo = widget.repository;
    if (repo == null) {
      _show('测试功能暂不可用');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await repo.testSource(source);
      _show(result);
    } catch (e) {
      _show('测试失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '书源管理',
    code: 'SRC',
    actions: [
      IconButton(
        icon: const Icon(Icons.link),
        tooltip: '从网络导入',
        onPressed: _busy ? null : _importFromUrl,
      ),
      IconButton(
        icon: const Icon(Icons.content_paste),
        tooltip: '从剪贴板导入',
        onPressed: _busy ? null : _importFromClipboard,
      ),
    ],
    child: ListView(
      padding: featurePadding(context),
      children: [
        _buildIntro(),
        if (_busy) const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppText(_message,
                style: const TextStyle(fontSize: 12)),
          ),
        if (_sources.isEmpty)
          _buildEmpty()
        else
          ..._sources.map(_buildSourceTile),
        const SizedBox(height: 24),
        _buildFormatHint(),
      ],
    ),
  );

  Widget _buildIntro() => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: AppText(
      '导入 阅读/Legado 格式书源后，即可在搜索中发现网络书籍。加入书架后与原书架书籍使用完全一致的界面。',
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
        height: 1.5,
      ),
    ),
  );

  Widget _buildEmpty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(
      child: Column(
        children: [
          Icon(Icons.source, size: 48,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .3)),
          const SizedBox(height: 16),
          const AppText('还没有书源'),
          const SizedBox(height: 8),
          AppText(
            '点击右上角图标，从剪贴板或网络导入书源',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildSourceTile(BookSource source) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      source.bookSourceName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    AppText(
                      source.bookSourceUrl,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: source.enabled,
                onChanged: (v) => _toggle(source, v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (source.bookSourceGroup.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Chip(
                    label: AppText(source.bookSourceGroup,
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: _busy ? null : () => _test(source),
                child: const AppText('测试', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除',
                onPressed: () => _delete(source),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _buildFormatHint() => Padding(
    padding: const EdgeInsets.all(14),
    child: AppText(
      '支持单个书源 JSON、书源数组，或 阅读/Legado 导出的书源订阅文件。书源规则支持 CSS 选择器、XPath、JSONPath、正则替换与 @js: 脚本。',
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .5),
        height: 1.5,
      ),
    ),
  );
}
