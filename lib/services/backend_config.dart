// Backend configuration and initialization
// ignore_for_file: avoid_print

import 'package:shared_preferences/shared_preferences.dart';
import 'backend_client.dart';

class BackendConfig {
  static BackendClient? _instance;
  
  /// Get or create the singleton BackendClient
  static Future<BackendClient> getInstance() async {
    if (_instance != null) return _instance!;
    
    final prefs = await SharedPreferences.getInstance();
    // Default to production Render server
    final url = prefs.getString('BACKEND_URL') ?? 'https://tasha-main.onrender.com';
    final token = prefs.getString('APP_AUTH_TOKEN') ?? 'test-app-token';
    
    if (token == 'test-app-token') {
      print('[BackendConfig] Using default test token for local development.');
    }
    
    _instance = BackendClient(
      backendUrl: url,
      appAuthToken: token,
    );
    
    print('[BackendConfig] Initialized with backendUrl=$url');
    return _instance!;
  }
  
  /// Set backend URL and token
  static Future<void> setBackendConfig(String url, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('BACKEND_URL', url);
    await prefs.setString('APP_AUTH_TOKEN', token);
    _instance = null; // Reset so next getInstance() uses new config
    print('[BackendConfig] Updated: url=$url');
  }
  
  /// Get current config
  static Future<Map<String, String>> getConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'BACKEND_URL': prefs.getString('BACKEND_URL') ?? 'https://tasha-main.onrender.com',
      'APP_AUTH_TOKEN': prefs.getString('APP_AUTH_TOKEN') ?? 'test-app-token',
    };
  }
}
