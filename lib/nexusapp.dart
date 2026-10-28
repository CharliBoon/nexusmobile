import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexusmobile/push/nexus_push.dart';
import 'package:nexusmobile/push/push_sheet.dart';
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
const _databaseHandlerName = 'nexusDatabase';
const _popupHandlerName = 'nexusPopup';
const _actionsButtonHandlerName = 'nexusActionsButton';

// How the web app's own three dot button looks and where it is, the bell copies it
class _ActionsButton {
  final double centerY;
  final double size;
  final Color background;
  final Color icon;
  final Color? shadow;

  _ActionsButton(this.centerY, this.size, this.background, this.icon, this.shadow);

  static _ActionsButton? from(Object? data) {
    if (data is! Map) return null;

    final background = _cssColor(data['background']);
    final icon = _cssColor(data['icon']);
    final centerY = data['centerY'], size = data['size'];

    if (background == null || icon == null) return null;
    if (centerY is! num || size is! num) return null;

    return _ActionsButton(centerY.toDouble(), size.toDouble(), background, icon,
        _cssColor(data['shadow']));
  }

  // The browser gives colours as "rgb(13, 34, 48)" or "rgba(13, 34, 48, 0.5)"
  static Color? _cssColor(Object? css) {
    final match = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)')
        .firstMatch(css is String ? css : '');
    if (match == null) return null;

    return Color.fromRGBO(int.parse(match.group(1)!), int.parse(match.group(2)!),
        int.parse(match.group(3)!), double.tryParse(match.group(4) ?? '') ?? 1);
  }
}

class _NexusWebViewAppState extends State<NexusWebViewApp> {
  late InAppWebViewController webViewController;
  bool _isLoggedIn = false;
  bool _firstLoad = true;
  bool _showSplash = true;
  bool _cookiesRestored = false;
  bool _fallbackActive = false;
  Timer? _initialLoadTimeoutTimer;
  StreamSubscription<String>? _openedPushLinkSubscription;
  String? _pendingPushLink;
  String _dbName = '';
  bool _popupOpen = false;
  _ActionsButton? _actionsButton;

  @override
  void initState() {
    super.initState();
    _openedPushLinkSubscription =
        NexusPush.instance.openedLinks.listen(_openPushLink);
    NexusPush.instance.takeLaunchLink().then((link) => _pendingPushLink = link);

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
    _openedPushLinkSubscription?.cancel();
    super.dispose();
  }

  bool _keyboardVisible(BuildContext context) {
    return MediaQuery.of(context).viewInsets.bottom > 0;
  }

  void _openPushLink(String link) {
    final uri = Uri.tryParse(link);
    final nexusHosts = {
      Uri.parse(widget.initialUrl).host,
      Uri.parse(widget.fallbackUrl).host,
    };
    if (uri == null || uri.scheme != 'https' || !nexusHosts.contains(uri.host)) {
      return;
    }

    webViewController.loadUrl(urlRequest: URLRequest(url: WebUri(link)));
  }

  void _openPendingPushLink() {
    final link = _pendingPushLink;
    if (link == null) return;

    _pendingPushLink = null;
    _openPushLink(link);
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
                                controller.addJavaScriptHandler(
                                  handlerName: _databaseHandlerName,
                                  callback: (args) => _onDatabaseFooterChanged(
                                      args.isEmpty ? null : args.first),
                                );
                                controller.addJavaScriptHandler(
                                  handlerName: _popupHandlerName,
                                  callback: (args) => _onPopupChanged(
                                      args.isNotEmpty && args.first == true),
                                );
                                controller.addJavaScriptHandler(
                                  handlerName: _actionsButtonHandlerName,
                                  callback: (args) => _onActionsButtonChanged(
                                      args.isEmpty ? null : args.first),
                                );
                              },
                              onDownloadStartRequest:
                                  (controller, downloadStartRequest) =>
                                      _handleDownload(downloadStartRequest),
                              onLoadStart: (controller, url) async {
                                setState(() {
                                  _dbName = '';
                                  _popupOpen = false;
                                  _actionsButton = null;
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
                                    NexusPush.instance.setSession(null);
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

                                    final session = cookies
                                        .where((c) => c.name == 'session')
                                        .firstOrNull
                                        ?.value;
                                    NexusPush.instance.setSession(session);
                                  }
                                }

                                if (Platform.isIOS) {
                                  await _hideGoogleSignInButton(controller);
                                  await _hideMicrosoftSignInButton(controller);
                                }

                                if (isLoginPage) {
                                  setState(() {
                                    _isLoggedIn = false;
                                    _dbName = '';
                                    _popupOpen = false;
                                    _actionsButton = null;
                                  });
                                } else {
                                  setState(() {
                                    _isLoggedIn = true;
                                  });
                                  _watchDatabaseFooter(controller);
                                  _watchPopups(controller);
                                  _watchActionsButton(controller);
                                  _openPendingPushLink();
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
                ..._buildNotificationsButton(),
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

  Future<void> _watchDatabaseFooter(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      (function() {
        function report() {
          var footer = document.getElementById('dbFooter');
          var text = footer ? (footer.textContent || '').trim() : '';
          if (text !== window.__nexusLastDatabaseText) {
            window.__nexusLastDatabaseText = text;
            window.flutter_inappwebview.callHandler('$_databaseHandlerName', text);
          }
        }
        if (!window.__nexusDatabaseObserver) {
          window.__nexusDatabaseObserver = new MutationObserver(report);
          window.__nexusDatabaseObserver.observe(document.body, { childList: true, subtree: true, characterData: true });
        }
        report();
      })();
    """);
  }

  // The web app shows its popups as .n_modal elements that are hidden until they open
  Future<void> _watchPopups(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      (function() {
        function report() {
          var open = Array.prototype.some.call(
              document.querySelectorAll('.n_modal'),
              function(modal) { return window.getComputedStyle(modal).display !== 'none'; });
          if (open !== window.__nexusLastPopupOpen) {
            window.__nexusLastPopupOpen = open;
            window.flutter_inappwebview.callHandler('$_popupHandlerName', open);
          }
        }
        if (!window.__nexusPopupObserver) {
          window.__nexusPopupObserver = new MutationObserver(report);
          window.__nexusPopupObserver.observe(document.body,
              { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
        }
        report();
      })();
    """);
  }

  // The bell sits at the bottom centre, level with the web app's three dot button and in its
  // colours, so it follows the theme. Without that button, no bell.
  List<Widget> _buildNotificationsButton() {
    final actions = _actionsButton;

    if (actions == null ||
        !_isLoggedIn ||
        _dbName.isEmpty ||
        !NexusPush.instance.isAvailable ||
        _popupOpen ||
        _keyboardVisible(context)) {
      return [];
    }

    return [
      AnimatedPositioned(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        left: 0,
        right: 0,
        top: actions.centerY - actions.size / 2,
        height: actions.size,
        child: Center(
          child: SizedBox(
            width: actions.size,
            height: actions.size,
            child: Tooltip(
              message: 'Push notifications for $_dbName',
              // The same shadow as the web app's button, a Material elevation is too faint for it
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: actions.shadow ?? Colors.black26,
                        offset: const Offset(0, 3),
                        blurRadius: 3),
                  ],
                ),
                child: Material(
                  color: actions.background,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => NexusPushSheet.show(context, _dbName),
                    child: Icon(Icons.notifications_none_rounded,
                        size: actions.size * 0.5, color: actions.icon),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Future<void> _watchActionsButton(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: """
      (function() {
        // Kept outside the body, so adding it is not seen as a change of the page
        var probe = window.__nexusColourProbe;
        if (!probe) {
          probe = window.__nexusColourProbe = document.createElement('div');
          probe.style.display = 'none';
          document.documentElement.appendChild(probe);
        }
        function colour(property, value) {
          probe.style[property] = '';
          probe.style[property] = value;
          return window.getComputedStyle(probe)[property];
        }
        function report() {
          var button = document.getElementById('showActionsAction');
          var box = button ? button.getBoundingClientRect() : null;
          var visible = box && box.width > 0 && box.height > 0 &&
              window.getComputedStyle(button).visibility !== 'hidden';
          var info = visible ? {
            centerY: box.top + box.height / 2,
            size: button.offsetWidth,
            background: colour('backgroundColor', 'var(--ims-colour, #F7F7F7)'),
            icon: colour('color', 'var(--svg-fill, #484848)'),
            shadow: colour('color', 'var(--ims-shadow-colour, rgba(0, 0, 0, 0.3))')
          } : null;
          var text = JSON.stringify(info);
          if (text !== window.__nexusLastActionsButton) {
            window.__nexusLastActionsButton = text;
            window.flutter_inappwebview.callHandler('$_actionsButtonHandlerName', info);
          }
        }
        var waiting = false;
        function reportSoon() {
          if (waiting) return;
          waiting = true;
          requestAnimationFrame(function() { waiting = false; report(); });
        }
        if (!window.__nexusActionsButtonObserver) {
          window.__nexusActionsButtonObserver = new MutationObserver(reportSoon);
          window.__nexusActionsButtonObserver.observe(document.body,
              { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
          window.addEventListener('resize', reportSoon);
          document.addEventListener('transitionend', reportSoon, true);
        }
        report();
      })();
    """);
  }

  void _onActionsButtonChanged(Object? data) {
    if (mounted) {
      setState(() {
        _actionsButton = _ActionsButton.from(data);
      });
    }
  }

  void _onPopupChanged(bool open) {
    if (mounted && open != _popupOpen) {
      setState(() {
        _popupOpen = open;
      });
    }
  }

  void _onDatabaseFooterChanged(Object? footerText) {
    final database = _databaseFromFooter(footerText);

    if (mounted && database != _dbName) {
      setState(() {
        _dbName = database;
      });
    }
  }

  // "Database: Kusasalethu - elkIMS" is the database elkIMS, nothing selected gives ''
  String _databaseFromFooter(Object? footerText) {
    final match =
        RegExp(r'^Database:\s*(.+)$').firstMatch(footerText is String ? footerText.trim() : '');

    return match == null ? '' : match.group(1)!.trim().split(RegExp(r'\s+')).last;
  }
}
