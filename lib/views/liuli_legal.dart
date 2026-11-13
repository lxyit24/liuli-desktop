import 'package:fl_clash/services/liuli_legal.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter/widgets.dart';

/// 应用内协议页：用户协议 / 隐私政策，不跳浏览器。
class LiuliLegalView extends StatefulWidget {
  /// terms | privacy
  final String name;

  const LiuliLegalView({super.key, required this.name});

  @override
  State<LiuliLegalView> createState() => _LiuliLegalViewState();
}

class _LiuliLegalViewState extends State<LiuliLegalView> {
  LegalDoc? _doc;
  bool _fromCache = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (doc, fromCache) = await loadLegal(widget.name);
    if (!mounted) return;
    setState(() {
      _doc = doc;
      _fromCache = fromCache;
      _loading = false;
      if (doc == null) {
        _error = '内容加载失败：请检查网络，或在「我的」页确认面板地址后重试';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final doc = _doc;
    return Scaffold(
      title: legalTitle(widget.name),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : doc == null
          ? _buildError(colorScheme)
          : _buildDoc(doc, colorScheme),
    );
  }

  Widget _buildError(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlyphIcon(AppGlyphs.error, size: 28, color: colorScheme.error),
          const SizedBox(height: 12),
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: AppTextStyle.subheadline
                .of(context)
                .copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TonalButton(
            size: TonalButtonSize.bar,
            glyph: AppGlyphs.sync,
            label: '重试',
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _buildDoc(LegalDoc doc, ColorScheme colorScheme) {
    return ListView.separated(
      padding: EdgeInsets.symmetric(horizontal: 20).copyWith(
        top: context.contentTopPadding,
        bottom: 32 + context.bottomInset,
      ),
      itemCount: doc.blocks.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, index) {
        if (index == doc.blocks.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _fromCache ? '内容来自本地缓存（联网后自动更新）' : '内容来自面板 · 联网时自动更新',
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant.opacity60),
                  ),
                ),
                GestureDetector(
                  onTap: _load,
                  child: Row(
                    children: [
                      GlyphIcon(
                        AppGlyphs.sync,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '刷新',
                        style: AppTextStyle.caption1
                            .of(context, emphasized: true)
                            .copyWith(color: colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return _buildBlock(doc.blocks[index], colorScheme);
      },
    );
  }

  Widget _buildBlock(LegalBlock block, ColorScheme colorScheme) {
    final body = AppTextStyle.subheadline.of(context).copyWith(
          color: colorScheme.onSurface,
          height: 1.65,
        );
    switch (block.kind) {
      case 'h1':
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Text(
            block.text,
            style: AppTextStyle.title2.of(context, emphasized: true),
          ),
        );
      case 'h2':
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 3,
                height: 15,
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  block.text,
                  style: AppTextStyle.headline
                      .of(context, emphasized: true)
                      .copyWith(color: colorScheme.onSurface),
                ),
              ),
            ],
          ),
        );
      case 'h3':
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            block.text,
            style: AppTextStyle.callout.of(context, emphasized: true),
          ),
        );
      case 'li':
        return Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 8),
                child: Text(
                  '·',
                  style: body.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(child: Text(block.text, style: body)),
            ],
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(block.text, style: body),
        );
    }
  }
}
