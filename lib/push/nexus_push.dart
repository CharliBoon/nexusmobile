import 'dart:async';
import 'dart:convert';
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
const _savedStatesKey = 'nexus_push_saved';

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

  factory NexusRules.fromJson(Map<String, dynamic> json) {
    final rules = json['rules'];
    final chosen = json['chosen'];

    return NexusRules(
      rules: rules is Map
          ? rules.map((id, description) =>
              MapEntry(id.toString(), description.toString()))
          : {},
      chosen: chosen is List ? chosen.map((id) => id.toString()).toSet() : {},
    );
  }

  Map<String, Object> toJson() => {'rules': rules, 'chosen': chosen.toList()};
}

/// What the sheet shows for a database, kept ready so opening it needs no waiting
class NexusPushState {
  final bool registered;
  final NexusRules rules;

  NexusPushState({required this.registered, required this.rules});

  factory NexusPushState.fromJson(Map<String, dynamic> json) {
    return NexusPushState(
      registered: json['registered'] == true,
      rules: NexusRules.fromJson(Map<String, dynamic>.from(json['rules'] as Map)),
    );
  }

  Map<String, Object> toJson() =>
      {'registered': registered, 'rules': rules.toJson()};
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
  String? _token;

  bool _allowed = false;
  final _readyStates = <String, NexusPushState>{};
  final _refreshes = <String, Future<NexusPushState>>{};
  Future<void> _savedLoaded = Future.value();

  /// Changes when what the bell shows changes
  final changes = ValueNotifier<int>(0);

  bool get isAvailable => _available;

  /// Whether the phone gets notifications for the database
  bool isOn(String database) =>
      _allowed && (_readyStates[database]?.registered ?? false);

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
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _token = token;
      _registerAgain(token);
    });

    unawaited(_warmUpToken());
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
    if (session == _session) return;

    // Another user has other devices and rules
    _session = session;
    _readyStates.clear();
    _refreshes.clear();
    _savedLoaded = _loadSaved();
    changes.value++;
  }

  /// Gets the push token, whether the phone is registered and the rules of the database ahead
  /// of time, so the sheet opens at once and only posts when something is changed.
  /// Nothing is fetched before the user allowed notifications, so it never asks for that itself.
  Future<void> preload(String database) async {
    if (!_available) return;

    unawaited(_warmUp());

    try {
      await _savedLoaded;
      if (await notificationsAllowed()) await refresh(database);
    } catch (e) {
      debugPrint('Could not load the notifications of $database ahead of time: $e');
    }
  }

  // The connection is opened while the push token is still being fetched
  Future<void> _warmUp() async {
    try {
      await _dio.head('/', options: Options(validateStatus: (_) => true));
    } catch (e) {
      debugPrint('Could not warm up the connection to the mobile server: $e');
    }
  }

  Future<void> _warmUpToken() async {
    try {
      if (await notificationsAllowed()) await _pushToken();
    } catch (e) {
      debugPrint('Could not get the push token ahead of time: $e');
    }
  }

  /// Whether the phone lets this app show notifications, this never asks the user for it
  Future<bool> notificationsAllowed() async {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();

      final allowed =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
      _setAllowed(allowed);

      return allowed;
    } catch (e) {
      debugPrint('Could not check the notification permission: $e');
      return true; // the server is asked then, which is what happened before this check
    }
  }

  void _setAllowed(bool allowed) {
    if (allowed == _allowed) return;

    _allowed = allowed;
    changes.value++;
  }

  /// What is known of the database, from the last time or from the phone's memory
  Future<NexusPushState> load(String database) {
    final known = _readyStates[database];

    return known != null ? Future.value(known) : refresh(database);
  }

  /// The state of the database when it is already known
  NexusPushState? ready(String database) => _readyStates[database];

  /// Asks the server again, a refresh that is busy is shared
  Future<NexusPushState> refresh(String database) {
    return _refreshes.putIfAbsent(
        database,
        () => _fetchState(database).whenComplete(() => _refreshes.remove(database)));
  }

  Future<NexusPushState> _fetchState(String database) async {
    final session = _session;

    // The rules do not depend on the phone being registered, so both are asked together
    final (registered, rules) =
        await (isRegistered(database), fetchNotifications(database)).wait;
    final state = NexusPushState(registered: registered, rules: rules);

    // Not kept when the user changed while it was loading
    return session == _session ? _remember(database, state) : state;
  }

  NexusPushState _remember(String database, NexusPushState state) {
    _readyStates[database] = state;
    changes.value++;
    unawaited(_saveStates());

    return state;
  }

  // Kept on the phone, so the sheet has something to show right after the app starts
  Future<void> _saveStates() async {
    final session = _session;
    if (session == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
          _savedStatesKey,
          jsonEncode({
            'owner': _ownerOf(session),
            'databases': _readyStates
                .map((database, state) => MapEntry(database, state.toJson())),
          }));
    } catch (e) {
      debugPrint('Could not save the notifications: $e');
    }
  }

  Future<void> _loadSaved() async {
    final session = _session;

    try {
      final prefs = await SharedPreferences.getInstance();

      if (session == null) {
        await prefs.remove(_savedStatesKey);
        return;
      }

      final saved = jsonDecode(prefs.getString(_savedStatesKey) ?? '{}');
      if (saved is! Map || saved['owner'] != _ownerOf(session)) return;

      final databases = saved['databases'];
      if (databases is! Map || session != _session) return;

      databases.forEach((database, state) {
        _readyStates.putIfAbsent(database.toString(),
            () => NexusPushState.fromJson(Map<String, dynamic>.from(state as Map)));
      });
      changes.value++;
    } catch (e) {
      debugPrint('Could not read the saved notifications: $e');
    }
  }

  // The saved notifications are only used for the same login, and the login itself is not kept
  String _ownerOf(String session) {
    var hash = 0xcbf29ce484222325;
    for (final unit in session.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }

    return hash.toRadixString(16);
  }

  Future<bool> isRegistered(String database) async {
    final answer = await _post(_statusPath, await _deviceBody(database));

    return answer['registered'] == true;
  }

  Future<NexusPushState> register(String database) async {
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

    _setAllowed(true);

    await _post(_devicesPath, await _deviceBody(database));
    await _rememberDatabase(database, true);

    return _remember(database,
        NexusPushState(registered: true, rules: await _rulesOf(database)));
  }

  Future<NexusPushState> unregister(String database) async {
    await _post(_unregisterPath, await _deviceBody(database));
    await _rememberDatabase(database, false);

    return _remember(database,
        NexusPushState(registered: false, rules: await _rulesOf(database)));
  }

  Future<NexusRules> _rulesOf(String database) async {
    return _readyStates[database]?.rules ?? await fetchNotifications(database);
  }

  /// The TARP rules the database has and the ones the user chose
  Future<NexusRules> fetchNotifications(String database) async {
    final answer = await _post(_notificationsPath, {'database': database});

    return NexusRules.fromJson(answer);
  }

  /// Saves exactly the rules the user wants for the database, none is an empty set
  Future<void> selectNotifications(String database, Set<String> ruleIds) async {
    await _post(_selectNotificationsPath,
        {'database': database, 'ruleIds': ruleIds.toList()});

    final state = _readyStates[database];
    if (state != null) {
      _remember(
          database,
          NexusPushState(
              registered: state.registered,
              rules: NexusRules(rules: state.rules.rules, chosen: ruleIds)));
    }
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
    final known = _token;
    if (known != null) return known;

    const failed =
        'This phone could not get a push token. Check the internet connection and try again. Notifications may not be supported on this phone.';

    try {
      if (Platform.isIOS) await _waitForApplePushToken();

      final token =
          await FirebaseMessaging.instance.getToken().timeout(_tokenTimeout);
      if (token == null) throw NexusPushException(failed);

      _token = token;
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
