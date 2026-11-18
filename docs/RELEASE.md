# 发布 APK

发布物只有一个 arm64 APK，放在 GitHub Releases。**不要把 APK 提交进仓库**
（单文件约 200 MB，超过 GitHub 的 100 MB 限制）。

## 1. 构建

```bash
# 运行时资产（约 200 MB，不入库）
runtime/build-runtime.sh arm64-v8a

cd app
flutter pub get

# 不要带 RADAR_SERVER_HOST / RELAY_SERVER_HOST：
# 开源版默认不预填任何服务器地址，中继使用官方服务。
flutter build apk --release --flavor arm64 \
  --build-number="$(date +%Y%m%d%H%M)"
```

产物：`app/build/app/outputs/flutter-apk/app-arm64-release.apk`。

> `versionCode` 默认是构建时刻。覆盖安装旧包报 `INSTALL_FAILED_VERSION_DOWNGRADE`
> 时，用 `--build-number` 给一个更大的值。

## 2. 签名

没有 `app/android/key.properties` 时，Gradle 用本机 debug 签名——**能装，但不适合长期分发**：
换一台机器构建就会因为签名不同而无法覆盖安装。

正式发布请自建 keystore：

```bash
keytool -genkey -v -keystore ~/dsh-buddy-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias dsh-buddy
```

在 `app/android/key.properties` 写入（**该文件已被 .gitignore 忽略，不要提交**）：

```properties
storeFile=/absolute/path/to/dsh-buddy-release.jks
storePassword=...
keyAlias=dsh-buddy
keyPassword=...
```

再执行上面的 `flutter build apk`，Gradle 会自动选用 release 签名。
把 keystore 与密码存在密码管理器里：丢了就无法给已安装用户升级。

## 3. 自检

```bash
# 包名、版本、权限
aapt dump badging app/build/app/outputs/flutter-apk/app-arm64-release.apk | head -5

# 干净设备上装一次（先卸载旧版，确认不是靠旧数据活着）
adb uninstall io.github.ccch1mneyyy.personal_assistant
adb install app/build/app/outputs/flutter-apk/app-arm64-release.apk
```

装机后逐项确认：

1. 官方中继下底部只有 **工作 / 自动化 / 资料 / 我的** 四个页签（无雷达）；
2. 「我的 → 连接 → 远程主机」能打开扫码配对，「让电脑常驻」能复制命令；
3. 切到自建服务器后底部出现「信息雷达」，切回官方中继后立即消失；
4. 首次启动能解压运行时并进入工作页。

## 4. 发布

```bash
git tag v1.2.0
git push origin v1.2.0
```

在 GitHub Releases 里以该 tag 新建 release，上传 APK，正文至少写清：

- 版本号与 `versionCode`；
- 安装方式（`adb install -r` 或手机点开）；
- 破坏性变更（例如数据迁移、需要重新配对）；
- **对应源码就是本 tag**（AGPL-3.0 要求）。

## 5. 发布前检查

- 本地构建**没有**注入任何私有地址：`--dart-define` 只应出现在你自己的本地测试里；
- `git status` 干净，没有 `runtime/out/`、`*.db`、`*.jks`、`key.properties`；
- 用 `unzip -l app-arm64-release.apk | grep -i -E "key|secret|\.db"` 粗查一遍资源；
- 在至少一台真机上从「未登录、无数据」的状态走一遍扫码配对；
- 有自建服务器时，再走一遍「自建服务器 → 雷达可见 → 切回官方中继 → 雷达隐藏」。
