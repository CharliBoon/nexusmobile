import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexusmobile/widgets/nexus_splash_overlay.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NexusWebViewApp extends StatefulWidget {
  final String initialUrl;
  final String fallbackUrl;

  const NexusWebViewApp(
      {super.key, required this.initialUrl, required this.fallbackUrl});

  @override
  _NexusWebViewAppState createState() => _NexusWebViewAppState();
}

const _cookieStoreKey = 'nexus_persisted_cookies';

class _NexusWebViewAppState extends State<NexusWebViewApp> {
  late InAppWebViewController webViewController;
  bool _isLoggedIn = false;
  bool _isCheckingDB = false;
  bool _firstLoad = true;
  bool _showSplash = true;
  bool _cookiesRestored = false;
  bool _fallbackActive = false;
  Timer? _initialLoadTimeoutTimer;
  String _dbName = '';

  @override
  void initState() {
    super.initState();
    _restoreCookies().then((_) {
      if (mounted) {
        setState(() {
          _cookiesRestored = true;
        });
        _startInitialLoadTimeoutTimer();
      }
    });
  }

  @override
  void dispose() {
    _initialLoadTimeoutTimer?.cancel();
    super.dispose();
  }

  // If the primary URL hasn't finished loading within 20s, switch to the
  // fallback URL
  void _startInitialLoadTimeoutTimer() {
    _initialLoadTimeoutTimer = Timer(const Duration(seconds: 20), () {
      if (_firstLoad && !_fallbackActive && mounted) {
        _fallbackActive = true;
        webViewController.loadUrl(
            urlRequest: URLRequest(url: WebUri(widget.fallbackUrl)));
      }
    });
  }

  // Replays cookies saved when logged in to persist app login
  Future<void> _restoreCookies() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_cookieStoreKey);
    if (stored == null || stored.isEmpty) return;

    final defaultDomain = WebUri(widget.initialUrl).host;
    try {
      final List<dynamic> savedCookies = jsonDecode(stored);
      for (final entry in savedCookies) {
        final map = entry as Map<String, dynamic>;
        final domain = (map['domain'] as String?) ?? defaultDomain;
        await CookieManager.instance().setCookie(
          url: WebUri('https://$domain'),
          name: map['name'] as String,
          value: map['value'] as String,
          path: (map['path'] as String?) ?? '/',
          domain: domain,
          isSecure: map['isSecure'] as bool?,
        );
      }
    } catch (e) {
      print('Failed to restore cookies: $e');
    }
  }

  Future<void> _handleDownload(DownloadStartRequest request) async {
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: request.url);
      final cookieHeader =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final fileName = (request.suggestedFilename?.isNotEmpty ?? false)
          ? request.suggestedFilename!
          : request.url.pathSegments.isNotEmpty
              ? request.url.pathSegments.last
              : 'download';

      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/$fileName';

      await Dio().download(
        request.url.toString(),
        filePath,
        options: Options(headers: {'Cookie': cookieHeader}),
      );

      await OpenFilex.open(filePath);
    } catch (e) {
      print('Failed to download/open file: $e');
    }
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
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom * 0.5),
            child: Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: !_cookiesRestored
                          ? const SizedBox.shrink()
                          : InAppWebView(
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                useHybridComposition: true,
                                supportMultipleWindows: true,
                                javaScriptCanOpenWindowsAutomatically: true,
                                // The webapp handles its own zoom/pan the
                                // native WebView must NEVER intercept pinch/double-tap zoom.
                                supportZoom: false,
                                builtInZoomControls: false,
                                displayZoomControls: false,
                                minimumZoomScale: 1.0,
                                maximumZoomScale: 1.0,
                                // use platform pdf explorer?
                                useOnDownloadStart: true
                              ),
                              initialUrlRequest:
                                  URLRequest(url: WebUri(widget.initialUrl)),
                              // Lets the webapp's own JS check if it's the app on every page, before any other JS runs
                              initialUserScripts: UnmodifiableListView<UserScript>([
                                UserScript(
                                  source: 'window.NexusMobileApp = true;',
                                  injectionTime:
                                      UserScriptInjectionTime.AT_DOCUMENT_START,
                                ),
                              ]),
                              onWebViewCreated: (controller) {
                                webViewController = controller;
                              },
                              onDownloadStartRequest:
                                  (controller, downloadStartRequest) =>
                                      _handleDownload(downloadStartRequest),
                              onLoadStart: (controller, url) async {
                                setState(() {
                                  _dbName = '';
                                });
                              },
                              onLoadStop: (controller, url) async {
                                if (_firstLoad) {
                                  _firstLoad = false;
                                  _initialLoadTimeoutTimer?.cancel();
                                  setState(() {
                                    _showSplash = false;
                                  });
                                }

                                final isLoginPage =
                                    url.toString().contains('login');

                                if (url != null) {
                                  SharedPreferences prefs =
                                      await SharedPreferences.getInstance();

                                  if (isLoginPage) {
                                    // Logged out (or session expired) - don't persist whatever's left in the cookie jar
                                    await prefs.remove(_cookieStoreKey);
                                  } else {
                                    final cookies = await CookieManager
                                        .instance()
                                        .getCookies(url: url);
                                    final savedCookies = cookies
                                        .map((cookie) => {
                                              'name': cookie.name,
                                              'value': cookie.value,
                                              'domain':
                                                  cookie.domain ?? url.host,
                                              'path': cookie.path ?? '/',
                                              'isSecure': cookie.isSecure,
                                            })
                                        .toList();
                                    await prefs.setString(_cookieStoreKey,
                                        jsonEncode(savedCookies));
                                  }
                                }

                                if (Platform.isIOS) {
                                  await _hideGoogleSignInButton(controller);
                                  await _hideMicrosoftSignInButton(controller);
                                }

                                if (isLoginPage) {
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
                                String message =
                                    jsAlertRequest.message ?? 'NO MESSAGE';
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
                                                action: JsAlertResponseAction
                                                    .CONFIRM,
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
                              onCreateWindow:
                                  (controller, createWindowAction) =>
                                      _openPopupWindow(createWindowAction),
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
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom * 0.6),
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

  // Apple Guideline 4.8 requires an Apple-equivalent alongside any third-party login - removing for now but can be added back if we ever do sign in with Apple
  Future<void> _hideGoogleSignInButton(
      InAppWebViewController controller) async {
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

  // Apple Guideline 4.8 requires an Apple-equivalent alongside any third-party login - removing for now but can be added back if we ever do sign in with Apple
  Future<void> _hideMicrosoftSignInButton(
      InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      (function() {
        function hideMicrosoftSignIn() {
          document.querySelectorAll('button').forEach(function(btn) {
            var text = (btn.innerText || '').trim().toLowerCase();
            if (text.indexOf('sign in with microsoft') !== -1) {
              btn.style.display = 'none';
            }
          });
        }
        hideMicrosoftSignIn();
        if (!window.__nexusHideMicrosoftObserver) {
          window.__nexusHideMicrosoftObserver = new MutationObserver(hideMicrosoftSignIn);
          window.__nexusHideMicrosoftObserver.observe(document.body, { childList: true, subtree: true });
        }
      })();
    """);
  }

  Future<void> _forgetGoogleSession() async {
    for (final host in [
      'accounts.google.com',
      'google.com',
      'www.google.com'
    ]) {
      final url = WebUri('https://$host');
      final cookies = await CookieManager.instance().getCookies(url: url);
      for (final cookie in cookies) {
        await CookieManager.instance()
            .deleteCookie(url: url, name: cookie.name);
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
      String? dbName = await controller.evaluateJavascript(
          source: 'window.dbNameValue || null;') as String?;

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
