import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../utils/storageutils.dart';

class PushManagerDialog extends StatefulWidget {
  final String selectedDB;

  const PushManagerDialog({
    Key? key,
    required this.selectedDB,
  }) : super(key: key);

  @override
  _PushManagerDialogState createState() => _PushManagerDialogState();
}

class _PushManagerDialogState extends State<PushManagerDialog> {
  late bool notificationsEnabled = false;
  final FirebaseMessaging messaging = FirebaseMessaging.instance;
  final database = FirebaseDatabase.instance;
  bool isLoadingNotificationState = true;

  @override
  void initState() {
    super.initState();
    _loadNotificationsState();
  }

  DatabaseReference _getUserRef(String? email, String deviceUUID) {
    final emailKey = email?.replaceAll('.', '').replaceAll('@', '');
    final deviceKey = deviceUUID.replaceAll('.', '').replaceAll('@', '');
    return database.ref('nexus_push_notifications/$emailKey-$deviceKey');
  }

  Future<void> _loadNotificationsState() async {
    String? userEmail = await StorageUtils.getUserEmail();
    String deviceUUID = await getDeviceUUID();

    try {
      final userRef = _getUserRef(userEmail, deviceUUID);

      final DataSnapshot snapshot = await userRef.get();
      bool hasPushToken = false;

      if (snapshot.exists) {
        // Load existing data
        var userData = Map<String, dynamic>.from(snapshot.value as Map);

        List<String> dbNames = (userData['dbNames'] ?? []).cast<String>();
        if (dbNames.contains(widget.selectedDB)) {
          hasPushToken = true;
        }
      }

      setState(() {
        notificationsEnabled = hasPushToken;
      });
    } catch (e) {
      print('Failed to load notifications state: $e');
    } finally {
      setState(() {
        isLoadingNotificationState = false; // Set loading to false once data is loaded
      });
    }
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
                    maxLines: 1, // Prevents overflow with a single line
                  ),
                ),
                isLoadingNotificationState
                    ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : Switch(
                  value: notificationsEnabled,
                        onChanged: (bool value) {
                          setState(() {
                            notificationsEnabled = value;
                            registerForPush(value);
                          });
                          StorageUtils.savePush(value);
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

  Future<void> registerForPush(bool isEnabled) async {
    String? userEmail = await StorageUtils.getUserEmail();
    String deviceUUID = await getDeviceUUID();
    final userRef = _getUserRef(userEmail, deviceUUID);

    if (userEmail == null || userEmail.isEmpty) {
      print('User email is null or empty. Cannot proceed.');
      return;
    }

    if (isEnabled) {
      await requestPermission();
      String? token = await messaging.getToken();

      if (token != null) {
        try {
          final DataSnapshot snapshot = await userRef.get();

          Map<String, dynamic> userData = {};
          if (snapshot.exists) {
            // Load existing data
            userData = Map<String, dynamic>.from(snapshot.value as Map);
          }

          // Update or initialize the "dbNames" list
          List<String> dbNames = List<String>.from(userData['dbNames'] ?? []);
          if (!dbNames.contains(widget.selectedDB)) {
            dbNames.add(widget.selectedDB);
          }

          // Save updated user data
          userData['email'] = userEmail;
          userData['deviceUUID'] = deviceUUID;
          userData['token'] = token;
          userData['dbNames'] = dbNames;
          userData['updatedAt'] = DateTime.now().toIso8601String();

          await userRef.set(userData);
          print('Token and DB names saved successfully to Realtime Database');

          setState(() {
            notificationsEnabled = true;
          });
        } catch (e) {
          print('Failed to save token and DB names: $e');
        }
      }
    } else {
      try {
        final DataSnapshot snapshot = await userRef.get();

        if (snapshot.exists) {
          // Load existing data
          Map<String, dynamic> userData = Map<String, dynamic>.from(snapshot.value as Map);

          // Update the "dbNames" listlocate
          List<String> dbNames = List<String>.from(userData['dbNames'] ?? []);
          dbNames.remove(widget.selectedDB);

          if (dbNames.isEmpty) {
            // If no DB names are left, remove the user entry
            await userRef.remove();
            print('User with email $userEmail deleted from Realtime Database.');
          } else {
            // Otherwise, update the user entry
            userData['dbNames'] = dbNames;
            userData['updatedAt'] = DateTime.now().toIso8601String();
            userData['deviceUUID'] = deviceUUID;

            await userRef.set(userData);
            print('DB name ${widget.selectedDB} removed for user $userEmail.');
          }
        }

        setState(() {
          notificationsEnabled = false;
        });
      } catch (e) {
        print('Failed to delete DB name for user: $e');
      }
    }
  }

  Future<void> requestPermission() async {
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus != AuthorizationStatus.authorized) {
      print('User denied permissions');
      setState(() {
        notificationsEnabled = false;
      });
    }
  }

  Future<String> getDeviceUUID() async {
    var deviceInfo = DeviceInfoPlugin();
    String uuid = const Uuid().v4();

    if (Theme.of(context).platform == TargetPlatform.iOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      uuid = iosInfo.identifierForVendor ?? uuid;
    } else if (Theme.of(context).platform == TargetPlatform.android) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      uuid = androidInfo.id ?? uuid;
    }

    return uuid;
  }
}
