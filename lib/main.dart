import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

// ─────────────────────────────────────────────
// 1. AppConfig — build-time constants
// ─────────────────────────────────────────────

class AppConfig {
  static const String gameUrl = String.fromEnvironment('GAME_URL');
  static const String afDevKey = String.fromEnvironment('AF_DEV_KEY');
  static const String appId = String.fromEnvironment('APP_PACKAGE_ID');
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String builderProjectId = String.fromEnvironment('BUILDER_PROJECT_ID');

  static bool get isValid =>
      gameUrl.isNotEmpty &&
      afDevKey.isNotEmpty &&
      appId.isNotEmpty &&
      supabaseUrl.isNotEmpty &&
      builderProjectId.isNotEmpty;
}

// ─────────────────────────────────────────────
// 2. DeepLinkData + DeepLinkParser
// ─────────────────────────────────────────────

class DeepLinkData {
  final String username;
  final String domain; 
  final String alias;
  final String sub2;
  final String sub3;
  final String sub4;
  final String sub5;

  const DeepLinkData({
    required this.username,
    required this.domain,
    required this.alias,
    this.sub2 = '',
    this.sub3 = '',
    this.sub4 = '',
    this.sub5 = '',
  });
}

class DeepLinkParser {
  static DeepLinkData? parse(String deepLinkValue) {
    if (deepLinkValue.isEmpty) return null;

    final parts = deepLinkValue.split('_');
    if (parts.length < 3) return null; 

    return DeepLinkData(
      username: parts[0],
      domain: parts[1].replaceAll('-', '.'),
      alias: parts[2],
      sub2: parts.length > 3 ? parts[3] : '',
      sub3: parts.length > 4 ? parts[4] : '',
      sub4: parts.length > 5 ? parts[5] : '',
      sub5: parts.length > 6 ? parts[6] : '',
    );
  }
}

// ─────────────────────────────────────────────
// 3. AppsFlyerService
// ─────────────────────────────────────────────

class AppsFlyerService {
  AppsflyerSdk? _sdk;
  String? uid;

  Future<void> init({
    required void Function(DeepLinkResult) onDeepLink,
    required void Function(String campaign) onConversionData,
  }) async {
    if (AppConfig.afDevKey.isEmpty) {
      debugPrint('AF_DEV_KEY not set — skipping AppsFlyer init');
      return;
    }

    final options = AppsFlyerOptions(
      afDevKey: AppConfig.afDevKey,
      appId: AppConfig.appId,
      showDebug: true,
    );

    _sdk = AppsflyerSdk(options);

    _sdk!.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    _sdk!.startSDK();

    _sdk!.getAppsFlyerUID().then((id) {
      uid = id;
      debugPrint('AppsFlyer ID: $id');
    });

    _sdk!.onDeepLinking(onDeepLink);

    _sdk!.onInstallConversionData((data) {
      debugPrint('Conversion data received: $data');
      if (data is Map) {
        final payload = data['payload'] ?? data;
        final campaign = (payload is Map ? payload['campaign'] : null) as String?;
        if (campaign != null && campaign.isNotEmpty) {
          onConversionData(campaign);
        }
      }
    });
  }
}

// ─────────────────────────────────────────────
// 4. App entry point
// ─────────────────────────────────────────────

void main() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    runApp(const MyApp());
  }, (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebViewScreen(),
    );
  }
}

// ─────────────────────────────────────────────
// 5. WebViewScreen
// ─────────────────────────────────────────────

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with SingleTickerProviderStateMixin {
  late final WebViewController _controller;
  final AppsFlyerService _appsFlyerService = AppsFlyerService();

  String? _errorMessage;
  bool _isLoading = true;
  bool _isOffline = false;
  bool _deepLinkHandled = false;
  Timer? _fallbackTimer;
  String? _debugInfo; 
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  StreamSubscription? _connectivitySubscription;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (AppConfig.gameUrl.isEmpty) {
      _errorMessage = 'GAME_URL is not configured.';
      _isLoading = false;
      return;
    }

    _initWebViewController();
    _appsFlyerService.init(
      onDeepLink: _onDeepLinkResult,
      onConversionData: _onConversionCampaign,
    );
    _initConnectivityListener();

    _fallbackTimer = Timer(const Duration(seconds: 8), () {
      if (!_deepLinkHandled && mounted) {
        _loadUrl(AppConfig.gameUrl);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _connectivitySubscription?.cancel();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  void _onConversionCampaign(String campaign) {
    if (_deepLinkHandled) return;
    final parsed = DeepLinkParser.parse(campaign);
    if (parsed != null) {
      _handleDeepLink(campaign);
    }
  }

  void _onDeepLinkResult(DeepLinkResult result) {
    _fallbackTimer?.cancel();
    if (result.status == Status.FOUND) {
      final deepLink = result.deepLink;
      if (deepLink != null) {
        final val = deepLink.deepLinkValue ?? '';
        if (mounted) setState(() => _debugInfo = 'DeepLink detected: $val');
        _handleDeepLink(val);
      }
    }
  }

  Future<void> _handleDeepLink(String deepLinkValue) async {
    if (deepLinkValue.isEmpty || _deepLinkHandled) return;
    _deepLinkHandled = true;
    _fallbackTimer?.cancel();

    try {
      final data = DeepLinkParser.parse(deepLinkValue);
      if (data == null) {
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      if (mounted) setState(() => _debugInfo = 'Parsed: ${data.domain}\nResolving user...');

      final resolveUrl = '${AppConfig.supabaseUrl}/functions/v1/resolve-user?username=${data.username}';
      final response = await http.get(Uri.parse(resolveUrl));

      if (response.statusCode != 200) {
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      final afId = _appsFlyerService.uid ?? '';
      final keitaroUrl = 'https://${data.domain}/${data.alias}'
          '?sub1=${AppConfig.appId}'
          '&sub2=${data.sub2}'
          '&sub3=${data.sub3}'
          '&sub4=${data.sub4}'
          '&sub5=${data.sub5}'
          '&sub9=${AppConfig.builderProjectId}'
          '&sub10=$afId';

      if (mounted) setState(() => _debugInfo = 'Loading Keitaro URL...');
      _loadUrl(keitaroUrl);
    } catch (e, stack) {
      FirebaseCrashlytics.instance.recordError(e, stack);
      _loadUrl(AppConfig.gameUrl);
    }
  }

  void _initConnectivityListener() {
    _checkConnectivity();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (mounted) {
        final wasOffline = _isOffline;
        setState(() => _isOffline = !isConnected);
        if (wasOffline && isConnected) _retryLoading();
      }
    });
  }

  Future<void> _checkConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    final isConnected = results.any((r) => r != ConnectivityResult.none);
    if (mounted) setState(() => _isOffline = !isConnected);
  }

  void _retryLoading() {
    setState(() => _isLoading = true);
    if (!_deepLinkHandled) {
      _loadUrl(AppConfig.gameUrl);
    } else {
      _controller.reload();
    }
  }

  void _initWebViewController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _isOffline = true;
                _isLoading = false;
              });
            }
          },
        ),
      );
  }

  void _loadUrl(String url) {
    _controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) return _buildErrorScreen();
    if (_isOffline) return _buildOfflineScreen();
    return _buildWebViewScreen();
  }

  Widget _buildErrorScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.white))),
    );
  }

  Widget _buildOfflineScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white, size: 64),
            const Text('No Internet', style: TextStyle(color: Colors.white, fontSize: 24)),
            ElevatedButton(onPressed: _retryLoading, child: const Text('Try Again')),
          ],
        ),
      ),
    );
  }

  Widget _buildWebViewScreen() {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading) const Center(child: CircularProgressIndicator()),
            if (_debugInfo != null)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.black87, padding: const EdgeInsets.all(8),
                  child: Text(_debugInfo!, style: const TextStyle(color: Colors.greenAccent, fontSize: 10)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
