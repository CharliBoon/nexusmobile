import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'nexusapp.dart';

String _currentUrl = 'https://nexus.imsi.org';
String _fallbackUrl = 'https://nexus.imseismology.org';

//DEV
//String _currentUrl = 'https://hk47.au.imseismology.org:8030';
//String _fallbackUrl = 'https://10.11.13.1:8030';

//DEV LocalHost (requires `adb reverse tcp:12305 tcp:12305`)
//String _currentUrl = 'https://172.25.3.36:12305';
//String _fallbackUrl = 'https://172.25.3.36:12305';

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
  );

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

  runApp(NexusMobile());
  FlutterNativeSplash.remove();
}

class NexusMobile extends StatelessWidget {
  const NexusMobile({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF051B2C),
        ),
      ),
      home: NexusWebViewApp(initialUrl: _currentUrl, fallbackUrl: _fallbackUrl),
    );
  }
}
