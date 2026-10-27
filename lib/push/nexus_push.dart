import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

const _mobileServerUrl = 'https://mobile.imseismology.org';
///const _mobileServerUrl = 'https://localhost.za.imseismology.org:8010';

const _devicesPath = '/nexusmobile/devices';
const _unregisterPath = '/nexusmobile/devices/unregister';
const _statusPath = '/nexusmobile/devices/status';
const _notificationsPath = '/nexusmobile/notifications';
const _selectNotificationsPath = '/nexusmobile/notifications/select';

const _registeredDatabasesKey = 'nexus_push_databases';

const _startTimeout = Duration(seconds: 5);
const _tokenTimeout = Duration(seconds: 15);

class NexusPushException implements Exception {
  final String message;

  NexusPushException(this.message);

  @override
  String toString() => message;
}

/// The notification rules of a database, the id of each one with its description
class NexusRules {
  final Map<String, String> rules;
  final Set<String> chosen;

  NexusRules({required this.rules, required this.chosen});
}

class NexusPush {
  NexusPush._();

  static final NexusPush instance = NexusPush._();

  final _dio = Dio(BaseOptions(
    baseUrl: _mobileServerUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    contentType: Headers.jsonContentType,
  ));

  final _openedLinks = StreamController<String>.broadcast();

  bool _available = false;
  String? _session;

  bool get isAvailable => _available;

  Stream<String> get openedLinks => _openedLinks.stream;

  Future<void> start() async {
    final options = nexusFirebaseOptions;
    if (options == null) {
      debugPrint(
          'Push is off: fill in this platform in lib/push/firebase_options.dart');
      return;
    }

    try {
      await Firebase.initializeApp(options: options).timeout(_startTimeout);
    } catch (e) {
      debugPrint('Push is off, Firebase could not start: $e');
      return;
    }

    _available = true;

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final link = message.data['link'];
      if (link is String) _openedLinks.add(link);
    });
    FirebaseMessaging.instance.onTokenRefresh.listen(_registerAgain);
  }

  Future<String?> takeLaunchLink() async {
    if (!_available) return null;

    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      final link = message?.data['link'];
      return link is String ? link : null;
    } catch (e) {
      debugPrint('Could not read the push that started the app: $e');
      return null;
    }
  }

  void setSession(String? session) {
    _session = session;
  }

  Future<bool> isRegistered(String database) async {
    final answer = await _post(_statusPath, await _deviceBody(database));

    return answer['registered'] == true;
  }

  Future<void> register(String database) async {
    final NotificationSettings permission;
    try {
      permission = await FirebaseMessaging.instance.requestPermission();
    } catch (e) {
      debugPrint('Could not ask for notification permission: $e');
      throw NexusPushException(
          'Could not ask for notification permission. Please try again.');
    }

    if (permission.authorizationStatus == AuthorizationStatus.denied) {
      throw NexusPushException(
          'Notifications are turned off for this app. Turn them on in the phone settings and try again.');
    }

    await _post(_devicesPath, await _deviceBody(database));
    await _rememberDatabase(database, true);
  }

  Future<void> unregister(String database) async {
    await _post(_unregisterPath, await _deviceBody(database));
    await _rememberDatabase(database, false);
  }

  /// The TARP rules the database has and the ones the user chose
  Future<NexusRules> fetchNotifications(String database) async {
    final answer = await _post(_notificationsPath, {'database': database});
    final rules = answer['rules'];
    final chosen = answer['chosen'];

    return NexusRules(
      rules: rules is Map
          ? rules.map((id, description) =>
              MapEntry(id.toString(), description.toString()))
          : {},
      chosen: chosen is List ? chosen.map((id) => id.toString()).toSet() : {},
    );
  }

  /// Saves exactly the rules the user wants for the database, none is an empty set
  Future<void> selectNotifications(String database, Set<String> ruleIds) async {
    await _post(_selectNotificationsPath,
        {'database': database, 'ruleIds': ruleIds.toList()});
  }

  Future<Map<String, Object>> _deviceBody(String database) async {
    final token = await _pushToken();

    final info = await PackageInfo.fromPlatform();

    return {
      'database': database,
      'fcmToken': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'appVersion': info.version,
    };
  }

  Future<String> _pushToken() async {
    const failed =
        'This phone could not get a push token. Check the internet connection and try again. Notifications may not be supported on this phone.';

    try {
      if (Platform.isIOS) await _waitForApplePushToken();

      final token =
          await FirebaseMessaging.instance.getToken().timeout(_tokenTimeout);
      if (token == null) throw NexusPushException(failed);

      return token;
    } on NexusPushException {
      rethrow;
    } catch (e) {
      debugPrint('Could not get a push token: $e');
      throw NexusPushException(failed);
    }
  }

  // Firebase can only give an iPhone its push token after Apple has given the iPhone its own,
  // which takes a few seconds after the app starts. A simulator never gets one.
  Future<void> _waitForApplePushToken() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await FirebaseMessaging.instance.getAPNSToken() != null) return;

      await Future.delayed(const Duration(seconds: 1));
    }

    throw NexusPushException(
        'Apple has not given this iPhone a push token yet. Check that notifications are allowed for this app in the iPhone settings, that you are on a real iPhone, and try again.');
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, Object> data) async {
    final session = _session;
    if (session == null) {
      throw NexusPushException('You are not logged in.');
    }

    try {
      final response = await _dio.post(
        path,
        data: data,
        options: Options(headers: {'Cookie': 'session=$session'}),
      );

      final body = response.data;
      return body is Map<String, dynamic> ? body : {};
    } on DioException catch (e) {
      debugPrint(
          'The mobile server answered ${e.response?.statusCode} to $path: ${e.response?.data ?? e.message}');
      throw NexusPushException(_describe(e));
    }
  }

  String _describe(DioException e) {
    switch (e.response?.statusCode) {
      case null:
        return 'Could not reach the IMS server. Check your internet connection and try again or contact support@imsi.org';
      case 401:
        return 'Your session was not accepted. Please log in again.';
      case 503:
        return 'The server could not check your login right now. Please try again.';
      default:
        return 'The notification server had a problem (${e.response?.statusCode}). Please try again later.';
    }
  }

  Future<void> _registerAgain(String token) async {
    if (_session == null) return;

    final prefs = await SharedPreferences.getInstance();

    for (final database in prefs.getStringList(_registeredDatabasesKey) ?? []) {
      try {
        await _post(_devicesPath, await _deviceBody(database));
      } on NexusPushException catch (e) {
        debugPrint('Could not register the new push token for $database: $e');
      }
    }
  }

  Future<void> _rememberDatabase(String database, bool registered) async {
    final prefs = await SharedPreferences.getInstance();
    final databases = (prefs.getStringList(_registeredDatabasesKey) ?? []).toSet();

    if (registered) {
      databases.add(database);
    } else {
      databases.remove(database);
    }

    await prefs.setStringList(_registeredDatabasesKey, databases.toList());
  }
}
