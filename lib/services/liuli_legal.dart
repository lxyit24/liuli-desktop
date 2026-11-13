import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/services/liuli_update.dart';
import 'package:fl_clash/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用内协议页（用户协议 / 隐私政策）。
///
/// 正文从面板（`/terms`、`/privacy`）拉取，联网成功就更新本地缓存，
/// 断网时用上次缓存的正文，整个过程都在应用内部完成，不跳浏览器。
class LegalBlock {
  /// h1 | h2 | h3 | p | li
  final String kind;
  final String text;

  const LegalBlock(this.kind, this.text);
}

class LegalDoc {
  final List<LegalBlock> blocks;

  const LegalDoc(this.blocks);

  bool get isEmpty => blocks.isEmpty;
}

const _kTerms = 'liuli_legal_terms_html';
const _kPrivacy = 'liuli_legal_privacy_html';

String _cacheKey(String name) => name == 'privacy' ? _kPrivacy : _kTerms;

String legalTitle(String name) => name == 'privacy' ? '隐私政策' : '用户协议';

String _decodeEntities(String s) {
  const map = {
    '&nbsp;': ' ',
    '&middot;': '·',
    '&hellip;': '…',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&amp;': '&',
  };
  var out = s;
  map.forEach((k, v) => out = out.replaceAll(k, v));
  return out.replaceAll(RegExp(r'&#\d+;'), '');
}

String _plainText(String html) {
  final noTags = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  final text = _decodeEntities(noTags.replaceAll(RegExp(r'<[^>]+>'), ' '));
  return text
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// 把面板返回的 HTML 拆成「标题 / 小标题 / 段落 / 列表项」几个块。
/// 只取协议正文（`<article>` 里的内容）+ 标题与生效日期，避免把站点导航混进来。
LegalDoc parseLegal(String html) {
  String clean(String s) {
    var out = s.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
      '',
    );
    out = out.replaceAll(
      RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
      '',
    );
    return out;
  }

  final titleMatch = RegExp(
    r'<h1[^>]*class="[^"]*legal-h1[^"]*"[^>]*>([\s\S]*?)</h1>',
    caseSensitive: false,
  ).firstMatch(html);
  final metaMatch = RegExp(
    r'<p[^>]*class="[^"]*legal-meta[^"]*"[^>]*>([\s\S]*?)</p>',
    caseSensitive: false,
  ).firstMatch(html);
  final articleMatch = RegExp(
    r'<article[^>]*>([\s\S]*?)</article>',
    caseSensitive: false,
  ).firstMatch(html);

  var body = articleMatch?.group(1) ?? html;
  if (articleMatch == null) {
    final bodyStart = RegExp(
      r'<body[^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (bodyStart != null) body = html.substring(bodyStart.end);
  }
  body = clean(body);

  final blocks = <LegalBlock>[];
  if (titleMatch != null) {
    final t = _plainText(titleMatch.group(1) ?? '');
    if (t.isNotEmpty) blocks.add(LegalBlock('h1', t));
  }
  if (metaMatch != null) {
    final t = _plainText(metaMatch.group(1) ?? '');
    if (t.isNotEmpty) blocks.add(LegalBlock('p', t));
  }
  final re = RegExp(
    r'<(h1|h2|h3|p|li)([^>]*)>([\s\S]*?)</\1>',
    caseSensitive: false,
  );
  for (final m in re.allMatches(body)) {
    final kind = (m.group(1) ?? '').toLowerCase();
    final text = _plainText(m.group(3) ?? '');
    if (text.isEmpty) continue;
    blocks.add(LegalBlock(kind, text));
  }
  return LegalDoc(blocks);
}

Future<String?> _fetchHtml(String base, String path) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final root = base.replaceAll(RegExp(r'/+$'), '');
    final req = await client.getUrl(Uri.parse('$root$path'));
    req.headers.set(
      'User-Agent',
      'FlClash/${globalState.packageInfo.version} (Liuli)',
    );
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    final text = await resp.transform(utf8.decoder).join();
    if (!text.toLowerCase().contains('<html')) return null;
    return text;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 读取协议正文：先联网，失败回退到本地缓存。
/// 返回 (正文, 是否来自缓存)
Future<(LegalDoc?, bool)> loadLegal(String name) async {
  final sp = await SharedPreferences.getInstance();
  final base = await liuliBase();
  final path = name == 'privacy' ? '/privacy' : '/terms';
  final fresh = await _fetchHtml(base, path);
  if (fresh != null) {
    await sp.setString(_cacheKey(name), fresh);
    final doc = parseLegal(fresh);
    if (!doc.isEmpty) return (doc, false);
  }
  final cached = sp.getString(_cacheKey(name));
  if (cached != null && cached.isNotEmpty) {
    final doc = parseLegal(cached);
    if (!doc.isEmpty) return (doc, true);
  }
  return (null, false);
}
