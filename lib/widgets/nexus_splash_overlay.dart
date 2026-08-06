import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class NexusSplashOverlay extends StatefulWidget {
  const NexusSplashOverlay({super.key});

  @override
  State<NexusSplashOverlay> createState() => _NexusSplashOverlayState();
}

class _NexusSplashOverlayState extends State<NexusSplashOverlay> with SingleTickerProviderStateMixin {
  late String _appVersion = '';
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _initPackageInfo();

    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.8, end: 1.3).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _appVersion = 'V ${info.version}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    return ScaleTransition(
                      scale: _animation,
                      child: child,
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24.0),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF051B2C).withValues(alpha: 0.18),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/icon/icon-2.png',
                      width: 96,
                      height: 96,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'IMS Nexus',
                  style: TextStyle(
                    color: Color(0xFF051B2C),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 25,
            left: 25,
            child: Text(
              _appVersion,
              style: const TextStyle(
                color: Colors.black38,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Positioned(
            bottom: 25,
            right: 25,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Powered by',
                  style: TextStyle(
                    color: Colors.black38,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Image.asset(
                  'assets/icon/IMS-Transparent.png',
                  height: 20,
                  width: 20,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
