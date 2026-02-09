import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// This is the "dumb shell" entry point.
/// All customization is injected via --dart-define at build time.
/// GAME_URL is the only required variable — it points to the published web app.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
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

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;

  // Injected at build time via: --dart-define=GAME_URL=https://...
  static const String gameUrl = String.fromEnvironment('GAME_URL');

  String? _errorMessage;

  @override
  void initState() {
    super.initState();

    // Guard against empty or invalid GAME_URL
    if (gameUrl.isEmpty) {
      _errorMessage = 'GAME_URL is not configured.\n\nThe app was built without a valid URL. Please rebuild with a valid GAME_URL.';
      return;
    }

    Uri? parsedUri;
    try {
      parsedUri = Uri.parse(gameUrl);
      if (!parsedUri.hasScheme || !parsedUri.hasAuthority) {
        throw FormatException('Invalid URL: $gameUrl');
      }
    } catch (e) {
      _errorMessage = 'Invalid GAME_URL: $gameUrl\n\nError: $e';
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => debugPrint('Loading: $url'),
          onPageFinished: (url) => debugPrint('Loaded: $url'),
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
            setState(() {
              _errorMessage = 'Failed to load page.\n\nURL: $gameUrl\nError: ${error.description}';
            });
          },
        ),
      )
      ..loadRequest(parsedUri!);
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
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

    return Scaffold(
      body: SafeArea(
        child: WebViewView(controller: _controller),
      ),
    );
  }
}
