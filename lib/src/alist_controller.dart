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
  }) : _nativeApi = nativeApi ?? AListNativeApi(),
       _runtimeDownloader = runtimeDownloader ?? RuntimeDownloader();

  static const String _prefsPortKey = 'preferred_port';
  static const String _prefsPasswordKey = 'preferred_admin_password';
  static const String _prefsLastAppliedPasswordKey =
      'last_applied_admin_password';
  static const String _prefsPasswordInitializedKey =
      'admin_password_initialized';
  static const int _tokenExpiresInHours = 876000;
  static const int maxVisibleLogLines = 300;
  static final RegExp _ansiEscapePattern = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
  static final RegExp _controlCharsPattern = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',
  );
  static final RegExp _logLevelPrefixPattern = RegExp(
    r'^(?:\[(?:stdout|stderr)\]\s+)?(?:INFO|WARN|ERRO|FATA|DEBU|TRAC|PANI)\[[^\]]+\]\s*',
    multiLine: true,
  );

  final AListNativeApi _nativeApi;
  final RuntimeDownloader _runtimeDownloader;

  SharedPreferences? _preferences;
  StreamSubscription<AListRuntimeEvent>? _runtimeEventsSubscription;
  bool _refreshing = false;
  bool _autoSaveInProgress = false;
  int _autoSaveRequestedRevision = 0;
  int _autoSaveCompletedRevision = 0;
  Completer<void>? _serviceTransitionCompleter;
  bool? _pendingRunningState;
  String? _lastSyncedNotificationMessage;

  bool initialized = false;
  bool busy = false;
  bool clearingLogs = false;
  String busyMessage = '';
  double? busyProgress;
  String logs = '';
  bool localAccessUrlsRefreshing = false;
  List<String> localAccessUrls = const <String>[];
  String portInput = '5244';
  String adminPassword = '';
  String lastAppliedAdminPassword = '';
  bool adminPasswordInitialized = false;
  bool passwordVisible = false;
  bool autoSavePending = false;
  RuntimeMetadata? installedRuntime;
  AListPaths? paths;
  AListStatus status = AListStatus.initial();

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    final envPassword = await _readPasswordFromEnv();
    portInput = _preferences?.getString(_prefsPortKey) ?? '5244';
    lastAppliedAdminPassword =
        _preferences?.getString(_prefsLastAppliedPasswordKey) ?? '';
    adminPasswordInitialized =
        (_preferences?.getBool(_prefsPasswordInitializedKey) ?? false) ||
        lastAppliedAdminPassword.trim().isNotEmpty;
    adminPassword =
        _preferences?.getString(_prefsPasswordKey) ??
        (lastAppliedAdminPassword.isNotEmpty
            ? lastAppliedAdminPassword
            : envPassword ?? '');

    paths = await _nativeApi.getPaths();
    installedRuntime = await _runtimeDownloader.ensureLatestRuntime(
      paths: paths!,
      force: false,
    );
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
      if (status.running) {
        await _refreshLocalAccessUrls(showLoading: false, notify: false);
      } else {
        localAccessUrls = const <String>[];
      }
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

        final initialPasswordResult = await _applyInitialPasswordIfNeeded();
        if (!initialPasswordResult.success) {
          return initialPasswordResult;
        }

        final result = await _nativeApi.startService(port: port);
        if (result.success) {
          await _waitForServiceState(true);
          await _refreshLocalAccessUrls(showLoading: false);
        }
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
        if (result.success) {
          await _waitForServiceState(false);
          localAccessUrls = const <String>[];
        }
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
        final files = await FilePicker.pickFiles(
          dialogTitle: '选择要导入的 AList 配置',
          type: FileType.custom,
          allowedExtensions: const <String>['json'],
        );
        if (files.isEmpty) {
          return const OperationResult(
            success: false,
            message: '已取消导入。',
            shouldNotify: false,
          );
        }

        final bytes = await files.single.readAsBytes();

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
        final savedPath = await FilePicker.saveFile(
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

        return OperationResult(success: true, message: '配置文件已导出到 $savedPath');
      },
    );
  }

  Future<OperationResult> clearLogs() async {
    final currentPaths = paths;
    if (currentPaths == null) {
      return const OperationResult(success: false, message: '应用路径尚未就绪。');
    }

    if (clearingLogs) {
      return const OperationResult(
        success: false,
        message: '正在清空日志，请稍候。',
        shouldNotify: false,
      );
    }

    clearingLogs = true;
    notifyListeners();
    try {
      final logFile = File(currentPaths.logPath);
      await logFile.parent.create(recursive: true);
      await logFile.writeAsString('', flush: true);
      logs = '';
      return const OperationResult(
        success: true,
        message: '日志已清空。',
        shouldNotify: false,
      );
    } catch (error) {
      return OperationResult(success: false, message: '$error');
    } finally {
      clearingLogs = false;
      notifyListeners();
    }
  }

  Future<OperationResult> toggleService() {
    if (status.running) {
      return stopService();
    }
    return startService();
  }

  Future<OperationResult> openBatterySettings() async {
    return _nativeApi.openBatterySettings();
  }

  Future<OperationResult> openStoragePermissionSettings() async {
    return _nativeApi.openStoragePermissionSettings();
  }

  Future<OperationResult> refreshLocalAccessUrls() async {
    if (!status.running) {
      localAccessUrls = const <String>[];
      notifyListeners();
      return const OperationResult(
        success: true,
        message: '',
        shouldNotify: false,
      );
    }

    final port = status.port ?? _parsePort();
    if (port == null) {
      return const OperationResult(
        success: false,
        message: '当前端口无效，无法刷新局域网地址。',
      );
    }

    localAccessUrlsRefreshing = true;
    notifyListeners();

    try {
      localAccessUrls = await _resolveLocalAccessUrls(port);
      return const OperationResult(
        success: true,
        message: '',
        shouldNotify: false,
      );
    } catch (error) {
      localAccessUrls = const <String>[];
      return OperationResult(success: false, message: '刷新局域网地址失败：$error');
    } finally {
      localAccessUrlsRefreshing = false;
      notifyListeners();
    }
  }

  Future<OperationResult> openAListInBrowser() async {
    final port = status.port ?? _parsePort();
    if (port == null) {
      return const OperationResult(
        success: false,
        message: '当前端口无效，无法打开 AList。',
      );
    }

    return _nativeApi.openInBrowser('http://localhost:$port');
  }

  Future<OperationResult> applyAdminPassword() async {
    final password = adminPassword.trim();
    if (password.isEmpty) {
      return const OperationResult(
        success: false,
        message: '管理员密码不能为空。',
        shouldNotify: false,
      );
    }
    if (password == lastAppliedAdminPassword.trim()) {
      return const OperationResult(
        success: false,
        message: '管理员密码未发生变化。',
        shouldNotify: false,
      );
    }
    if (status.running) {
      return const OperationResult(success: false, message: '请先停止服务，再修改管理员密码。');
    }

    return _runBusy(
      label: '正在修改管理员密码…',
      action: () async {
        final result = await _nativeApi.applyAdminPassword(password);
        if (!result.success) {
          return result;
        }
        await _markPasswordApplied(password);
        return result;
      },
    );
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

  bool get canApplyAdminPassword {
    final password = adminPassword.trim();
    return !busy &&
        !status.running &&
        password.isNotEmpty &&
        password != lastAppliedAdminPassword.trim();
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
      return const OperationResult(
        success: false,
        message: 'Native paths are not ready.',
      );
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
    final executable = await _nativeApi.ensureBinaryExecutable(
      currentPaths.binaryPath,
    );
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

  Future<OperationResult> _applyInitialPasswordIfNeeded() async {
    final password = adminPassword.trim();
    if (adminPasswordInitialized || password.isEmpty) {
      return const OperationResult(
        success: true,
        message: '',
        shouldNotify: false,
      );
    }

    final result = await _nativeApi.applyAdminPassword(password);
    if (!result.success) {
      return result;
    }
    await _markPasswordApplied(password);
    return result;
  }

  Future<void> _markPasswordApplied(String password) async {
    lastAppliedAdminPassword = password;
    adminPasswordInitialized = true;
    await _preferences?.setString(_prefsLastAppliedPasswordKey, password);
    await _preferences?.setBool(_prefsPasswordInitializedKey, true);
    notifyListeners();
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
      autoSavePending =
          _autoSaveCompletedRevision != _autoSaveRequestedRevision;
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
      final previousRunning = status.running;
      final previousPort = status.port;
      status = event.status!;
      _syncRunningNotificationIfNeeded();
      _resolveServiceTransitionIfNeeded();
      if (!status.running) {
        localAccessUrls = const <String>[];
      } else if (!previousRunning || previousPort != status.port) {
        unawaited(_refreshLocalAccessUrls(showLoading: false));
      }
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

  Future<void> _waitForServiceState(bool running) {
    if (status.running == running) {
      _pendingRunningState = null;
      _serviceTransitionCompleter = null;
      return Future<void>.value();
    }

    _pendingRunningState = running;
    final completer = Completer<void>();
    _serviceTransitionCompleter = completer;
    return completer.future;
  }

  void _resolveServiceTransitionIfNeeded() {
    final expected = _pendingRunningState;
    final completer = _serviceTransitionCompleter;
    if (expected == null || completer == null) {
      return;
    }
    if (status.running != expected) {
      return;
    }

    _pendingRunningState = null;
    _serviceTransitionCompleter = null;
    busy = false;
    busyMessage = '';
    busyProgress = null;
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void _syncRunningNotificationIfNeeded() {
    if (!status.running) {
      _lastSyncedNotificationMessage = null;
      return;
    }

    final port = status.port ?? _parsePort() ?? 5244;
    final message = '服务运行中，端口 $port';
    if (_lastSyncedNotificationMessage == message) {
      return;
    }

    _lastSyncedNotificationMessage = message;
    unawaited(
      _nativeApi.updateServiceNotification(port: port, message: message),
    );
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
          const JsonEncoder.withIndent(
            '  ',
          ).convert(_buildDefaultConfig(currentPaths, port)),
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
      'token_expires_in': _tokenExpiresInHours,
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
      'token_expires_in': _tokenExpiresInHours,
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
      's3': <String, Object?>{'enable': false, 'port': 5246, 'ssl': false},
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
      'sftp': <String, Object?>{'enable': false, 'listen': ':5222'},
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
      return const OperationResult(
        success: true,
        message: 'Notification permission not needed.',
      );
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
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<void> _refreshLocalAccessUrls({
    required bool showLoading,
    bool notify = true,
  }) async {
    if (localAccessUrlsRefreshing) {
      return;
    }

    final port = status.port ?? _parsePort();
    if (port == null || !status.running) {
      localAccessUrls = const <String>[];
      if (notify) {
        notifyListeners();
      }
      return;
    }

    localAccessUrlsRefreshing = true;
    if (notify) {
      notifyListeners();
    }

    try {
      localAccessUrls = await _resolveLocalAccessUrls(port);
    } catch (_) {
      localAccessUrls = const <String>[];
    } finally {
      localAccessUrlsRefreshing = false;
      if (notify || showLoading) {
        notifyListeners();
      }
    }
  }

  bool _isPrivateIpv4(String host) {
    final octets = host.split('.').map(int.tryParse).toList(growable: false);
    if (octets.length != 4 || octets.any((value) => value == null)) {
      return false;
    }

    final a = octets[0]!;
    final b = octets[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  int _compareIpv4Addresses(String left, String right) {
    final rankDiff = _ipv4SortRank(left) - _ipv4SortRank(right);
    if (rankDiff != 0) {
      return rankDiff;
    }

    final leftOctets = left.split('.').map(int.parse).toList(growable: false);
    final rightOctets = right.split('.').map(int.parse).toList(growable: false);
    for (var index = 0; index < 4; index += 1) {
      final diff = leftOctets[index] - rightOctets[index];
      if (diff != 0) {
        return diff;
      }
    }
    return 0;
  }

  int _ipv4SortRank(String host) {
    if (host.startsWith('192.168.')) {
      return 0;
    }
    if (host.startsWith('172.')) {
      return 1;
    }
    if (host.startsWith('10.')) {
      return 2;
    }
    return 3;
  }

  Future<List<String>> _resolveLocalAccessUrls(int port) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final privateHosts = <String>{};
    final fallbackHosts = <String>{};

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final host = address.address;
        if (_isPrivateIpv4(host)) {
          privateHosts.add(host);
        } else {
          fallbackHosts.add(host);
        }
      }
    }

    final selectedHosts = privateHosts.isNotEmpty
        ? privateHosts
        : fallbackHosts;
    final sortedHosts = selectedHosts.toList(growable: false)
      ..sort(_compareIpv4Addresses);
    return sortedHosts
        .map((host) => 'http://$host:$port')
        .toList(growable: false);
  }
}
