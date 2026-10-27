import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

const _placeholder = '';

const _android = FirebaseOptions(
  apiKey: 'AIzaSyDxVaJWMb717CFmYbRLzl7D74iCgmbfeHs',
  appId: '1:933974660895:android:0e29b1b1df953d14c3c22a',
  messagingSenderId: '933974660895',
  projectId: 'ims-nexus',
);

const _ios = FirebaseOptions(
  apiKey: 'AIzaSyCOj1LId6Yl6T2ASvF8QlojfwSZMtaiYKE',
  appId: '1:933974660895:ios:b8bebd2f2457d6f0c3c22a',
  messagingSenderId: '933974660895',
  projectId: 'ims-nexus',
  iosBundleId: 'org.ims.nexusmobile',
);

FirebaseOptions? get nexusFirebaseOptions {
  final FirebaseOptions options;

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      options = _android;
    case TargetPlatform.iOS:
      options = _ios;
    default:
      return null;
  }

  final filledIn = options.apiKey != _placeholder &&
      options.appId != _placeholder &&
      options.messagingSenderId != _placeholder &&
      options.projectId != _placeholder;

  return filledIn ? options : null;
}
