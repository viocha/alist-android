import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'alist_controller.dart';
import 'alist_models.dart';
import 'runtime_downloader.dart';
class AListApp extends StatefulWidget {
  const AListApp({super.key});

  @override
  State<AListApp> createState() => _AListAppState();
}

class _AListAppState extends State<AListApp> {
  late final AListController _controller;
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final TextEditingController _portTextController = TextEditingController();
  final TextEditingController _passwordTextController = TextEditingController();
  final FocusNode _portFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final ScrollController _logScrollController = ScrollController();
  String _lastObservedLogs = '';

  @override
  void initState() {
    super.initState();
    _controller = AListController()..addListener(_syncTextControllers);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_syncTextControllers)
      ..dispose();
    _portTextController.dispose();
    _passwordTextController.dispose();
    _portFocusNode.dispose();
    _passwordFocusNode.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _syncTextControllers() {
    if (!_portFocusNode.hasFocus &&
        _portTextController.text != _controller.portInput) {
      _portTextController.value = _portTextController.value.copyWith(
        text: _controller.portInput,
        selection: TextSelection.collapsed(offset: _controller.portInput.length),
      );
    }

    if (!_passwordFocusNode.hasFocus &&
        _passwordTextController.text != _controller.adminPassword) {
      _passwordTextController.value = _passwordTextController.value.copyWith(
        text: _controller.adminPassword,
        selection: TextSelection.collapsed(
          offset: _controller.adminPassword.length,
        ),
      );
    }

    if (_lastObservedLogs != _controller.logs) {
      _lastObservedLogs = _controller.logs;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_logScrollController.hasClients) {
          return;
        }
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      });
    }
  }

  Future<void> _runAction(Future<OperationResult> Function() action) async {
    final result = await action();
    if (!mounted || !result.shouldNotify) {
      return;
    }

    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) {
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor:
              result.success ? const Color(0xFF165D49) : const Color(0xFFB42318),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AList',
      scaffoldMessengerKey: _scaffoldMessengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8F7F2),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF8F7F2),
          foregroundColor: Color(0xFF182230),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: const BorderSide(color: Color(0xFFE7E5DE)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFFFCF7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD5D2C8)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFD5D2C8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.5),
          ),
        ),
      ),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return _AListHomePage(
            controller: _controller,
            portController: _portTextController,
            passwordController: _passwordTextController,
            portFocusNode: _portFocusNode,
            passwordFocusNode: _passwordFocusNode,
            logScrollController: _logScrollController,
            onAction: _runAction,
          );
        },
      ),
    );
  }
}

class _AListHomePage extends StatelessWidget {
  const _AListHomePage({
    required this.controller,
    required this.portController,
    required this.passwordController,
    required this.portFocusNode,
    required this.passwordFocusNode,
    required this.logScrollController,
    required this.onAction,
  });

  final AListController controller;
  final TextEditingController portController;
  final TextEditingController passwordController;
  final FocusNode portFocusNode;
  final FocusNode passwordFocusNode;
  final ScrollController logScrollController;
  final Future<void> Function(Future<OperationResult> Function() action) onAction;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final runtime = controller.installedRuntime;
    final busy = controller.busy;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AList',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<_MenuAction>(
            tooltip: '更多操作',
            position: PopupMenuPosition.under,
            onSelected: (action) {
              switch (action) {
                case _MenuAction.batterySettings:
                  onAction(controller.openBatterySettings);
                  break;
                case _MenuAction.importConfig:
                  onAction(controller.importConfig);
                  break;
                case _MenuAction.exportConfig:
                  onAction(controller.exportConfig);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _MenuAction.batterySettings,
                child: Text('电池策略'),
              ),
              PopupMenuItem(
                value: _MenuAction.importConfig,
                child: Text('导入配置'),
              ),
              PopupMenuItem(
                value: _MenuAction.exportConfig,
                child: Text('导出配置'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: controller.initialized
          ? SafeArea(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                  children: [
                    _StatusHero(
                      running: status.running,
                      message: status.lastMessage,
                      versionLabel:
                          runtime?.tagName ?? RuntimeDownloader.bundledVersion,
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '服务控制',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 18),
                            TextField(
                              controller: portController,
                              focusNode: portFocusNode,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              enabled: !busy,
                              decoration: const InputDecoration(
                                labelText: '端口',
                              ),
                              onTapOutside: (_) =>
                                  FocusManager.instance.primaryFocus?.unfocus(),
                              onChanged: controller.setPortInput,
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: passwordController,
                              focusNode: passwordFocusNode,
                              obscureText: !controller.passwordVisible,
                              enabled: !busy,
                              decoration: InputDecoration(
                                labelText: '管理员密码',
                                suffixIcon: IconButton(
                                  onPressed: busy
                                      ? null
                                      : controller.togglePasswordVisibility,
                                  icon: Icon(
                                    controller.passwordVisible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              onTapOutside: (_) =>
                                  FocusManager.instance.primaryFocus?.unfocus(),
                              onChanged: controller.setAdminPassword,
                            ),
                            const SizedBox(height: 18),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                OutlinedButton(
                                  onPressed: controller.canApplyAdminPassword
                                      ? () => onAction(controller.applyAdminPassword)
                                      : null,
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 12,
                                    ),
                                  ),
                                  child: const Text('修改密码'),
                                ),
                                const SizedBox(width: 12),
                                status.running
                                    ? OutlinedButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => onAction(controller.toggleService),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 12,
                                          ),
                                        ),
                                        icon: const Icon(Icons.stop_circle_outlined),
                                        label: const Text('停止服务'),
                                      )
                                    : FilledButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => onAction(controller.toggleService),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 12,
                                          ),
                                        ),
                                        icon: const Icon(Icons.play_arrow_rounded),
                                        label: const Text('启动服务'),
                                      ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '日志面板',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => onAction(controller.clearLogs),
                                  icon: const Icon(Icons.cleaning_services_outlined),
                                  label: const Text('清空'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Container(
                              height: 280,
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFAFAF7),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: const Color(0xFFE6E4DB)),
                              ),
                              child: SingleChildScrollView(
                                controller: logScrollController,
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: SelectableText(
                                  controller.logs.isEmpty ? '暂无日志。' : controller.logs,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        fontFamily: 'monospace',
                                        height: 1.4,
                                        color: const Color(0xFF182230),
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.running,
    required this.message,
    required this.versionLabel,
  });

  final bool running;
  final String message;
  final String versionLabel;

  @override
  Widget build(BuildContext context) {
    final background = running
        ? const LinearGradient(
            colors: [Color(0xFF0F766E), Color(0xFF14B8A6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFFF5E3C2), Color(0xFFFFF5E8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    final foreground = running ? Colors.white : const Color(0xFF182230);
    final secondary = running ? Colors.white70 : const Color(0xFF475467);

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: background,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: running ? const Color(0xFF86EFAC) : const Color(0xFFF79009),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                running ? '服务运行中' : '服务未启动',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: secondary,
                ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _TagChip(label: 'AList $versionLabel', foreground: foreground),
            ],
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.foreground,
  });

  final String label;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

enum _MenuAction {
  batterySettings,
  importConfig,
  exportConfig,
}
