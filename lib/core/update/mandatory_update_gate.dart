import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'update_service.dart';

/// Blocks all in-app interaction while a mandatory published update is due.
/// A failed network check fails open so offline users are not permanently locked.
class MandatoryUpdateGate extends StatefulWidget {
  const MandatoryUpdateGate({super.key, required this.child});
  final Widget child;

  @override
  State<MandatoryUpdateGate> createState() => _MandatoryUpdateGateState();
}

class _MandatoryUpdateGateState extends State<MandatoryUpdateGate>
    with WidgetsBindingObserver {
  final UpdateService _service = UpdateService();
  UpdateInfo? _required;
  bool _checking = false;
  bool _installing = false;
  double? _progress;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      _timer = Timer.periodic(const Duration(minutes: 10), (_) => _check());
    }
  }

  Future<void> _check() async {
    if (!mounted || _checking || _installing) return;
    _checking = true;
    try {
      final info = await _service.checkForUpdate(respectSkip: false);
      if (!mounted) return;
      setState(() {
        _required = info?.mandatory == true ? info : null;
        _error = null;
      });
    } catch (_) {
      // Preserve an existing lock when a refresh fails.
    } finally {
      _checking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _install() async {
    final info = _required;
    if (info == null || _installing) return;
    setState(() {
      _installing = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await _service.downloadApk(
        info.apkUrl,
        expectedSize: info.apkSize,
        expectedSha256: info.sha256,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final opened = await _service.installApk(file);
      if (!mounted) return;
      if (!opened) {
        setState(() => _error = 'Could not open the Android installer. Check install permissions.');
      }
      // Keep the gate up even after launching the installer. The installed
      // version is checked again when the application resumes/restarts.
    } catch (e) {
      if (mounted) setState(() => _error = 'Update failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _installing = false;
          _progress = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _required;
    if (info == null) return widget.child;
    return PopScope(
      canPop: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(child: AbsorbPointer(child: widget.child)),
          Positioned.fill(
            child: Material(
              color: const Color(0xFF101018),
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.system_update_rounded, size: 72, color: Color(0xFF8B7BFF)),
                          const SizedBox(height: 24),
                          const Text('Update required',
                              style: TextStyle(fontSize: 26, color: Colors.white, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          Text('AnimePlex v${info.version} must be installed to continue.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 16)),
                          if (info.notes.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(info.notes, textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white60)),
                          ],
                          if (_progress != null) ...[
                            const SizedBox(height: 24),
                            LinearProgressIndicator(value: _progress),
                            const SizedBox(height: 8),
                            Text('${(_progress! * 100).round()}%', style: const TextStyle(color: Colors.white70)),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Text(_error!, textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.redAccent)),
                          ],
                          const SizedBox(height: 28),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _installing ? null : _install,
                              icon: const Icon(Icons.download_rounded),
                              label: Text(_installing ? 'Preparing update…' : 'Download & install'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _installing ? null : _check,
                            child: const Text('Check again'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
