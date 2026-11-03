import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http;

// Same fixed white-label backend as ActivationGate.
const _kVersionServer = 'https://app.creativeinfra.com.br';

/// Wraps the app's main content and shows a small dismissible banner on top
/// when the backend reports a newer build than the one currently running.
/// Purely informational -- the client decides whether to download, nothing
/// is forced or auto-installed.
class UpdateBanner extends StatefulWidget {
  final Widget child;
  const UpdateBanner({Key? key, required this.child}) : super(key: key);

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  String? _downloadUrl;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    try {
      final localBuildDate = await bind.mainGetBuildDate();
      final resp = await http
          .get(Uri.parse('$_kVersionServer/api/neuradesk-remote/versao-atual'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body);
      final remoteBuildDate = data['build_date'] as String?;
      final url = data['download_url'] as String?;
      if (remoteBuildDate == null || url == null) return;
      // Same lexicographic comparison as the Rust side's
      // is_installed_lower_version(): both sides use the "YYYY-MM-DD HH:MM"
      // format, which sorts chronologically as a plain string.
      if (remoteBuildDate.compareTo(localBuildDate) > 0 && mounted) {
        setState(() => _downloadUrl = url);
      }
    } catch (_) {
      // No internet / server unreachable: just stay quiet, this is purely
      // an FYI banner, not something to retry or nag about.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_downloadUrl == null || _dismissed) {
      return widget.child;
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.system_update_rounded, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    translate('update_available_tip'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => launchUrl(Uri.parse(_downloadUrl!)),
                  child: Text(translate('Download')),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
