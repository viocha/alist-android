import 'package:flutter/services.dart';

import 'alist_models.dart';

class AListNativeApi {
  AListNativeApi();

  static const MethodChannel _channel = MethodChannel(
    'com.viocha.alist_android/runtime',
  );
  static const EventChannel _events = EventChannel(
    'com.viocha.alist_android/runtime_events',
  );

  Future<AListPaths> getPaths() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('getPaths');
    return AListPaths.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<AListStatus> getStatus() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('getStatus');
    return AListStatus.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<String> readLogs({int maxBytes = 128 * 1024}) async {
    final logs = await _channel.invokeMethod<String>(
      'readLogs',
      <String, Object?>{'maxBytes': maxBytes},
    );
    return logs ?? '';
  }

  Future<bool> ensureBinaryExecutable(String binaryPath) async {
    return await _channel.invokeMethod<bool>(
          'ensureBinaryExecutable',
          <String, Object?>{'binaryPath': binaryPath},
        ) ??
        false;
  }

  Future<OperationResult> initializeDataDirectory() async {
    final map =
        await _channel.invokeMapMethod<Object?, Object?>('initializeDataDirectory');
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> applyAdminPassword(String password) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'applyAdminPassword',
      <String, Object?>{'password': password},
    );
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> startService({
    required int port,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'startService',
      <String, Object?>{
        'port': port,
      },
    );
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> stopService() async {
    final map =
        await _channel.invokeMapMethod<Object?, Object?>('stopService');
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> updateServiceNotification({
    required int port,
    required String message,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'updateServiceNotification',
      <String, Object?>{
        'port': port,
        'message': message,
      },
    );
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> requestNotificationPermission() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'requestNotificationPermission',
    );
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Future<OperationResult> openBatterySettings() async {
    final map =
        await _channel.invokeMapMethod<Object?, Object?>('openBatterySettings');
    return OperationResult.fromMap(map ?? const <Object?, Object?>{});
  }

  Stream<AListRuntimeEvent> watchRuntimeEvents() {
    return _events.receiveBroadcastStream().map((event) {
      final map = (event as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
      return AListRuntimeEvent.fromMap(map);
    });
  }
}
