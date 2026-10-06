import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake native side of the `spotify_sdk` plugin for widget tests. Records every call
/// (method names only) and answers through [onCall] (default: success).
class FakeSdk {
  FakeSdk._();

  final List<String> calls = <String>[];
  Future<Object?>? Function(MethodCall call) onCall = (_) async => true;

  int count(String method) => calls.where((c) => c == method).length;

  /// Never answers (what the iOS plugin does when the connection is gone).
  static Future<Object?> silent() => Completer<Object?>().future;

  static FakeSdk install() {
    final sdk = FakeSdk._();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('spotify_sdk'), (call) {
      sdk.calls.add(call.method);
      return sdk.onCall(call);
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(const MethodChannel('spotify_sdk'), null),
    );
    return sdk;
  }
}
