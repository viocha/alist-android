# alist_android

## 构建 Android APK

安装 Flutter、Android SDK、Node.js 和 Task，安装图标生成脚本所需的项目依赖后执行：

```powershell
task build:android
```

任务会从官方发布地址下载固定版本的 AList Android ARM64 运行时，校验 SHA-256 后缓存到 `build/runtime/`。缓存校验通过时直接使用，构建产物和运行时压缩包均由 Git 忽略。

运行时版本、下载地址和 SHA-256 定义在 `lib/src/runtime_downloader.dart`；升级时同步修改这三项。APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`。

在已连接的设备上调试并启用热重载，执行 `task debug:android`，该任务也会准备运行时。

## 常驻服务通知

AList 服务运行时显示访问地址和停止操作，通知被划走后静默恢复。应用回到前台时检查服务运行状态和系统通知列表，只补回正在运行服务的缺失通知。停止服务后移除通知，迟到的通知更新或恢复请求不会启动服务或重新显示通知。

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
