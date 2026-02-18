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
  final String alias;
  final String sub2;
  final String sub3;
  final String sub4;
  final String sub5;

  const DeepLinkData({
    required this.username,
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
    if (parts.length < 2) return null;

    return DeepLinkData(
      username: parts[0],
      alias: parts[1],
      sub2: parts.length > 2 ? parts[2] : '',
      sub3: parts.length > 3 ? parts[3] : '',
      sub4: parts.length > 4 ? parts[4] : '',
      sub5: parts.length > 5 ? parts[5] : '',
    );
  }
}

// ─────────────────────────────────────────────
// 3. AppsFlyerService
// ─────────────────────────────────────────────

class AppsFlyerService {
  AppsflyerSdk? _sdk;
  String? uid;

  Future<void> init(void Function(DeepLinkResult) onDeepLink) async {
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
// 5. WebViewScreen (cleaned up)
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
      _errorMessage = 'GAME_URL is not configured.\n\nThe app was built without a valid URL. Please rebuild with a valid GAME_URL.';
      _isLoading = false;
      return;
    }

    _initWebViewController();
    _appsFlyerService.init(_onDeepLinkResult);
    _initConnectivityListener();

    Future.delayed(const Duration(seconds: 5), () {
      if (!_deepLinkHandled && mounted) {
        _loadUrl(AppConfig.gameUrl);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  // ── Deep link callback ──

  void _onDeepLinkResult(DeepLinkResult result) {
    debugPrint('Deep link result: ${result.status}');
    if (result.status == Status.FOUND) {
      final deepLink = result.deepLink;
      if (deepLink != null) {
        final deepLinkValue = deepLink.deepLinkValue ?? '';
        debugPrint('Deep link value: $deepLinkValue');
        _handleDeepLink(deepLinkValue);
      }
    }
  }

  Future<void> _handleDeepLink(String deepLinkValue) async {
    if (deepLinkValue.isEmpty || _deepLinkHandled) return;
    _deepLinkHandled = true;

    try {
      final data = DeepLinkParser.parse(deepLinkValue);
      if (data == null) {
        debugPrint('Deep link too short, loading GAME_URL');
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      final resolveUrl = '${AppConfig.supabaseUrl}/functions/v1/resolve-user?username=${data.username}';
      debugPrint('Resolving user: $resolveUrl');

      final response = await http.get(Uri.parse(resolveUrl));

      if (response.statusCode != 200) {
        debugPrint('resolve-user failed: ${response.statusCode} ${response.body}');
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      final json = jsonDecode(response.body);
      final keitaroDomain = json['keitaro_domain'] as String?;

      if (keitaroDomain == null || keitaroDomain.isEmpty) {
        debugPrint('No keitaro_domain found');
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      final afId = _appsFlyerService.uid ?? '';

      final keitaroUrl = 'https://$keitaroDomain/${data.alias}'
          '?sub1=${AppConfig.appId}'
          '&sub2=${data.sub2}'
          '&sub3=${data.sub3}'
          '&sub4=${data.sub4}'
          '&sub5=${data.sub5}'
          '&sub9=${AppConfig.builderProjectId}'
          '&sub10=$afId';

      debugPrint('Loading Keitaro URL: $keitaroUrl');
      _loadUrl(keitaroUrl);
    } catch (e, stack) {
      debugPrint('Deep link handling error: $e');
      FirebaseCrashlytics.instance.recordError(e, stack, reason: 'Deep link handling');
      _loadUrl(AppConfig.gameUrl);
    }
  }

  // ── Connectivity ──

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

  // ── WebView ──

  void _initWebViewController() {
    Uri? parsedUri;
    try {
      parsedUri = Uri.parse(AppConfig.gameUrl);
      if (!parsedUri.hasScheme || !parsedUri.hasAuthority) {
        throw FormatException('Invalid URL: ${AppConfig.gameUrl}');
      }
    } catch (e) {
      _errorMessage = 'Invalid GAME_URL: ${AppConfig.gameUrl}\n\nError: $e';
      _isLoading = false;
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('Loading: $url'),
          onPageFinished: (url) {
            debugPrint('Loaded: $url');
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            if (error.errorType == WebResourceErrorType.hostLookup ||
                error.errorType == WebResourceErrorType.connect ||
                error.errorType == WebResourceErrorType.timeout ||
                error.description.contains('net::ERR_INTERNET_DISCONNECTED') ||
                error.description.contains('net::ERR_NAME_NOT_RESOLVED') ||
                error.description.contains('net::ERR_CONNECTION')) {
              if (mounted) {
                setState(() {
                  _isOffline = true;
                  _isLoading = false;
                });
              }
            }
            FirebaseCrashlytics.instance.recordError(
              Exception('WebView error: ${error.description}'),
              null,
              reason: 'WebView resource error',
            );
          },
        ),
      );
  }

  void _loadUrl(String url) {
    _controller.loadRequest(Uri.parse(url));
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) return _buildErrorScreen();
    if (_isOffline) return _buildOfflineScreen();
    return _buildWebViewScreen();
  }

  Widget _buildErrorScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
                const SizedBox(height: 24),
                const Text(
                  'Configuration Error',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(40.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.05),
                          border: Border.all(color: Colors.white.withOpacity(0.1), width: 2),
                        ),
                        child: const Icon(Icons.wifi_off_rounded, color: Colors.white70, size: 56),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                const Text(
                  'No Internet Connection',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please check your Wi-Fi or mobile data\nand try again',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 40),
                SizedBox(
                  width: 200,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _retryLoading,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh_rounded, size: 20),
                        SizedBox(width: 8),
                        Text('Try Again', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
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
            if (_isLoading)
              const Center(child: CircularProgressIndicator(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
