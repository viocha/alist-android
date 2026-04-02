import 'dart:convert';

class OperationResult {
  const OperationResult({
    required this.success,
    required this.message,
    this.shouldNotify = true,
  });

  final bool success;
  final String message;
  final bool shouldNotify;

  factory OperationResult.fromMap(Map<Object?, Object?> map) {
    return OperationResult(
      success: map['success'] == true,
      message: (map['message'] as String?) ?? 'Unknown result.',
      shouldNotify: map['shouldNotify'] != false,
    );
  }
}

class AListPaths {
  const AListPaths({
    required this.filesDir,
    required this.runtimeDir,
    required this.binaryPath,
    required this.dataDir,
    required this.configPath,
    required this.logPath,
    required this.primaryAbi,
    required this.supportedAbis,
  });

  final String filesDir;
  final String runtimeDir;
  final String binaryPath;
  final String dataDir;
  final String configPath;
  final String logPath;
  final String primaryAbi;
  final List<String> supportedAbis;

  factory AListPaths.fromMap(Map<Object?, Object?> map) {
    return AListPaths(
      filesDir: (map['filesDir'] as String?) ?? '',
      runtimeDir: (map['runtimeDir'] as String?) ?? '',
      binaryPath: (map['binaryPath'] as String?) ?? '',
      dataDir: (map['dataDir'] as String?) ?? '',
      configPath: (map['configPath'] as String?) ?? '',
      logPath: (map['logPath'] as String?) ?? '',
      primaryAbi: (map['primaryAbi'] as String?) ?? 'unknown',
      supportedAbis: (map['supportedAbis'] as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

class AListStatus {
  const AListStatus({
    required this.running,
    required this.port,
    required this.startedAt,
    required this.lastExitCode,
    required this.lastMessage,
    required this.binaryReady,
    required this.configExists,
    required this.logExists,
    required this.pid,
    required this.paths,
  });

  final bool running;
  final int? port;
  final DateTime? startedAt;
  final int? lastExitCode;
  final String lastMessage;
  final bool binaryReady;
  final bool configExists;
  final bool logExists;
  final int? pid;
  final AListPaths? paths;

  factory AListStatus.initial() {
    return const AListStatus(
      running: false,
      port: null,
      startedAt: null,
      lastExitCode: null,
      lastMessage: '正在初始化…',
      binaryReady: false,
      configExists: false,
      logExists: false,
      pid: null,
      paths: null,
    );
  }

  factory AListStatus.fromMap(Map<Object?, Object?> map) {
    final startedAtEpochMs = _asInt(map['startedAtEpochMs']);
    final pathsMap = map['paths'] as Map<Object?, Object?>?;
    return AListStatus(
      running: map['running'] == true,
      port: _asInt(map['port']),
      startedAt: startedAtEpochMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedAtEpochMs),
      lastExitCode: _asInt(map['lastExitCode']),
      lastMessage: (map['lastMessage'] as String?) ?? 'Unknown status.',
      binaryReady: map['binaryReady'] == true,
      configExists: map['configExists'] == true,
      logExists: map['logExists'] == true,
      pid: _asInt(map['pid']),
      paths: pathsMap == null ? null : AListPaths.fromMap(pathsMap),
    );
  }
}

class RuntimeMetadata {
  const RuntimeMetadata({
    required this.tagName,
    required this.assetName,
    required this.downloadUrl,
    required this.abi,
    required this.downloadedAt,
  });

  final String tagName;
  final String assetName;
  final String downloadUrl;
  final String abi;
  final DateTime downloadedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'tag_name': tagName,
      'asset_name': assetName,
      'download_url': downloadUrl,
      'abi': abi,
      'downloaded_at': downloadedAt.toIso8601String(),
    };
  }

  factory RuntimeMetadata.fromJson(Map<String, Object?> json) {
    return RuntimeMetadata(
      tagName: (json['tag_name'] as String?) ?? 'unknown',
      assetName: (json['asset_name'] as String?) ?? 'unknown',
      downloadUrl: (json['download_url'] as String?) ?? '',
      abi: (json['abi'] as String?) ?? 'unknown',
      downloadedAt: DateTime.tryParse(json['downloaded_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static RuntimeMetadata? tryParse(String source) {
    try {
      final json = jsonDecode(source);
      if (json is Map<String, Object?>) {
        return RuntimeMetadata.fromJson(json);
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

enum AListRuntimeEventType {
  status,
  logs,
}

class AListRuntimeEvent {
  const AListRuntimeEvent({
    required this.type,
    this.status,
    this.logs = '',
  });

  final AListRuntimeEventType type;
  final AListStatus? status;
  final String logs;

  factory AListRuntimeEvent.fromMap(Map<Object?, Object?> map) {
    final rawType = (map['type'] as String?) ?? 'status';
    final statusMap = map['status'] as Map<Object?, Object?>?;
    return AListRuntimeEvent(
      type: rawType == 'logs'
          ? AListRuntimeEventType.logs
          : AListRuntimeEventType.status,
      status: statusMap == null ? null : AListStatus.fromMap(statusMap),
      logs: (map['logs'] as String?) ?? '',
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}
