import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Use environment variable or fallback
    const gameUrl = String.fromEnvironment('GAME_URL', 
      defaultValue: 'https://andro-dream-studio.lovable.app');
    
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GameWebView(url: gameUrl),
    );
  }
}

class GameWebView extends StatefulWidget {
  final String url;
  const GameWebView({super.key, required this.url});

  @override
  State<GameWebView> createState() => _GameWebViewState();
}

class _GameWebViewState extends State<GameWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
