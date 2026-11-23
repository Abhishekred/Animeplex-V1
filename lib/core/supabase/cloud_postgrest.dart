import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestClient, PostgrestQueryBuilder;

import 'supabase_service.dart';

/// Sends signed-in cloud-data requests to the AnimePlex Cloudflare Worker.
class CloudPostgrest {
  CloudPostgrest(
    this._service, {
    PostgrestClient? vpsClient,
    String? Function()? accessToken,
  }) : _vpsClient = vpsClient,
       _accessToken = accessToken;

  final SupabaseService _service;
  final PostgrestClient? _vpsClient;
  final String? Function()? _accessToken;

  PostgrestQueryBuilder from(String table) {
    final vpsClient = _vpsClient;
    if (vpsClient == null) {
      throw StateError('AnimePlex cloud backend is not configured');
    }
    final token =
        (_accessToken ??
                () => _service.client.auth.currentSession?.accessToken)()
            ?.trim();
    if (token == null || token.isEmpty) {
      throw StateError('A signed-in session is required for cloud sync');
    }
    return vpsClient.setAuth(token).from(table);
  }
}
