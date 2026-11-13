import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/liuli_update.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 琉璃用户中心
///
/// 直接对接面板的客户端接口：
///   POST /api/client/login   账号密码换令牌
///   GET  /api/client/subinfo 剩余流量 / 到期 / 订阅地址
/// 登录后一键把订阅导入成 Clash 配置（面板会按 UA 返回 YAML）。
const _kServer = 'liuli_server';
const _kUser = 'liuli_user';
const _kToken = 'liuli_token';
const _kSub = 'liuli_sub_url';
const _kInfo = 'liuli_info';

const _defaultServer = 'https://liuli.lianji.win';

class AccountView extends ConsumerStatefulWidget {
  const AccountView({super.key});

  @override
  ConsumerState<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends ConsumerState<AccountView> {
  final _serverCtl = TextEditingController(text: _defaultServer);
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();

  // 账号与安全（改昵称 / 改密码 / 重置订阅）
  final _nickCtl = TextEditingController();
  final _oldPwdCtl = TextEditingController();
  final _newPwdCtl = TextEditingController();
  final _newPwd2Ctl = TextEditingController();
  bool _showPwd = false;
  bool _confirmReset = false;
  String? _secMsg;
  bool _secOk = false;

  bool _busy = false;
  String? _error;
  String _token = '';
  String _subUrl = '';
  Map<String, dynamic> _info = const {};

  // 客户端更新（多源测速）
  bool _checking = false;
  UpdateInfo? _updInfo;
  List<MirrorSpeed> _speeds = const [];
  double? _progress;
  File? _downloaded;
  String? _updateMsg;

  bool get _loggedIn => _token.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _serverCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _nickCtl.dispose();
    _oldPwdCtl.dispose();
    _newPwdCtl.dispose();
    _newPwd2Ctl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final sp = await SharedPreferences.getInstance();
    final server = sp.getString(_kServer) ?? _defaultServer;
    final token = sp.getString(_kToken) ?? '';
    final sub = sp.getString(_kSub) ?? '';
    final infoRaw = sp.getString(_kInfo);
    if (!mounted) return;
    setState(() {
      _serverCtl.text = server;
      _userCtl.text = sp.getString(_kUser) ?? '';
      _token = token;
      _subUrl = sub;
      if (infoRaw != null) {
        try {
          _info = jsonDecode(infoRaw) as Map<String, dynamic>;
        } catch (_) {}
      }
      _nickCtl.text = (_info['display'] ?? _info['username'] ?? '').toString();
    });
    if (token.isNotEmpty) {
      unawaited(_refresh());
    }
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kServer, _serverCtl.text.trim());
    await sp.setString(_kUser, _userCtl.text.trim());
    await sp.setString(_kToken, _token);
    await sp.setString(_kSub, _subUrl);
    await sp.setString(_kInfo, jsonEncode(_info));
  }

  String get _base {
    var s = _serverCtl.text.trim();
    if (s.isEmpty) s = _defaultServer;
    if (s.contains('/api/')) s = s.substring(0, s.indexOf('/api/'));
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.parse('$_base$path');
      final req = body == null
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      req.headers.set('User-Agent', 'FlClash/${globalState.packageInfo.version} (Liuli)');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final text = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(text);
      if (data is Map<String, dynamic>) return data;
      return {'ok': false, 'error': '返回格式异常'};
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _login() async {
    final user = _userCtl.text.trim();
    final pass = _passCtl.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await _request('/api/client/login',
          body: {'username': user, 'password': pass});
      if (res['ok'] != true) {
        setState(() => _error = (res['error'] ?? '登录失败').toString());
        return;
      }
      _token = (res['token'] ?? '').toString();
      final account = res['user'];
      if (account is Map<String, dynamic>) _info = account;
      await _refresh();
      await _save();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      setState(() => _error = '网络错误：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_token.isEmpty) return;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      try {
        final uri = Uri.parse('$_base/api/client/subinfo?token=$_token');
        final req = await client.getUrl(uri);
        req.headers.set('User-Agent', 'FlClash/${globalState.packageInfo.version} (Liuli)');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        final text = await resp.transform(utf8.decoder).join();
        final res = jsonDecode(text);
        if (res is Map<String, dynamic> && res['ok'] == true) {
          _subUrl = (res['subUrl'] ?? '').toString();
          _info = {
            ..._info,
            'display': res['display'],
            'usedBytes': res['usedBytes'],
            'limitBytes': res['limitBytes'],
            'leftBytes': res['leftBytes'],
            'usedPct': res['usedPct'],
            'expireAt': res['expireAt'],
            'balance': res['balance'],
            'billingMode': res['billingMode'],
            'deviceCount': res['deviceCount'],
            'deviceLimit': res['deviceLimit'],
            'nodeCount': res['nodeCount'],
          };
          if ((_nickCtl.text).trim().isEmpty) {
            _nickCtl.text =
                (_info['display'] ?? _info['username'] ?? '').toString();
          }
          await _save();
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // 静默失败：离线时仍显示上次缓存
    }
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kToken);
    await sp.remove(_kSub);
    await sp.remove(_kInfo);
    if (!mounted) return;
    setState(() {
      _token = '';
      _subUrl = '';
      _info = const {};
      _passCtl.clear();
    });
  }

  Future<void> _importProfile() async {
    if (_subUrl.isEmpty) {
      if (mounted) setState(() => _error = '还没有订阅地址，请先点击刷新');
      return;
    }
    await ref
        .read(profilesActionProvider.notifier)
        .addProfileFromLink(_subUrl, label: '琉璃订阅');
  }

  String _fmtBytes(num? bytes) {
    var v = (bytes ?? 0).toDouble();
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i <= 1 ? 0 : 2)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // FlClash 的 TextTheme 是部分定制的，bodyLarge 等可能为 null，
    // Flutter 的 TextField 会 `textTheme.bodyLarge!` 直接崩，这里补齐后再渲染。
    final base = Theme.of(context);
    final textTheme = base.textTheme.copyWith(
      bodyLarge: base.textTheme.bodyLarge ?? const TextStyle(fontSize: 14),
      bodyMedium: base.textTheme.bodyMedium ?? const TextStyle(fontSize: 13),
      titleMedium:
          base.textTheme.titleMedium ?? const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      titleLarge:
          base.textTheme.titleLarge ?? const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      headlineMedium:
          base.textTheme.headlineMedium ?? const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      displaySmall:
          base.textTheme.displaySmall ?? const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
    );
    // FlClash 的外壳不是 Material 控件树，输入框/按钮需要 Material 祖先；
    // MaterialLocalizations 已在 application.dart 里注册（GlobalMaterialLocalizations）。
    return Theme(
      data: base.copyWith(textTheme: textTheme),
      child: Material(
        color: Colors.transparent,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('我的', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    _loggedIn ? '账号信息与订阅' : '登录后自动同步账号、流量与节点',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  _loggedIn ? _buildAccountCard(scheme) : _buildLoginCard(scheme),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: scheme.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 16),
                  _buildUpdateCard(scheme),
                  if (_loggedIn) ...[
                    const SizedBox(height: 16),
                    _buildSubCard(scheme),
                    const SizedBox(height: 16),
                    _buildSecurityCard(scheme),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 客户端更新
  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _updateMsg = null;
      _updInfo = null;
      _speeds = const [];
      _progress = null;
      _downloaded = null;
    });
    try {
      final info = await fetchUpdate(_base);
      if (info == null) {
        setState(() => _updateMsg = '更新服务不可达，请稍后再试');
        return;
      }
      setState(() => _updInfo = info);
      final speeds = await probeMirrors(info.mirrors);
      if (mounted) setState(() => _speeds = speeds);
    } catch (e) {
      if (mounted) setState(() => _updateMsg = '检查更新失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _downloadUpdate() async {
    final info = _updInfo;
    if (info == null) return;
    setState(() {
      _progress = 0;
      _updateMsg = null;
    });
    try {
      final file = await downloadFromBest(
        info,
        _speeds,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = received / total);
        },
      );
      if (mounted) {
        setState(() {
          _downloaded = file;
          _progress = 1;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _updateMsg = '下载失败：$e';
          _progress = null;
        });
      }
    }
  }

  void _openDownloadFolder() {
    final file = _downloaded;
    if (file == null) return;
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,${file.path}']);
    }
  }

  Widget _buildUpdateCard(ColorScheme scheme) {
    final current = globalState.packageInfo.version;
    final info = _updInfo;
    final best = _speeds.isNotEmpty ? _speeds.first : null;
    final hasNewer = info != null && info.isNewerThan(current);
    return _card(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('客户端更新',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Text('当前 v$current',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '自动并发测速所有下载源（面板 / GitHub / 加速镜像），选最快的那个下载。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_downloaded == null)
                FilledButton.tonal(
                  onPressed: _checking ? null : _checkUpdate,
                  child: Text(_checking ? '测速中…' : '检查更新'),
                ),
              if (info != null && hasNewer && _downloaded == null)
                FilledButton.icon(
                  onPressed: _progress == null ? _downloadUpdate : null,
                  icon: const GlyphIcon(AppGlyphs.cloudDownload, size: 15),
                  label: Text(_progress == null
                      ? '下载 v${info.version}'
                      : '下载中 ${(_progress! * 100).toStringAsFixed(0)}%'),
                ),
              if (_downloaded != null)
                FilledButton.tonal(
                  onPressed: _openDownloadFolder,
                  child: const Text('打开文件夹'),
                ),
            ],
          ),
          if (_progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                minHeight: 6,
              ),
            ),
          ],
          if (info != null) ...[
            const SizedBox(height: 10),
            Text(
              hasNewer
                  ? '最新 v${info.version} · ${fmtSize(info.size)}'
                  : '已是最新（v${info.version}）',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (_speeds.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '最快源：${Uri.tryParse(best!.url)?.host ?? best.url}'
                ' · ${best.ms} ms · ${best.kbps.toStringAsFixed(0)} KB/s',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              ..._speeds.take(4).map((s) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${s.ok ? "✓" : "×"} ${Uri.tryParse(s.url)?.host ?? s.url}'
                      '${s.ok ? "  ${s.ms} ms · ${s.kbps.toStringAsFixed(0)} KB/s" : "  ${s.error ?? "不可用"}"}',
                      style: TextStyle(
                        fontSize: 11,
                        color: s.ok
                            ? scheme.onSurfaceVariant
                            : scheme.error.withValues(alpha: 0.8),
                      ),
                    ),
                  )),
            ],
          ],
          if (_updateMsg != null) ...[
            const SizedBox(height: 8),
            Text(_updateMsg!,
                style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
          if (_downloaded != null) ...[
            const SizedBox(height: 8),
            Text('已保存：${_downloaded!.path}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  Widget _card(ColorScheme scheme, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: child,
    );
  }

  Widget _field(
    TextEditingController ctl,
    String label, {
    bool obscure = false,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctl,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildLoginCard(ColorScheme scheme) {
    return _card(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('登录琉璃账号', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          _field(_serverCtl, '服务器', hint: _defaultServer),
          _field(_userCtl, '用户名'),
          _field(_passCtl, '密码', obscure: true),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('登录并同步'),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(ColorScheme scheme) {
    final used = (_info['usedBytes'] as num?)?.toDouble() ?? 0;
    final limit = (_info['limitBytes'] as num?)?.toDouble() ?? 0;
    final left = (_info['leftBytes'] as num?)?.toDouble() ?? 0;
    final metered = (limit <= 0);
    final pct = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;

    return _card(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (_info['display'] ?? _info['username'] ?? '已登录').toString(),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _busy ? null : _refresh,
                icon: const GlyphIcon(AppGlyphs.refresh, size: 18),
              ),
              TextButton(
                onPressed: _logout,
                child: const Text('退出登录'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            metered
                ? '余额 ¥${(_info['balance'] ?? 0)}'
                : '剩余 ${_fmtBytes(left)}',
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            metered
                ? '按量计费 · 已用 ${_fmtBytes(used)}'
                : '已用 ${_fmtBytes(used)} / ${_fmtBytes(limit)}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          if (!metered) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _stat('到期时间', (_info['expireAt'] ?? '—').toString()),
              _stat('设备',
                  '${_info['deviceCount'] ?? 0} / ${_info['deviceLimit'] ?? 0}'),
              _stat('节点', '${_info['nodeCount'] ?? 0} 个'),
              _stat('计费',
                  (_info['billingMode'] == 'metered') ? '按量' : '套餐'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
        const SizedBox(height: 2),
        Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildSubCard(ColorScheme scheme) {    return _card(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('订阅', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _subUrl.isEmpty ? '（刷新后显示）' : _subUrl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制',
                onPressed: _subUrl.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: _subUrl)),
                icon: const GlyphIcon(AppGlyphs.copy, size: 15),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _importProfile,
                icon: const GlyphIcon(AppGlyphs.cloudDownload, size: 15),
                label: const Text('导入 / 更新节点'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '导入后到「代理」页选择节点，回仪表盘点圆盘即可连接。',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 账号与安全

  Future<void> _saveDisplay() async {
    final name = _nickCtl.text.trim();
    if (name.isEmpty) {
      setState(() {
        _secOk = false;
        _secMsg = '昵称不能为空';
      });
      return;
    }
    setState(() {
      _busy = true;
      _secMsg = null;
    });
    try {
      final res = await _request('/api/client/profile', body: {
        'token': _token,
        'display': name,
      });
      final ok = res['ok'] == true;
      if (ok) {
        _info = {..._info, 'display': name};
        await _save();
      }
      if (mounted) {
        setState(() {
          _secOk = ok;
          _secMsg = ok ? '昵称已更新' : (res['error'] ?? '保存失败').toString();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _secOk = false;
          _secMsg = '网络错误：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final old = _oldPwdCtl.text;
    final n1 = _newPwdCtl.text;
    final n2 = _newPwd2Ctl.text;
    String? bad;
    if (old.isEmpty) {
      bad = '请输入原密码';
    } else if (n1.length < 6) {
      bad = '新密码至少 6 位';
    } else if (n1 != n2) {
      bad = '两次输入的新密码不一致';
    }
    if (bad != null) {
      setState(() {
        _secOk = false;
        _secMsg = bad;
      });
      return;
    }
    setState(() {
      _busy = true;
      _secMsg = null;
    });
    try {
      final res = await _request('/api/client/password', body: {
        'token': _token,
        'old': old,
        'new': n1,
      });
      final ok = res['ok'] == true;
      if (ok) {
        _oldPwdCtl.clear();
        _newPwdCtl.clear();
        _newPwd2Ctl.clear();
      }
      if (mounted) {
        setState(() {
          _secOk = ok;
          _showPwd = !ok;
          _secMsg = ok
              ? '密码已修改，下次登录请用新密码'
              : (res['error'] ?? '修改失败').toString();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _secOk = false;
          _secMsg = '网络错误：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetSub() async {
    setState(() {
      _busy = true;
      _secMsg = null;
    });
    try {
      final res = await _request('/api/client/sub/reset', body: {'token': _token});
      final ok = res['ok'] == true;
      if (ok) {
        _subUrl = (res['subUrl'] ?? _subUrl).toString();
        await _save();
      }
      if (mounted) {
        setState(() {
          _secOk = ok;
          _confirmReset = false;
          _secMsg = ok
              ? '订阅地址已重置，旧地址已失效；点上面「导入 / 更新节点」用新地址重新导入'
              : (res['error'] ?? '重置失败').toString();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _secOk = false;
          _secMsg = '网络错误：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildSecurityCard(ColorScheme scheme) {
    final msg = _secMsg;
    return _card(
      scheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('账号与安全', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '改昵称、改密码、重置订阅地址都在这里完成；'
            '注销账号、订单与退款请到网页用户中心（用户中心 → 账户 / 订单）。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _field(_nickCtl, '昵称')),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: FilledButton.tonal(
                  onPressed: _busy ? null : _saveDisplay,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
          if (!_showPwd)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : () => setState(() => _showPwd = true),
                icon: const GlyphIcon(AppGlyphs.lock, size: 15),
                label: const Text('修改密码'),
              ),
            )
          else ...[
            _field(_oldPwdCtl, '原密码', obscure: true),
            _field(_newPwdCtl, '新密码（至少 6 位）', obscure: true),
            _field(_newPwd2Ctl, '再输一次新密码', obscure: true),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _changePassword,
                  child: const Text('确认修改'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _showPwd = false;
                            _oldPwdCtl.clear();
                            _newPwdCtl.clear();
                            _newPwd2Ctl.clear();
                          }),
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (!_confirmReset)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _confirmReset = true),
                  icon: const GlyphIcon(AppGlyphs.refresh, size: 15),
                  label: const Text('重置订阅地址'),
                ),
                const SizedBox(height: 6),
                Text(
                  '怀疑订阅地址被分享时用；重置后旧地址与已复制的节点链接立即失效。',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '重置后旧地址会立即失效，其它设备需要重新导入。确定吗？',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _resetSub,
                      child: const Text('确认重置'),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _confirmReset = false),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
          if (msg != null) ...[
            const SizedBox(height: 10),
            Text(
              msg,
              style: TextStyle(
                fontSize: 12,
                color: _secOk ? scheme.primary : scheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

