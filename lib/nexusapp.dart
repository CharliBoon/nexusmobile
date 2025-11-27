import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:nexusmobile/utils/storageutils.dart';
import 'package:nexusmobile/widgets/pushmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NexusWebViewApp extends StatefulWidget {
  final String initialUrl;

  NexusWebViewApp({required this.initialUrl});

  @override
  _NexusWebViewAppState createState() => _NexusWebViewAppState();
}

class _NexusWebViewAppState extends State<NexusWebViewApp> {
  late InAppWebViewController webViewController;
  bool _isLoggedIn = false;
  bool _isCheckingMail = false;
  bool _isCheckingDB = false;
  bool _firstLoad = true;
  String _dbName = '';
  String _pushToken = '';

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
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        useHybridComposition: true,
                      ),
                      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
                      onWebViewCreated: (controller) {
                        webViewController = controller;
                      },
                      onLoadStart: (controller, url) async {
                        setState(() {
                          _isCheckingMail = false;
                          _dbName = '';
                        });
                      },
                      onLoadStop: (controller, url) async {
                        if (_firstLoad) {
                          FlutterNativeSplash.remove();
                          _firstLoad = false;
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

                        if (url.toString().contains('login')) {
                          setState(() {
                            _isLoggedIn = false;
                          });
                          _startCheckingForEmail(controller);
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
                    ),
                  ),
                  if (_dbName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 10, right: 10),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.notifications),
                        label: const Text('Enable Notifications'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 30),
                          textStyle: const TextStyle(fontSize: 16),
                        ),
                        onPressed: _showManagePushDialog, // your existing method
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startCheckingForEmail(InAppWebViewController controller) async {
    if (_isCheckingMail) return;
    _isCheckingMail = true;

    await controller.evaluateJavascript(source: """
      (function() {
        var observer = new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            var inputField = document.querySelector('input[name="email"]');
            if (inputField) {
              inputField.addEventListener('input', function(event) {
                if (inputField.value) {
                  window.emailValue = inputField.value;
                }
              });
              observer.disconnect();
            }
          });
        });
        observer.observe(document.body, { childList: true, subtree: true });
      })();
    """);

    while (_isCheckingMail) {
      String? email = await controller.evaluateJavascript(source: "window.emailValue || null;") as String?;
      if (email != null && email.isNotEmpty) {
        print('Detected email: $email');
        StorageUtils.saveUserEmail(email);
        setState(() {});
      }

      await Future.delayed(const Duration(seconds: 1));
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

          // ---- NEW: fetch push token using session cookies ----
          try {
            String? pushToken = await controller.evaluateJavascript(source: """
            (async function() {
              try {
                // Send request to your backend using fetch
                const response = await fetch('/ims-nexus/resources/databases/firebase/requestPushToken', {
                  method: 'POST',
                  credentials: 'include' // <--- important: includes all cookies from this WebView
                });
                const data = await response.json();
                return data.pushToken || null;
              } catch(e) {
                return null;
              }
            })();
          """) as String?;

            if (pushToken != null && pushToken.isNotEmpty) {
              print('Push token from backend: $pushToken');

              setState(() {
                _pushToken = pushToken;
              });

            } else {
              print('No push token returned');
            }
          } catch (e) {
            print('Failed to fetch push token: $e');
          }
        }
      } else {
        setState(() {
          _dbName = '';
        });
      }

      await Future.delayed(const Duration(seconds: 1));
    }
  }

  void _showManagePushDialog() {
    showDialog(
      context: context,
      builder: (context) => PushManagerDialog(
        selectedDB: _dbName,
        pushToken: _pushToken,
        webViewController: webViewController,
      ),
    );
  }
}
