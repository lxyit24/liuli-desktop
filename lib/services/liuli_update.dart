import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 琉璃桌面客户端更新：多源并发测速，自动选最快的下载（境内 GitHub 常不通）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.size,
    required this.sha256,
    required this.mirrors,
  });

  final String version;
  final int size;
  final String sha256;
  final List<String> mirrors;

  /// a.b.c 逐段比较，返回 true 表示 [this] 比 [other] 新
  bool isNewerThan(String other) {
    List<int> parts(String v) => v
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final a = parts(version);
    final b = parts(other);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

/// 单个源的测速结果
class MirrorSpeed {
  const MirrorSpeed(this.url, this.ms, this.kbps, {this.error});

  final String url;
  final int ms;
  final double kbps;
  final String? error;

  bool get ok => error == null && kbps > 0;
}

const _probeBytes = 262144; // 256KB 足够判断快慢
const _probeTimeout = Duration(seconds: 8);

HttpClient _client() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 8)
  ..userAgent = 'Liuli/update';

/// GitHub 系域名在境内常被墙；如果内核在跑，就让它走我们的节点出口
bool _isGithubHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.contains('github') || host.contains('githubusercontent');
}

HttpClient _clientFor(String url, int? proxyPort) {
  final client = _client();
  if (proxyPort != null && proxyPort > 0 && _isGithubHost(url)) {
    client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
  }
  return client;
}

/// 拉更新清单（面板优先；面板不可达时尝试镜像域名）
Future<UpdateInfo?> fetchUpdate(String base) async {
  final candidates = <String>[
    '$base/api/client/update?platform=windows',
  ];
  for (final url in candidates) {
    final client = _client();
    try {
      final resp =
          await (await client.getUrl(Uri.parse(url))).close().timeout(_probeTimeout);
      if (resp.statusCode != 200) continue;
      final text = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(text);
      if (data is! Map || data['ok'] != true) continue;
      final mirrors = (data['mirrors'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.startsWith('http'))
              .toList() ??
          const <String>[];
      if (mirrors.isEmpty) continue;
      return UpdateInfo(
        version: (data['version'] ?? '').toString(),
        size: int.tryParse((data['size'] ?? 0).toString()) ?? 0,
        sha256: (data['sha256'] ?? '').toString(),
        mirrors: mirrors,
      );
    } catch (_) {
      // 换下一个源
    } finally {
      client.close(force: true);
    }
  }
  return null;
}

/// 并发探测各源：取前 256KB，算「首包耗时 + 吞吐」
Future<List<MirrorSpeed>> probeMirrors(List<String> urls, {int? proxyPort}) async {
  final results = await Future.wait(urls.map((u) => _probe(u, proxyPort)));
  results.sort((a, b) {
    if (a.ok != b.ok) return a.ok ? -1 : 1;
    return b.kbps.compareTo(a.kbps);
  });
  return results;
}

Future<MirrorSpeed> _probe(String url, [int? proxyPort]) async {
  final client = _clientFor(url, proxyPort);
  final sw = Stopwatch()..start();
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(_probeTimeout);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$_probeBytes');
    final resp = await req.close().timeout(_probeTimeout);
    if (resp.statusCode >= 400) {
      await resp.drain<void>();
      return MirrorSpeed(url, 0, 0, error: 'HTTP ${resp.statusCode}');
    }
    var got = 0;
    final completer = Completer<void>();
    final sub = resp.listen(
      (chunk) {
        got += chunk.length;
        if (got >= _probeBytes && !completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    try {
      await completer.future.timeout(_probeTimeout);
    } finally {
      await sub.cancel();
    }
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    final kbps = got / 1024.0 / (ms / 1000.0 + 0.001);
    return MirrorSpeed(url, ms, kbps);
  } catch (e) {
    return MirrorSpeed(url, 0, 0, error: e.toString());
  } finally {
    client.close(force: true);
  }
}


/// 按测速结果依次尝试下载，返回本地文件
Future<File> downloadFromBest(
  UpdateInfo info,
  List<MirrorSpeed> speeds, {
  void Function(int received, int total)? onProgress,
  int? proxyPort,
}) async {
  final dir = await getDownloadsDirectory() ??
      Directory('${Platform.environment['USERPROFILE']}\\Downloads');
  final name = 'Liuli-Windows-${info.version}.zip';
  final target = File('${dir.path}${Platform.pathSeparator}$name');
  final ordered = speeds.where((s) => s.ok).map((s) => s.url).toList();
  if (ordered.isEmpty) {
    ordered.addAll(info.mirrors);
  }
  Object? lastError;
  for (final url in ordered) {
    final client = _clientFor(url, proxyPort);
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      if (resp.statusCode >= 400) {
        await resp.drain<void>();
        lastError = 'HTTP ${resp.statusCode}';
        continue;
      }
      final total = resp.contentLength > 0 ? resp.contentLength : info.size;
      final tmp = File('${target.path}.part');
      final sink = tmp.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      if (await tmp.length() == 0) {
        lastError = '下载内容为空';
        continue;
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (e) {
      lastError = e;
    } finally {
      client.close(force: true);
    }
  }
  throw Exception('所有下载源都失败：$lastError');
}

String fmtSize(int bytes) {
  var v = bytes.toDouble();
  const units = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i <= 1 ? 0 : 1)} ${units[i]}';
}

// ---------------------------------------------------------------- �����ڡ��� ������
// �� ���� �� ���� ʹ�ã�������嵥 + ��Դ���٣����ٲ����� GitHub��

Future<String> liuliBase() async {
  final sp = await SharedPreferences.getInstance();
  var s = (sp.getString('liuli_server') ?? '').trim();
  if (s.isEmpty) s = 'https://liuli.lianji.win';
  if (s.contains('/api/')) s = s.substring(0, s.indexOf('/api/'));
  return s.replaceAll(RegExp(r'/+$'), '');
}

Future<void> showLiuliUpdate(BuildContext context, {required String current}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LiuliUpdateDialog(current: current),
  );
}

class _LiuliUpdateDialog extends ConsumerStatefulWidget {
  const _LiuliUpdateDialog({required this.current});

  final String current;

  @override
  ConsumerState<_LiuliUpdateDialog> createState() => _LiuliUpdateDialogState();
}

class _LiuliUpdateDialogState extends ConsumerState<_LiuliUpdateDialog> {
  bool _checking = true;
  UpdateInfo? _info;
  List<MirrorSpeed> _speeds = const [];
  double? _progress;
  File? _downloaded;
  String? _msg;
  int? _proxyPort;

  String get _current => widget.current;

  // Windows 上 Material 默认字体（Roboto）没有中文字形，这里显式给回退链
  static const _cjk = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'SimHei',
    'SimSun',
    'Noto Sans SC',
    'Segoe UI',
  ];

  TextStyle _ts(BuildContext context, {double size = 13, FontWeight? weight, Color? color}) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return base.copyWith(
      fontSize: size,
      fontWeight: weight,
      color: color,
      fontFamilyFallback: _cjk,
    );
  }

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _checking = true;
      _msg = null;
      _speeds = const [];
      _progress = null;
      _downloaded = null;
      _info = null;
    });
    try {
      final info = await fetchUpdate(await liuliBase());
      if (info == null) {
        setState(() {
          _msg = '更新服务不可达，请稍后再试';
          _checking = false;
        });
        return;
      }
      final status = ref.read(coreStatusProvider);
      if (status == CoreStatus.connected) {
        _proxyPort = ref.read(patchClashConfigProvider).mixedPort;
      }
      final speeds = await probeMirrors(info.mirrors, proxyPort: _proxyPort);
      if (!mounted) return;
      setState(() {
        _info = info;
        _speeds = speeds;
        _checking = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _msg = '检查失败：$e';
          _checking = false;
        });
      }
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _progress = 0;
      _msg = null;
    });
    try {
      final f = await downloadFromBest(info, _speeds,
          proxyPort: _proxyPort, onProgress: (r, t) {
        if (!mounted || t <= 0) return;
        setState(() => _progress = r / t);
      });
      if (mounted) {
        setState(() {
          _downloaded = f;
          _progress = 1;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _msg = '下载失败：$e';
          _progress = null;
        });
      }
    }
  }

  void _openFolder() {
    final f = _downloaded;
    if (f == null) return;
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,', f.path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    final best = _speeds.isNotEmpty ? _speeds.first : null;
    final hasNewer = info != null && info.isNewerThan(_current);

    Widget line(String text,
        {double size = 13, FontWeight? weight, Color? color, double top = 0}) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: Text(text,
            style: _ts(context, size: size, weight: weight, color: color)),
      );
    }

    return Dialog(
      backgroundColor: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line('检查更新', size: 17, weight: FontWeight.w600),
            const SizedBox(height: 14),
            if (_checking) ...[
              const LinearProgressIndicator(),
              line('正在检查版本并测速下载源…', top: 12),
            ],
            if (!_checking && info != null) ...[
              line('当前版本 v$_current'),
              line(
                hasNewer
                    ? '最新版本 v${info.version} · ${fmtSize(info.size)}'
                    : '已是最新版本（v${info.version}）',
                weight: FontWeight.w600,
                top: 4,
              ),
              if (_speeds.isNotEmpty) ...[
                line('下载源测速', weight: FontWeight.w600, top: 14),
                ..._speeds.take(5).map((s) => line(
                      '${s.ok ? "✓" : "×"} ${Uri.tryParse(s.url)?.host ?? s.url}'
                      '${s.ok ? "  ${s.ms} ms · ${s.kbps.toStringAsFixed(0)} KB/s" : "  ${s.error ?? "不可用"}"}',
                      size: 12,
                      color: s.ok ? scheme.onSurfaceVariant : scheme.error,
                      top: 3,
                    )),
                if (_proxyPort != null)
                  line('GitHub 系源已走本机节点加速（端口 $_proxyPort）',
                      size: 12, color: scheme.primary, top: 6),
                if (best != null)
                  line('自动选择：${Uri.tryParse(best.url)?.host}',
                      size: 12, weight: FontWeight.w600, color: scheme.primary, top: 8),
              ],
            ],
            if (_progress != null) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                    value: _progress == 0 ? null : _progress, minHeight: 6),
              ),
            ],
            if (_downloaded != null)
              line('下载完成，解压后运行 Liuli.exe 覆盖旧版本即可。', size: 12, top: 10),
            if (_msg != null)
              line(_msg!, size: 12, color: scheme.error, top: 10),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasNewer && _downloaded == null)
                  FilledButton(
                    style: FilledButton.styleFrom(
                        textStyle: _ts(context, size: 13, weight: FontWeight.w600)),
                    onPressed: _progress == null ? _download : null,
                    child: Text(_progress == null ? '下载更新' : '下载中…',
                        style: _ts(context, size: 13, weight: FontWeight.w600)),
                  ),
                if (_downloaded != null)
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                        textStyle: _ts(context, size: 13, weight: FontWeight.w600)),
                    onPressed: _openFolder,
                    child: Text('打开文件夹',
                        style: _ts(context, size: 13, weight: FontWeight.w600)),
                  ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('关闭', style: _ts(context, size: 13)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
