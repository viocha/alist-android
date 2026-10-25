import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'alist_models.dart';

class RuntimeDownloader {
  RuntimeDownloader();

  static const String supportedAbi = 'arm64-v8a';
  static const String supportedAssetName = 'alist-android-arm64.tar.gz';
  static const String bundledAssetPath =
      'assets/runtime/alist-android-arm64.tar.gz';
  static const String bundledVersion = 'v3.66.0';
  static const String bundledSourceUrl =
      'https://github.com/AlistGo/alist/releases/download/v3.66.0/alist-android-arm64.tar.gz';

  Future<RuntimeMetadata> ensureLatestRuntime({
    required AListPaths paths,
    required bool force,
    void Function(String message, double? progress)? onProgress,
  }) async {
    final metadataFile = File(p.join(paths.runtimeDir, 'runtime.json'));
    final binaryFile = File(paths.binaryPath);
    final bundledMetadata = RuntimeMetadata(
      tagName: bundledVersion,
      assetName: supportedAssetName,
      downloadUrl: bundledSourceUrl,
      abi: supportedAbi,
      downloadedAt: DateTime.now(),
    );

    if (!await binaryFile.exists()) {
      throw const FileSystemException('Bundled AList runtime is missing.');
    }

    if (!force && await metadataFile.exists()) {
      final cachedMetadata = RuntimeMetadata.tryParse(
        await metadataFile.readAsString(),
      );
      if (cachedMetadata != null &&
          cachedMetadata.tagName == bundledVersion &&
          cachedMetadata.assetName == supportedAssetName) {
        onProgress?.call('已使用内置运行时 ${cachedMetadata.tagName}', 1);
        return cachedMetadata;
      }
    }

    await metadataFile.parent.create(recursive: true);
    await metadataFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(bundledMetadata.toJson()),
    );
    onProgress?.call('已使用内置运行时 ${bundledMetadata.tagName}', 1);
    return bundledMetadata;
  }
}
