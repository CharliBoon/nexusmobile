import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:rxdart/rxdart.dart';

import 'firebase_options.dart';
import 'nexusapp.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('Handling a background message: ${message.messageId}');
}

final _messageStreamController = BehaviorSubject<RemoteMessage>();
String _currentUrl = 'https://nexus.imseismology.org';

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  var connectivityResult = await Connectivity().checkConnectivity();
  for (var result in connectivityResult) {
    if (result == ConnectivityResult.none) {
      FlutterNativeSplash.remove();

      runApp(MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF051B2C),
          ),
        ),
        home: Scaffold(
          body: GestureDetector(
            onTap: () {
              SystemNavigator.pop();
            },
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'IMS Nexus Mobile requires an internet connection to function properly. Please connect to the internet and restart the app to continue.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () {
                        SystemNavigator.pop();
                      },
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      return; // Do not proceed further
    }
  }

  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    _messageStreamController.sink.add(message);
  });

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    if (message.data.containsKey('nexusurl')) {
      _currentUrl = message.data['nexusurl'];
    }
  });

  runApp(NexusMobile());
}

class NexusMobile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF051B2C),
        ),
      ),
      home: NexusWebViewApp(initialUrl: _currentUrl),
    );
  }
}
