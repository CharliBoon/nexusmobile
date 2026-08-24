import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexusmobile/widgets/nexus_splash_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NexusWebViewApp extends StatefulWidget {
  final String initialUrl;

  const NexusWebViewApp({super.key, required this.initialUrl});

  @override
  _NexusWebViewAppState createState() => _NexusWebViewAppState();
}

class _NexusWebViewAppState extends State<NexusWebViewApp> {
  late InAppWebViewController webViewController;
  bool _isLoggedIn = false;
  bool _isCheckingDB = false;
  bool _firstLoad = true;
  bool _showSplash = true;
  String _dbName = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;

        if (await webViewController.canGoBack()) {
          webViewController.goBack();
        } else {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom * 0.5),
            child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        useHybridComposition: true,
                        supportMultipleWindows: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        // The webapp handles its own zoom/pan (e.g. the 3D plot); the
                        // native WebView must never intercept pinch/double-tap zoom.
                        supportZoom: false,
                        builtInZoomControls: false,
                        displayZoomControls: false,
                        minimumZoomScale: 1.0,
                        maximumZoomScale: 1.0,
                      ),
                      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
                      onWebViewCreated: (controller) {
                        webViewController = controller;
                      },
                      onLoadStart: (controller, url) async {
                        setState(() {
                          _dbName = '';
                        });
                      },
                      onLoadStop: (controller, url) async {
                        if (_firstLoad) {
                          _firstLoad = false;
                          setState(() {
                            _showSplash = false;
                          });
                        }

                        if (url != null) {
                          final cookies = await CookieManager.instance().getCookies(url: url);
                          SharedPreferences prefs = await SharedPreferences.getInstance();

                          for (var cookie in cookies) {
                            await prefs.setString('cookie_${cookie.name}', cookie.value);
                            print('Cooky: ${cookie.name}');
                          }
                          print("Cookies saved to SharedPreferences.");
                        }

                        if (Platform.isIOS) {
                          await _hideGoogleSignInButton(controller);
                        }

                        if (url.toString().contains('login')) {
                          setState(() {
                            _isLoggedIn = false;
                          });
                        } else {
                          setState(() {
                            _isLoggedIn = true;
                          });
                          _startCheckingForDB(controller);
                        }
                      },
                      onJsAlert: (controller, jsAlertRequest) async {
                        String message = jsAlertRequest.message ?? 'NO MESSAGE';
                        return await showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('JS Alert'),
                                content: Text(message),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(
                                      context,
                                      JsAlertResponse(
                                        handledByClient: true,
                                        action: JsAlertResponseAction.CONFIRM,
                                      ),
                                    ),
                                    child: const Text('OK'),
                                  ),
                                ],
                              ),
                            ) ??
                            JsAlertResponse(
                              handledByClient: false,
                            );
                      },
                      onProgressChanged: (controller, progress) {
                        if (progress == 100) {
                          setState(() {});
                        }
                      },
                      onCreateWindow: (controller, createWindowAction) => _openPopupWindow(createWindowAction),
                    ),
                  ),
                ],
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: _showSplash
                    ? const NexusSplashOverlay(key: ValueKey('splash'))
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _openPopupWindow(CreateWindowAction createWindowAction) async {
    // Forget any existing Google session so the account picker is shown
    // every time, instead of silently reusing the last signed-in account.
    // Popups can start on 'about:blank' before JS navigates them to the
    // real Google URL, so this isn't gated on the popup's initial host.
    await _forgetGoogleSession();

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom * 0.6),
              child: InAppWebView(
                windowId: createWindowAction.windowId,
                initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
                onCloseWindow: (controller) => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      ),
    );
    return true;
  }

  // Apple Guideline 4.8 requires an Apple-equivalent alongside any third-party login.
  // The webapp's "Sign in with email" already requires the same manual account
  // approval as Google, so on iOS we simply don't offer the Google option at all
  Future<void> _hideGoogleSignInButton(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      (function() {
        function hideGoogleSignIn() {
          document.querySelectorAll('button').forEach(function(btn) {
            var text = (btn.innerText || '').trim().toLowerCase();
            if (text.indexOf('sign in with google') !== -1) {
              btn.style.display = 'none';
            }
          });
        }
        hideGoogleSignIn();
        if (!window.__nexusHideGoogleObserver) {
          window.__nexusHideGoogleObserver = new MutationObserver(hideGoogleSignIn);
          window.__nexusHideGoogleObserver.observe(document.body, { childList: true, subtree: true });
        }
      })();
    """);
  }

  Future<void> _forgetGoogleSession() async {
    for (final host in ['accounts.google.com', 'google.com', 'www.google.com']) {
      final url = WebUri('https://$host');
      final cookies = await CookieManager.instance().getCookies(url: url);
      for (final cookie in cookies) {
        await CookieManager.instance().deleteCookie(url: url, name: cookie.name);
      }
    }
  }

  void _startCheckingForDB(InAppWebViewController controller) async {
    _isCheckingDB = true;

    // Observe the DB field in the page
    await controller.evaluateJavascript(source: """
    (function() {
      var observer = new MutationObserver(function(mutations) {
        mutations.forEach(function(mutation) {
          var dbField = document.getElementById('dbFooter');
          if (dbField) {
            window.dbNameValue = dbField.textContent || '';
          }
        });
      });
      observer.observe(document.body, { childList: true, subtree: true });
    })();
  """);

    while (_isCheckingDB) {
      // Get the DB name from the page
      String? dbName = await controller.evaluateJavascript(source: 'window.dbNameValue || null;') as String?;

      if (dbName != null && dbName.isNotEmpty) {
        List<String> split = dbName.split(' ');
        String processedDBName = split.last.trim();

        if (processedDBName.contains('IMS') && _dbName != processedDBName) {
          setState(() {
            _dbName = processedDBName;
            _isLoggedIn = true;
            _isCheckingDB = false;
          });
        }
      } else {
        setState(() {
          _dbName = '';
        });
      }

      await Future.delayed(const Duration(seconds: 1));
    }
  }
}
