import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

// Fixed white-label activation backend -- not user-configurable, same idea
// as the fixed default API server in common.dart's get_api_server fallback.
const _kActivationServer = 'https://app.creativeinfra.com.br';

const _kKeyActivationKey = 'activation_key';
const _kKeyActivationStatus = 'activation_status';
const _kKeyActivationCheckedAt = 'activation_checked_at';

// If the activation server can't be reached, keep a previously-activated
// install usable for a while instead of locking out a technician who's
// somewhere with no/firewalled internet.
const _kOfflineGraceDays = 30;

bool _statusUnlocks(String? status) =>
    status == 'ativa' || status == 'carencia';

/// Wraps the app's main home content. Blocks access behind [ActivationPage]
/// until a valid activation key is on file, re-verifying with the backend
/// in the background on every launch.
class ActivationGate extends StatefulWidget {
  final Widget child;
  const ActivationGate({Key? key, required this.child}) : super(key: key);

  @override
  State<ActivationGate> createState() => _ActivationGateState();
}

class _ActivationGateState extends State<ActivationGate> {
  bool _checking = true;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final key = bind.mainGetLocalOption(key: _kKeyActivationKey);
    if (key.isEmpty) {
      setState(() {
        _checking = false;
        _unlocked = false;
      });
      return;
    }

    // Trust the cached status immediately so a healthy, already-activated
    // install never blocks on network at launch; refresh in the background.
    final cachedStatus = bind.mainGetLocalOption(key: _kKeyActivationStatus);
    setState(() {
      _checking = false;
      _unlocked = _statusUnlocks(cachedStatus);
    });

    unawaited(_verify(key));
  }

  Future<void> _verify(String key) async {
    try {
      final fingerprint = await bind.mainGetUuid();
      final resp = await http
          .post(
            Uri.parse('$_kActivationServer/api/licencas-remote/verificar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'chave': key, 'fingerprint': fingerprint}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          final situacao = data['situacao'] as String? ?? 'bloqueada';
          await bind.mainSetLocalOption(
              key: _kKeyActivationStatus, value: situacao);
          await bind.mainSetLocalOption(
              key: _kKeyActivationCheckedAt,
              value: DateTime.now().toIso8601String());
          if (mounted) {
            setState(() => _unlocked = _statusUnlocks(situacao));
          }
          return;
        }
      }
      if (resp.statusCode == 403 || resp.statusCode == 404) {
        // Explicit rejection from the server (reset on another device,
        // blocked, cancelled, unknown key): lock right away, don't wait
        // for the offline grace window.
        await bind.mainSetLocalOption(
            key: _kKeyActivationStatus, value: 'bloqueada');
        if (mounted) setState(() => _unlocked = false);
      }
    } catch (_) {
      _applyOfflineGrace();
    }
  }

  void _applyOfflineGrace() {
    final checkedAtStr =
        bind.mainGetLocalOption(key: _kKeyActivationCheckedAt);
    final checkedAt = DateTime.tryParse(checkedAtStr);
    final withinGrace = checkedAt != null &&
        DateTime.now().difference(checkedAt).inDays < _kOfflineGraceDays;
    if (mounted) {
      setState(() => _unlocked = _unlocked && withinGrace);
    }
  }

  void _onActivated() {
    setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return ActivationPage(onActivated: _onActivated);
    }
    return widget.child;
  }
}

class ActivationPage extends StatefulWidget {
  final VoidCallback onActivated;
  const ActivationPage({Key? key, required this.onActivated})
      : super(key: key);

  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final key = _controller.text.trim().toUpperCase();
    if (key.isEmpty) {
      setState(() => _error = translate('Please enter the activation key'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fingerprint = await bind.mainGetUuid();
      final resp = await http
          .post(
            Uri.parse('$_kActivationServer/api/licencas-remote/ativar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'chave': key, 'fingerprint': fingerprint}),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(resp.body);
      if (resp.statusCode == 200 && data['ok'] == true) {
        await bind.mainSetLocalOption(key: _kKeyActivationKey, value: key);
        await bind.mainSetLocalOption(
            key: _kKeyActivationStatus, value: data['status'] ?? 'ativa');
        await bind.mainSetLocalOption(
            key: _kKeyActivationCheckedAt,
            value: DateTime.now().toIso8601String());
        widget.onActivated();
        return;
      }
      String msg;
      switch (resp.statusCode) {
        case 404:
          msg = translate('activation_invalid_key');
          break;
        case 403:
          final erro = (data['erro'] as String?) ?? '';
          msg = erro.contains('bloquea') || erro.contains('cancelad')
              ? translate('activation_blocked')
              : translate('activation_already_used');
          break;
        default:
          msg = translate('Activation failed');
      }
      setState(() => _error = msg);
    } catch (_) {
      setState(() => _error = translate('network_error_tip'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.vpn_key_rounded, size: 48),
                const SizedBox(height: 16),
                Text(
                  translate('activation_title'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  translate('activation_tip'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: translate('Activation Key'),
                    hintText: 'NDRC-XXXX-XXXX-XXXX-XXXX',
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _activate(),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _loading ? null : _activate,
                  child: _loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(translate('Activate')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
