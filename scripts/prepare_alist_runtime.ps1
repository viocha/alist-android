$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$projectDir = Split-Path -Parent $PSScriptRoot
$metadataPath = Join-Path $projectDir 'lib/src/runtime_downloader.dart'
$metadataSource = Get-Content -LiteralPath $metadataPath -Raw

function Read-RuntimeConstant([string]$Name) {
    $match = [regex]::Match($metadataSource, "static const String $Name\s*=\s*'([^']+)';")
    if (-not $match.Success) {
        throw "无法读取运行时常量：$Name"
    }
    return $match.Groups[1].Value
}

$version = Read-RuntimeConstant 'bundledVersion'
$assetName = Read-RuntimeConstant 'supportedAssetName'
$downloadUrl = Read-RuntimeConstant 'bundledSourceUrl'
$expectedSha256 = Read-RuntimeConstant 'bundledArchiveSha256'
if ($expectedSha256 -notmatch '^[0-9a-f]{64}$') {
    throw '运行时 SHA-256 格式无效。'
}

$runtimeDir = Join-Path $projectDir 'build/runtime'
$archivePath = Join-Path $runtimeDir $assetName
$curlPath = Join-Path $env:SystemRoot 'System32/curl.exe'
if (Test-Path -LiteralPath $archivePath) {
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -eq $expectedSha256) {
        Write-Output "AList $version 缓存校验通过。"
        return
    }
}

New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$downloadPath = Join-Path $runtimeDir ([guid]::NewGuid().ToString() + '.download')
try {
    Write-Output "正在下载 AList $version…"
    & $curlPath --fail --location --silent --show-error --retry 3 --retry-all-errors --connect-timeout 30 --max-time 300 --output $downloadPath $downloadUrl
    if ($LASTEXITCODE -ne 0) {
        throw "运行时下载失败，curl 退出码：$LASTEXITCODE"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    if ($actualSha256 -ne $expectedSha256) {
        throw "运行时 SHA-256 校验失败：$actualSha256"
    }
    Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
    Write-Output "AList $version 已下载并通过校验。"
} finally {
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }
}
