[CmdletBinding()]
param(
    # Flutter 可执行文件。默认从 PATH 取；也可以用 -Flutter 指向具体路径。
    [string]$Flutter = 'flutter',
    # 构建期注入你自己的服务器（不传则 App 启动后要求用户手填地址）。
    #   -RadarServerHost radar.example.com   预填雷达地址
    #   -RadarServerIp   203.0.113.10        允许用户直接粘 IP，自动归一到域名
    #   -RelayServerHost relay.example.com   自建中继
    [string]$RadarServerHost = '',
    [string]$RadarServerIp = '',
    [string]$RelayServerHost = '',
    [string]$OutputDirectory,
    [switch]$CheckOnly,
    [switch]$SkipTests
)
# 打包 arm64 debug APK。
#
# 目录约定（相对本脚本上一级）：
#   code/app              Flutter 应用
#   code/runtime/out      Go 宿主运行时资产（arm64-v8a，打包必需，不入 git）
#   code/tool/test-fonts  金图测试固定字体（不入 git）
#
# 质量闸门（默认全开，任一失败即中断本次打包）：
#   dart analyze        → 有 error/warning 即中断
#   flutter test radar  → 有用例失败即中断（含金图）
# 金图是按像素比对的基线：改主题色、改文案这类全局改动会让整批基线过期。
# 那时先重铺基线，再出包：
#   flutter test --update-goldens test/radar
# 只是想验证能否编译、暂不追平基线时，用 -SkipTests 显式跳过测试。
#   dsh-buddy/artifacts   产物目录
#
# 前提：项目路径必须是纯 ASCII。Gradle 无法把 C: 上的 pub 缓存相对化到中文路径，
# 这也是旧目录（D:\whm\dsh 养鱼调研）必须先 robocopy 到 D:\Android\dsh-build 才编得过的原因。
$ErrorActionPreference = 'Stop'

function Invoke-Native([string]$Command, [string[]]$Arguments, [switch]$AllowNonZeroExit) {
    # Native tools write advisory text to stderr. With 'Stop', PowerShell treats
    # that as a terminating error, so scope these calls to 'Continue' and rely
    # on the process exit code instead.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command @Arguments
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $code = $LASTEXITCODE
    if (-not $AllowNonZeroExit -and $code -ne 0) {
        throw "$Command failed (exit $code): $Arguments"
    }
}

function Invoke-Flutter([string[]]$Arguments) {
    Invoke-Native -Command $Flutter -Arguments $Arguments
}

$repo = Split-Path $PSScriptRoot -Parent
$app = Join-Path $repo 'app'
if ($repo -match '[^\x00-\x7F]') {
    throw "Project path must be ASCII for Gradle: $repo. Move the repository to an ASCII path first."
}
if (Test-Path -LiteralPath $Flutter) {
    $Flutter = (Resolve-Path -LiteralPath $Flutter).Path
} else {
    $command = Get-Command $Flutter -ErrorAction SilentlyContinue
    if (!$command) { throw "Flutter not found: $Flutter (install it or pass -Flutter <path>)" }
    $Flutter = $command.Source
}

$runtime = Join-Path $repo 'runtime/out/arm64-v8a'
$hasRuntime = (Test-Path "$runtime/assets") -and (Test-Path "$runtime/jniLibs")
if (!$hasRuntime) {
    throw 'Runtime assets missing (runtime/out/arm64-v8a). They are git-ignored: build with runtime/build-runtime.sh or copy from a previous checkout.'
}
# 金图测试要真实字体（55 MB，不入库）；缺了会让 flutter test 直接报错。
$fonts = Join-Path $PSScriptRoot 'test-fonts'
if (!$env:DSH_TEST_FONT_DIR -and !(Test-Path -LiteralPath $fonts) -and !$SkipTests) {
    throw "Golden-test fonts missing: $fonts. Copy the font set there, set DSH_TEST_FONT_DIR, or rerun with -SkipTests to build without the test gate."
}
Invoke-Native -Command 'python' -Arguments @((Join-Path $PSScriptRoot 'verify-runtime.py'), $runtime)

function New-BuildInitScript {
    $initDir = Join-Path $env:USERPROFILE '.gradle/init.d'
    New-Item -ItemType Directory -Force $initDir | Out-Null
    $initFile = Join-Path $initDir ("dsh-build-" + [guid]::NewGuid().ToString('N') + '.gradle')
    Copy-Item (Join-Path $PSScriptRoot 'android-mirrors.gradle') $initFile
    return $initFile
}

$initFile = New-BuildInitScript
$previousStorage = $env:FLUTTER_STORAGE_BASE_URL
$previousBuildDir = $env:DSH_ANDROID_BUILD_DIR
$env:DSH_ANDROID_BUILD_DIR = $repo
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
Push-Location $app
try {
    Invoke-Flutter @('pub', 'get')
    # Direct dart analysis avoids Flutter's LSP framing failure on this Windows path.
    $dart = Join-Path (Split-Path $Flutter -Parent) 'cache/dart-sdk/bin/dart.exe'
    if (!(Test-Path -LiteralPath $dart)) { $dart = 'dart' }
    Invoke-Native -Command $dart -Arguments @('analyze')
    $previousFonts = $env:DSH_TEST_FONT_DIR
    try {
        if (!$env:DSH_TEST_FONT_DIR) { $env:DSH_TEST_FONT_DIR = Join-Path $PSScriptRoot 'test-fonts' }
        if ($SkipTests) {
            Write-Warning 'Skipping widget tests (-SkipTests): a stale golden baseline will not block this build.'
        } else {
            Invoke-Flutter @('test', 'test/radar')
        }
    } finally { $env:DSH_TEST_FONT_DIR = $previousFonts }
    if (!$CheckOnly) {
        $defines = @()
        if ($RadarServerHost) { $defines += "--dart-define=RADAR_SERVER_HOST=$RadarServerHost" }
        if ($RadarServerIp) { $defines += "--dart-define=RADAR_SERVER_IP=$RadarServerIp" }
        if ($RelayServerHost) { $defines += "--dart-define=RELAY_SERVER_HOST=$RelayServerHost" }
        Invoke-Flutter (@('build', 'apk', '--debug', '--flavor', 'arm64', '--target-platform', 'android-arm64') + $defines)
        $apk = Join-Path $app 'build/app/outputs/flutter-apk/app-arm64-debug.apk'
        if (!(Test-Path $apk)) { throw "Expected APK missing: $apk" }
        if (!$OutputDirectory) { $OutputDirectory = Join-Path (Split-Path $repo -Parent) 'artifacts' }
        New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
        $target = Join-Path $OutputDirectory "dsh-buddy-$stamp-arm64-debug.apk"
        Copy-Item $apk $target -Force
        Get-Item $target | Select-Object FullName, Length, LastWriteTime
        Get-FileHash $target -Algorithm SHA256
    }
} finally {
    Pop-Location
    $env:FLUTTER_STORAGE_BASE_URL = $previousStorage
    $env:DSH_ANDROID_BUILD_DIR = $previousBuildDir
    # Cleaning up a temporary file must not turn a successful build into a failure.
    try {
        Remove-Item -LiteralPath $initFile -ErrorAction Stop
    } catch {
        Write-Warning "Could not clean up temporary Gradle init script (build result unaffected): $initFile ($($_.Exception.Message))"
    }
}
