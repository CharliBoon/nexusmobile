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

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: Stack(children: [
          Column(children: [
            Expanded(
              child: InAppWebView(
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
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

                  // Save cookies here
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
                  String? nullableString = jsAlertRequest.message;
                  String nonNullableString = nullableString ?? 'NO MESSAGE';

                  return await showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('JS Alert'),
                          content: Text(nonNullableString),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(
                                  context,
                                  JsAlertResponse(
                                    handledByClient: true,
                                    action: JsAlertResponseAction.CONFIRM,
                                  )),
                              child: const Text('OK'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(
                                context,
                                JsPromptResponse(
                                  handledByClient: true,
                                  action: JsPromptResponseAction.CANCEL,
                                  value: '',
                                ),
                              ),
                              child: const Text('Cancel'),
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
          ]),
        ]),
        //bottomNavigationBar: !_isLoggedIn || _dbName.isEmpty
        //    ? null
        //    : Container(
        //        color: Colors.white.withOpacity(0.1),
        //child: SafeArea(
        // child: Padding(
        //  padding: const EdgeInsets.all(8.0),
        //   child: ElevatedButton(
        //    onPressed: () => _showManagePushDialog(),
        //    style: ElevatedButton.styleFrom(
        //       backgroundColor: const Color(0xFF051B2C).withOpacity(0.2),
        //       foregroundColor: const Color(0xFF051B2C),
        //       shadowColor: Colors.transparent,
        //     ),
        //    child: const Row(
        //      mainAxisSize: MainAxisSize.min,
        //      children: [
        //        Icon(Icons.notifications, size: 20),
        //         SizedBox(width: 8),
        //        Text('Manage Push Notifications'),
        //       ],
        //    ),
        //    ),
        //),
        //),
        //   ),
      ),
    );
  }

  void _startCheckingForEmail(InAppWebViewController controller) async {
    if (_isCheckingMail) return; // Prevent multiple checks at the same time
    _isCheckingMail = true;
    // Inject JavaScript to monitor the input field and store its value
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
                                observer.disconnect(); // Stop observing once the input field is found
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

    // Inject JavaScript to observe the DOM for the DB name
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

    // Continuously check for the dbName until found
    while (_isCheckingDB) {
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

  void _showManagePushDialog() {
    showDialog(
      context: context,
      builder: (context) => PushManagerDialog(
        selectedDB: _dbName,
      ),
    );
  }
}
