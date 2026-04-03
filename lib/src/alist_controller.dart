import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'alist_models.dart';
import 'alist_native_api.dart';
import 'runtime_downloader.dart';

class AListController extends ChangeNotifier {
  AListController({
    AListNativeApi? nativeApi,
    RuntimeDownloader? runtimeDownloader,
  })  : _nativeApi = nativeApi ?? AListNativeApi(),
        _runtimeDownloader = runtimeDownloader ?? RuntimeDownloader();

  static const String _prefsPortKey = 'preferred_port';
  static const String _prefsPasswordKey = 'preferred_admin_password';
  static const int maxVisibleLogLines = 300;
  static final RegExp _ansiEscapePattern =
      RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
  static final RegExp _controlCharsPattern =
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');
  static final RegExp _logLevelPrefixPattern = RegExp(
    r'^(?:\[(?:stdout|stderr)\]\s+)?(?:INFO|WARN|ERRO|FATA|DEBU|TRAC|PANI)\[[^\]]+\]\s*',
    multiLine: true,
  );
  static final RegExp _timestampPrefixPattern = RegExp(
    r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*',
  );
  static final List<RegExp> _importantLogPatterns = <RegExp>[
    RegExp(r'\bwarn(?:ing)?\b', caseSensitive: false),
    RegExp(r'\berr(?:or|o)?\b', caseSensitive: false),
    RegExp(r'\bfail(?:ed|ure)?\b', caseSensitive: false),
    RegExp(r'\bfatal\b', caseSensitive: false),
    RegExp(r'\bpanic\b', caseSensitive: false),
    RegExp(r'\bexception\b', caseSensitive: false),
    RegExp(r'\brefused\b', caseSensitive: false),
    RegExp(r'\bdenied\b', caseSensitive: false),
    RegExp(r'\btimeout\b', caseSensitive: false),
    RegExp(r'\btimed out\b', caseSensitive: false),
    RegExp(r'\balready in use\b', caseSensitive: false),
    RegExp(r'\bmissing\b', caseSensitive: false),
    RegExp(r'\bunable\b', caseSensitive: false),
    RegExp(r"\bcan't\b", caseSensitive: false),
  ];

  final AListNativeApi _nativeApi;
  final RuntimeDownloader _runtimeDownloader;

  SharedPreferences? _preferences;
  StreamSubscription<AListRuntimeEvent>? _runtimeEventsSubscription;
  bool _refreshing = false;
  bool _autoSaveInProgress = false;
  int _autoSaveRequestedRevision = 0;
  int _autoSaveCompletedRevision = 0;

  bool initialized = false;
  bool busy = false;
  String busyMessage = '';
  double? busyProgress;
  String logs = '';
  String portInput = '5244';
  String adminPassword = '';
  bool passwordVisible = false;
  bool autoSavePending = false;
  RuntimeMetadata? installedRuntime;
  AListPaths? paths;
  AListStatus status = AListStatus.initial();

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    final envPassword = await _readPasswordFromEnv();
    portInput = _preferences?.getString(_prefsPortKey) ?? '5244';
    adminPassword =
        _preferences?.getString(_prefsPasswordKey) ?? envPassword ?? '';

    paths = await _nativeApi.getPaths();
    installedRuntime = await _readRuntimeMetadata();
    await refresh();

    _runtimeEventsSubscription?.cancel();
    _runtimeEventsSubscription = _nativeApi.watchRuntimeEvents().listen(
      _handleRuntimeEvent,
      onError: (_) {},
    );
    initialized = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _runtimeEventsSubscription?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (_refreshing || paths == null) {
      return;
    }

    _refreshing = true;
    try {
      status = await _nativeApi.getStatus();
      logs = _trimLogs(await _nativeApi.readLogs());
      installedRuntime ??= await _readRuntimeMetadata();
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<OperationResult> installRuntime({bool force = false}) async {
    return _runBusy(
      label: '准备安装内置运行时…',
      action: () => _installRuntimeInternal(force: force),
    );
  }

  Future<OperationResult> startService() async {
    final port = _parsePort();
    if (port == null) {
      return const OperationResult(
        success: false,
        message: '端口必须是 1 到 65535 之间的数字。',
        shouldNotify: false,
      );
    }

    return _runBusy(
      label: '正在启动 AList…',
      action: () async {
        final permissionResult = await _ensureNotificationPermission();
        if (!permissionResult.success) {
          return permissionResult;
        }

        final runtimeResult = await _installRuntimeInternal(force: false);
        if (!runtimeResult.success) {
          return runtimeResult;
        }

        await _saveSettingsSilently(port: port);
        await _persistPreferences();

        final result = await _nativeApi.startService(
          port: port,
          password: adminPassword.trim(),
        );
        return OperationResult(
          success: result.success,
          message: result.message,
          shouldNotify: false,
        );
      },
    );
  }

  Future<OperationResult> stopService() async {
    return _runBusy(
      label: '正在停止 AList…',
      action: () async {
        final result = await _nativeApi.stopService();
        return OperationResult(
          success: result.success,
          message: result.message,
          shouldNotify: false,
        );
      },
    );
  }

  Future<OperationResult> importConfig() async {
    if (status.running) {
      return const OperationResult(success: false, message: '请先停止服务，再导入配置文件。');
    }
    final currentPaths = paths;
    if (currentPaths == null) {
      return const OperationResult(success: false, message: '应用路径尚未就绪。');
    }

    return _runBusy(
      label: '正在导入配置文件…',
      action: () async {
        final file = await FilePicker.platform.pickFiles(
          dialogTitle: '选择要导入的 AList 配置',
          type: FileType.custom,
          allowedExtensions: const <String>['json'],
          withData: true,
        );
        if (file == null || file.files.isEmpty) {
          return const OperationResult(
            success: false,
            message: '已取消导入。',
            shouldNotify: false,
          );
        }

        final bytes = file.files.single.bytes;
        if (bytes == null) {
          return const OperationResult(success: false, message: '读取配置文件失败。');
        }

        final configFile = File(currentPaths.configPath);
        await configFile.parent.create(recursive: true);
        await configFile.writeAsBytes(bytes, flush: true);

        final importedPort = await _readPortFromConfig();
        if (importedPort != null) {
          portInput = '$importedPort';
        }
        await _persistPreferences();
        await refresh();
        return const OperationResult(success: true, message: '配置文件已导入。');
      },
    );
  }

  Future<OperationResult> exportConfig() async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return const OperationResult(success: false, message: '应用路径尚未就绪。');
    }

    return _runBusy(
      label: '正在导出配置文件…',
      action: () async {
        final configFile = File(currentPaths.configPath);
        if (!await configFile.exists()) {
          final port = _parsePort() ?? 5244;
          await _prepareConfigFile(port: port);
        }

        final bytes = await configFile.readAsBytes();
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: '导出 AList 配置',
          fileName: 'alist-config-${_timestampForFileName()}.json',
          type: FileType.custom,
          allowedExtensions: const <String>['json'],
          bytes: bytes,
        );

        if (savedPath == null) {
          return const OperationResult(
            success: false,
            message: '已取消导出。',
            shouldNotify: false,
          );
        }

        return OperationResult(
          success: true,
          message: '配置文件已导出到 $savedPath',
        );
      },
    );
  }

  Future<OperationResult> clearLogs() async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return const OperationResult(success: false, message: '应用路径尚未就绪。');
    }

    return _runBusy(
      label: '正在清空日志…',
      action: () async {
        final logFile = File(currentPaths.logPath);
        await logFile.parent.create(recursive: true);
        await logFile.writeAsString('', flush: true);
        logs = '';
        notifyListeners();
        return const OperationResult(
          success: true,
          message: '日志已清空。',
          shouldNotify: false,
        );
      },
    );
  }

  Future<OperationResult> toggleService() {
    if (status.running) {
      return stopService();
    }
    return startService();
  }

  void setPortInput(String value) {
    portInput = value;
    _scheduleAutoSave();
    notifyListeners();
  }

  void setAdminPassword(String value) {
    adminPassword = value;
    _scheduleAutoSave();
    notifyListeners();
  }

  void togglePasswordVisibility() {
    passwordVisible = !passwordVisible;
    notifyListeners();
  }

  Future<OperationResult> _runBusy({
    required String label,
    required Future<OperationResult> Function() action,
  }) async {
    if (busy) {
      return const OperationResult(success: false, message: '当前有任务正在执行，请稍候。');
    }

    busy = true;
    busyMessage = label;
    busyProgress = null;
    notifyListeners();

    try {
      return await action();
    } catch (error) {
      return OperationResult(success: false, message: '$error');
    } finally {
      busy = false;
      busyMessage = '';
      busyProgress = null;
      notifyListeners();
    }
  }

  Future<OperationResult> _installRuntimeInternal({required bool force}) async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return const OperationResult(success: false, message: 'Native paths are not ready.');
    }

    final metadata = await _runtimeDownloader.ensureLatestRuntime(
      paths: currentPaths,
      force: force,
      onProgress: (message, progress) {
        busyMessage = message;
        busyProgress = progress;
        notifyListeners();
      },
    );
    final executable = await _nativeApi.ensureBinaryExecutable(currentPaths.binaryPath);
    if (!executable) {
      return const OperationResult(
        success: false,
        message: '运行时安装完成，但无法设置执行权限。',
      );
    }

    installedRuntime = metadata;
    await refresh();
    return OperationResult(
      success: true,
      message: '已准备 AList ${metadata.tagName}。',
    );
  }

  Future<void> _persistPreferences() async {
    await _preferences?.setString(_prefsPortKey, portInput.trim());
    await _preferences?.setString(_prefsPasswordKey, adminPassword);
  }

  void _scheduleAutoSave() {
    _autoSaveRequestedRevision += 1;
    autoSavePending = true;
    unawaited(_flushAutoSave());
  }

  Future<void> _flushAutoSave() async {
    if (_autoSaveInProgress) {
      notifyListeners();
      return;
    }

    _autoSaveInProgress = true;
    notifyListeners();

    try {
      while (_autoSaveCompletedRevision != _autoSaveRequestedRevision) {
        final targetRevision = _autoSaveRequestedRevision;
        final port = _parsePort();
        await _persistPreferences();
        if (port != null) {
          await _saveSettingsSilently(port: port);
        }
        _autoSaveCompletedRevision = targetRevision;
      }
    } finally {
      _autoSaveInProgress = false;
      autoSavePending = _autoSaveCompletedRevision != _autoSaveRequestedRevision;
      notifyListeners();
    }
  }

  Future<void> _saveSettingsSilently({required int port}) async {
    await _prepareConfigFile(port: port);
    status = await _nativeApi.getStatus();
    installedRuntime ??= await _readRuntimeMetadata();
  }

  void _handleRuntimeEvent(AListRuntimeEvent event) {
    var shouldNotify = false;

    if (event.status != null) {
      status = event.status!;
      shouldNotify = true;
    }

    if (event.logs.isNotEmpty) {
      logs = _appendLogs(logs, event.logs);
      shouldNotify = true;
    }

    if (shouldNotify) {
      notifyListeners();
    }
  }

  String _appendLogs(String current, String incoming) {
    final normalizedIncoming = _sanitizeLogText(incoming);
    if (normalizedIncoming.isEmpty) {
      return current;
    }

    if (current.isEmpty) {
      return _trimLogs(normalizedIncoming);
    }

    return _trimLogs('$current\n$normalizedIncoming');
  }

  Future<void> _prepareConfigFile({required int port}) async {
    final currentPaths = paths;
    if (currentPaths == null) {
      throw StateError('Native paths are not ready.');
    }

    final configFile = File(currentPaths.configPath);
    if (!await configFile.exists()) {
      final initializeResult = await _nativeApi.initializeDataDirectory();
      if (!initializeResult.success && !await configFile.exists()) {
        await configFile.parent.create(recursive: true);
        await configFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(
            _buildDefaultConfig(currentPaths, port),
          ),
          flush: true,
        );
      }
    }

    Map<String, Object?> configMap;
    try {
      final decoded = jsonDecode(await configFile.readAsString());
      configMap = (decoded is Map<String, Object?>)
          ? decoded
          : _buildDefaultConfig(currentPaths, port);
    } catch (_) {
      configMap = _buildDefaultConfig(currentPaths, port);
    }

    final rawScheme = (configMap['scheme'] as Map?)?.cast<String, Object?>();
    final scheme = <String, Object?>{
      ...?rawScheme,
      'address': (rawScheme?['address'] as String?) ?? '0.0.0.0',
      'http_port': port,
      'https_port': (rawScheme?['https_port'] as num?)?.toInt() ?? -1,
      'force_https': (rawScheme?['force_https'] as bool?) ?? false,
      'cert_file': (rawScheme?['cert_file'] as String?) ?? '',
      'key_file': (rawScheme?['key_file'] as String?) ?? '',
      'unix_file': (rawScheme?['unix_file'] as String?) ?? '',
      'unix_file_perm': (rawScheme?['unix_file_perm'] as String?) ?? '',
      'enable_h2c': (rawScheme?['enable_h2c'] as bool?) ?? false,
    };

    final updated = <String, Object?>{
      ...configMap,
      'scheme': scheme,
    };

    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(updated),
      flush: true,
    );
  }

  Map<String, Object?> _buildDefaultConfig(AListPaths currentPaths, int port) {
    final jwtSecret = _randomSecret(16);
    return <String, Object?>{
      'force': false,
      'site_url': '',
      'cdn': '',
      'jwt_secret': jwtSecret,
      'token_expires_in': 48,
      'database': <String, Object?>{
        'type': 'sqlite3',
        'host': '',
        'port': 0,
        'user': '',
        'password': '',
        'name': '',
        'db_file': p.join(currentPaths.dataDir, 'data.db'),
        'table_prefix': 'x_',
        'ssl_mode': '',
        'dsn': '',
      },
      'meilisearch': <String, Object?>{
        'host': 'http://localhost:7700',
        'api_key': '',
        'index_prefix': '',
      },
      'scheme': <String, Object?>{
        'address': '0.0.0.0',
        'http_port': port,
        'https_port': -1,
        'force_https': false,
        'cert_file': '',
        'key_file': '',
        'unix_file': '',
        'unix_file_perm': '',
        'enable_h2c': false,
      },
      'temp_dir': p.join(currentPaths.dataDir, 'temp'),
      'bleve_dir': p.join(currentPaths.dataDir, 'bleve'),
      'dist_dir': '',
      'log': <String, Object?>{
        'enable': true,
        'name': p.join(currentPaths.dataDir, 'log', 'log.log'),
        'max_size': 50,
        'max_backups': 30,
        'max_age': 28,
        'compress': false,
      },
      'delayed_start': 0,
      'max_connections': 0,
      'max_concurrency': 64,
      'tls_insecure_skip_verify': false,
      'tasks': <String, Object?>{
        'download': <String, Object?>{'workers': 5, 'max_retry': 1},
        'transfer': <String, Object?>{'workers': 5, 'max_retry': 2},
        'upload': <String, Object?>{'workers': 5, 'max_retry': 0},
        'copy': <String, Object?>{'workers': 5, 'max_retry': 2},
        'decompress': <String, Object?>{'workers': 5, 'max_retry': 2},
        'decompress_upload': <String, Object?>{'workers': 5, 'max_retry': 2},
        's3_transition': <String, Object?>{'workers': 5, 'max_retry': 2},
        'allow_retry_canceled': false,
      },
      'cors': <String, Object?>{
        'allow_origins': const <String>['*'],
        'allow_methods': const <String>['*'],
        'allow_headers': const <String>['*'],
      },
      's3': <String, Object?>{
        'enable': false,
        'port': 5246,
        'ssl': false,
      },
      'ftp': <String, Object?>{
        'enable': false,
        'listen': ':5221',
        'find_pasv_port_attempts': 50,
        'active_transfer_port_non_20': false,
        'idle_timeout': 900,
        'connection_timeout': 30,
        'disable_active_mode': false,
        'default_transfer_binary': false,
        'enable_active_conn_ip_check': true,
        'enable_pasv_conn_ip_check': true,
      },
      'sftp': <String, Object?>{
        'enable': false,
        'listen': ':5222',
      },
      'last_launched_version': '',
    };
  }

  Future<RuntimeMetadata?> _readRuntimeMetadata() async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return null;
    }
    final file = File(p.join(currentPaths.runtimeDir, 'runtime.json'));
    if (!await file.exists()) {
      return null;
    }
    return RuntimeMetadata.tryParse(await file.readAsString());
  }

  Future<int?> _readPortFromConfig() async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return null;
    }
    final file = File(currentPaths.configPath);
    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) {
        final scheme = decoded['scheme'];
        if (scheme is Map<String, Object?>) {
          final value = scheme['http_port'];
          if (value is int) {
            return value;
          }
          if (value is num) {
            return value.toInt();
          }
          if (value is String) {
            return int.tryParse(value);
          }
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<String?> _readPasswordFromEnv() async {
    try {
      final envSource = await rootBundle.loadString('.env');
      for (final rawLine in const LineSplitter().convert(envSource)) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }
        final separatorIndex = line.indexOf('=');
        if (separatorIndex <= 0) {
          continue;
        }
        final key = line.substring(0, separatorIndex).trim();
        final value = line.substring(separatorIndex + 1).trim();
        if (key == 'PASSWORD' && value.isNotEmpty) {
          return value;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  int? _parsePort() {
    final value = int.tryParse(portInput.trim());
    if (value == null || value < 1 || value > 65535) {
      return null;
    }
    return value;
  }

  Future<OperationResult> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return const OperationResult(success: true, message: 'Notification permission not needed.');
    }
    return _nativeApi.requestNotificationPermission();
  }

  String _randomSecret(int length) {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List<String>.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }

  String _timestampForFileName() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }

  String _trimLogs(String source) {
    final sanitized = _sanitizeLogText(source);
    if (sanitized.isEmpty) {
      return sanitized;
    }

    final lines = const LineSplitter().convert(sanitized);
    if (lines.length <= maxVisibleLogLines) {
      return sanitized;
    }

    final trimmedLines = lines.sublist(lines.length - maxVisibleLogLines);
    return trimmedLines.join('\n');
  }

  String _sanitizeLogText(String source) {
    return source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(_ansiEscapePattern, '')
        .replaceAll(_controlCharsPattern, '')
        .split('\n')
        .map((line) => line.replaceAll(_logLevelPrefixPattern, '').trim())
        .where(_isImportantLogLine)
        .join('\n')
        .trim();
  }

  static bool _isImportantLogLine(String line) {
    if (line.isEmpty) {
      return false;
    }

    final normalized = line.replaceFirst(_timestampPrefixPattern, '').trim();
    if (normalized.isEmpty) {
      return false;
    }

    for (final pattern in _importantLogPatterns) {
      if (pattern.hasMatch(normalized)) {
        return true;
      }
    }
    return false;
  }
}
