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
  /// Format: username_domain_alias_sub2_sub3_sub4_sub5
  /// Domain hyphens are converted to dots
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
          debugPrint('Campaign from conversion data: $campaign');
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

class _WebViewScreenState extends State<WebViewScreen>
    with SingleTickerProviderStateMixin {
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
      _errorMessage =
          'GAME_URL is not configured.\n\nThe app was built without a valid URL. Please rebuild with a valid GAME_URL.';
      _isLoading = false;
      return;
    }

    _initWebViewController();
    _appsFlyerService.init(
      onDeepLink: _onDeepLinkResult,
      onConversionData: _onConversionCampaign,
    );
    _initConnectivityListener();

    _fallbackTimer = Timer(const Duration(seconds: 5), () {
      if (!_deepLinkHandled && mounted) {
        debugPrint('DEBUG: 5s fallback timer fired — loading game URL');
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

  // ── Conversion data fallback ──

  void _onConversionCampaign(String campaign) {
    if (_deepLinkHandled) return;
    final parsed = DeepLinkParser.parse(campaign);
    if (parsed != null) {
      debugPrint('Using campaign name as fallback deep link: $campaign');
      _handleDeepLink(campaign);
    } else {
      debugPrint('Campaign name does not match deep link pattern: $campaign');
    }
  }

  // ── Deep link callback ──

  void _onDeepLinkResult(DeepLinkResult result) {
    debugPrint('Deep link result: ${result.status}');
    _fallbackTimer?.cancel();

    if (result.status == Status.FOUND) {
      final deepLink = result.deepLink;
      if (deepLink == null) {
        if (mounted) setState(() => _debugInfo = 'DeepLink object is NULL');
        return;
      }

      final deepLinkValue = deepLink.deepLinkValue ?? '';
      String? clickEvent;
      try {
        clickEvent = deepLink.clickEvent.toString();
      } catch (_) {
        clickEvent = 'clickEvent unavailable';
      }

      final fullDump =
          'deepLinkValue: "$deepLinkValue"\nclickEvent: $clickEvent';
      debugPrint('DEBUG FULL DUMP:\n$fullDump');
      if (mounted) setState(() => _debugInfo = 'Full Map:\n$fullDump');

      String resolvedValue = deepLinkValue;

      if (resolvedValue.isEmpty) {
        try {
          final event = deepLink.clickEvent;
          if (event is Map) {
            for (final key in [
              'deep_link_value',
              'link',
              'click_http_referrer',
              'af_dp',
              'deep_link_sub1',
              'campaign'
            ]) {
              final v = event[key];
              if (v != null && v.toString().isNotEmpty) {
                resolvedValue = v.toString();
                debugPrint(
                    'DEBUG: Found value in clickEvent["$key"]: $resolvedValue');
                break;
              }
            }
          }
        } catch (e) {
          debugPrint('DEBUG: Error scanning clickEvent: $e');
        }
      }

      if (resolvedValue.isEmpty) {
        for (final key in [
          'deep_link_value',
          'link',
          'click_http_referrer',
          'af_dp',
          'deep_link_sub1'
        ]) {
          try {
            final v = deepLink.getStringValue(key);
            if (v != null && v.isNotEmpty) {
              resolvedValue = v;
              debugPrint(
                  'DEBUG: Found value via getStringValue("$key"): $resolvedValue');
              break;
            }
          } catch (_) {}
        }
      }

      if (resolvedValue.isEmpty) {
        debugPrint('DEBUG: All deep link fields empty, falling back to game');
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      _handleDeepLink(resolvedValue);
    } else {
      if (mounted) {
        setState(() => _debugInfo = 'DeepLink status: ${result.status}');
      }
    }
  }

  // ── Handle deep link ──

  Future<void> _handleDeepLink(String deepLinkValue) async {
    String s1 = '';
    String s2 = '';
    String s3 = '';

    try {
      if (deepLinkValue.isEmpty || _deepLinkHandled) return;
      _deepLinkHandled = true;
      _fallbackTimer?.cancel();

      // Strip URI scheme
      String cleanValue = deepLinkValue;
      final schemeIdx = cleanValue.indexOf('://');
      if (schemeIdx != -1) {
        cleanValue = cleanValue.substring(schemeIdx + 3);
      }
      cleanValue = cleanValue.replaceAll(RegExp(r'^/+|/+$'), '').trim();

      debugPrint('DEBUG: Cleaned value: $cleanValue');

      final data = DeepLinkParser.parse(cleanValue);
      if (data == null) {
        final parts = cleanValue.split('_');
        s1 = 'PARSE FAILED: Got ${parts.length} parts (need >=3): $parts';
        debugPrint('DEBUG: $s1');
        if (mounted) setState(() => _debugInfo = s1);
        _loadUrl(AppConfig.gameUrl);
        return;
      }

      // Step 1: parsed OK
      s1 = 'S1: user=${data.username} dom=${data.domain} alias=${data.alias} sub2=${data.sub2}';
      debugPrint('DEBUG: $s1');
      if (mounted) setState(() => _debugInfo = s1);

      // Step 2: resolve-user (bypass if missing or error)
      if (AppConfig.supabaseUrl.isEmpty) {
        s2 = 'S2: SKIPPED — SUPABASE_URL is empty';
        debugPrint('DEBUG: $s2');
      } else {
        final resolveUrl =
            '${AppConfig.supabaseUrl}/functions/v1/resolve-user?username=${data.username}';
        try {
          final response = await http.get(Uri.parse(resolveUrl));
          s2 = 'S2: ${response.statusCode} — ${response.body}';
        } catch (netErr) {
          s2 = 'S2: NET ERROR: $netErr — bypassing';
        }
        debugPrint('DEBUG: $s2');
      }
      if (mounted) setState(() => _debugInfo = '$s1\n$s2');

      // Step 3: build Keitaro URL
      final afId = _appsFlyerService.uid ?? 'no-uid';
      final keitaroUrl = 'https://${data.domain}/${data.alias}'
          '?sub1=${AppConfig.appId}'
          '&sub2=${data.sub2}'
          '&sub3=${data.sub3}'
          '&sub4=${data.sub4}'
          '&sub5=${data.sub5}'
          '&sub9=${AppConfig.builderProjectId}'
          '&sub10=$afId';

      s3 = 'S3: Loading $keitaroUrl';
      debugPrint('DEBUG: $s3');
      if (mounted) setState(() => _debugInfo = '$s1\n$s2\n$s3');
      _loadUrl(keitaroUrl);
    } catch (e, stack) {
      debugPrint('FATAL in _handleDeepLink: $e\n$stack');
      if (mounted) setState(() => _debugInfo = 'FATAL: $e\n$s1\n$s2\n$s3');
      FirebaseCrashlytics.instance
          .recordError(e, stack, reason: 'Deep link handling');
      _loadUrl(AppConfig.gameUrl);
    }
  }

  // ── Connectivity ──

  void _initConnectivityListener() {
    _checkConnectivity();
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
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
                error.description
                    .contains('net::ERR_INTERNET_DISCONNECTED') ||
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
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 64),
                const SizedBox(height: 24),
                const Text(
                  'Configuration Error',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.5),
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
                          border: Border.all(
                              color: Colors.white.withOpacity(0.1), width: 2),
                        ),
                        child: const Icon(Icons.wifi_off_rounded,
                            color: Colors.white70, size: 56),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                const Text(
                  'No Internet Connection',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Please check your Wi-Fi or mobile data\nand try again',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white54, fontSize: 16, height: 1.5),
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
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh_rounded, size: 20),
                        SizedBox(width: 8),
                        Text('Try Again',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
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
              const Center(
                  child: CircularProgressIndicator(color: Colors.white)),
            if (_debugInfo != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => setState(() => _debugInfo = null),
                  child: Container(
                    color: Colors.black.withOpacity(0.85),
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _debugInfo!,
                      style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 10,
                          fontFamily: 'monospace'),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
