import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:uuid/uuid.dart';
import '../utils/storageutils.dart';

class PushManagerDialog extends StatefulWidget {
  final String selectedDB;
  final String pushToken; // previously fetched from WebView
  final InAppWebViewController webViewController;

  const PushManagerDialog({
    Key? key,
    required this.selectedDB,
    required this.pushToken,
    required this.webViewController,
  }) : super(key: key);

  @override
  _PushManagerDialogState createState() => _PushManagerDialogState();
}

class _PushManagerDialogState extends State<PushManagerDialog> {
  bool notificationsEnabled = false;
  bool isLoading = true;
  final FirebaseMessaging messaging = FirebaseMessaging.instance;

  @override
  void initState() {
    super.initState();
    _initializePushState();
  }

  Future<void> _initializePushState() async {
    // If we already have a push token, mark notifications as enabled
    setState(() {
      notificationsEnabled = widget.pushToken.isNotEmpty;
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AlertDialog(
        title: const Text('Manage Push Notifications'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Push notifications are generated from IMS Tarp notifications. No push notifications will be sent if no tarp rules are set up.',
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Enable for ${widget.selectedDB}',
                    style: const TextStyle(overflow: TextOverflow.ellipsis),
                    maxLines: 1,
                  ),
                ),
                isLoading
                    ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : Switch(
                  value: notificationsEnabled,
                  onChanged: (value) {
                    setState(() {
                      notificationsEnabled = value;
                    });
                    _handlePushSwitch(value);
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePushSwitch(bool enable) async {
    if (enable) {
      // Step 1: Request permission
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        print('User denied notification permission');
        setState(() {
          notificationsEnabled = false;
        });
        return;
      }

      // Step 2: Get Firebase push token
      String? firebaseToken = await messaging.getToken();
      if (firebaseToken == null || firebaseToken.isEmpty) {
        print('Failed to get Firebase token');
        setState(() {
          notificationsEnabled = false;
        });
        return;
      }

      // Step 3: Inject JS into WebView to save push token via session cookie
      try {
        String? result = await widget.webViewController.evaluateJavascript(source: """
          (async function() {
            try {
              const response = await fetch('/ims-web-admin/resources/databases/remote/check/savePushToken', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                credentials: 'include',
                body: JSON.stringify({ pushToken: '$firebaseToken' })
              });
              const data = await response.json();
              return JSON.stringify(data);
            } catch(e) {
              return null;
            }
          })();
        """) as String?;

        if (result != null) {
          final Map<String, dynamic> jsonData = Map<String, dynamic>.from(jsonDecode(result));
          if (jsonData['pushTokenSuccess'] == true) {
            print('Push token saved successfully: ${jsonData['pushToken']}');
            setState(() {
              notificationsEnabled = true;
            });
          } else {
            print('Failed to save push token on server');
            setState(() {
              notificationsEnabled = false;
            });
          }
        } else {
          print('Push token request returned null');
          setState(() {
            notificationsEnabled = false;
          });
        }
      } catch (e) {
        print('Error saving push token via WebView: $e');
        setState(() {
          notificationsEnabled = false;
        });
      }
    } else {
      setState(() {
        notificationsEnabled = false;
      });
      print('Push notifications disabled');
    }
  }
}
