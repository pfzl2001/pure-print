# 纯净打印 / Pure Print

一个**独立开发、无广告、无账号、无云端上传**的局域网打印工具。支持 Android 与 Windows 桌面端，用同一套 Dart 代码完成「文件 → 页面光栅化 → 客户端拼版 → IPP 直连打印机」。

本项目基于公开标准自行实现：IPP (RFC 8011)、mDNS (RFC 6763)、AirPrint 光栅打印流程。**不包含任何商业打印应用的代码、dex/so、界面布局、图标、文案、商标、私有 SDK、密钥或服务端接口**，也不隶属于任何打印机厂商。

---

## 下载安装包

二进制安装包**不放在 Git 仓库里**（`dist/` 已 gitignore），统一发布在 [GitHub Releases](https://github.com/pfzl2001/pure-print/releases)：

- **Windows x64**：下载 `pure_print-windows-vX.Y.Z-x64.zip`，解压后直接运行 `pure_print.exe`，无需安装。
- **Android**：下载 `pure_print-vX.Y.Z-arm64.apk`（仅 arm64-v8a），安装时需允许「未知来源」。

每个 Release 附带 `SHA256SUMS.txt`，可用 `sha256sum -c SHA256SUMS.txt` 校验。APK 为本地调试签名，仅供自用/测试；正式发布请自行配置签名密钥。

如需自行构建，见下方「构建」章节。

---

## 主要功能

| 类别 | 能力 |
|---|---|
| 文件 | PDF、JPG/PNG/WebP/BMP/GIF、Word `.docx`、Excel `.xlsx`；多文件按顺序合并为连续排版 |
| 导入 | 文件选择、Android「分享到 / 用其他应用打开」、Windows 整窗拖放（支持拖入文件夹递归展开、格式过滤、去重） |
| 设备 | mDNS 自动发现 `_ipp._tcp`、手动输入 IP/端口、能力探测、设备状态与墨量查询 |
| 打印 | IPP `Print-Job` 直连；份数、彩色/黑白、双面、纸张；系统打印服务兜底；导出排版 PDF |
| 版式 | A4/A3/A5/Letter/4×6/自定义纸张、横竖方向、自定义网格、页边距/格间距 mm、完整显示 / 铺满裁切、内容缩放 %、上下位置 %、每格边框、渲染 DPI |
| 页面选择 | 页码范围（如 `1-3,5`、`2-`）、奇数页 / 偶数页 / 全部、逆序输出（便于手动双面） |
| 预览 | **按需触发**：点击「生成预览」后首张即时显示，其余逐张流式追加；72dpi 缩略图 + 后台 isolate 拼版；可随时取消 |
| 其他 | 默认设置持久化、打印历史（仅本机）、关于与法律声明、完整第三方许可证清单 |

> 预览与打印使用**同一套版式代码**，仅光栅化精度不同：预览 72dpi，打印按设置（默认 200dpi）全分辨率重新渲染全部页面。因此「不预览直接打印」也是完整功能路径。

---

## 预览性能设计

早期实现会在进入设置页时把整份文档按 200dpi 全量解码、在主 isolate 同步拼版，多页 PDF 会造成明显卡顿。当前实现：

1. **按需**：打开页面不渲染任何内容，由用户点击按钮触发，可取消。
2. **低分辨率**：预览 72dpi（A4 约 595×842px），足以覆盖显示区域，像素量约为 200dpi 的 1/7.7。
3. **流式 + 增量**：页引用只持有文档字节与页码；逐页渲染成 JPEG 字节，后台 `Isolate.run` 完成解码/缩放/合成/编码；首张完成即回调给 UI，后续逐张追加。峰值内存与单张纸的页数相关，不再随文档总页数增长。
4. **限量**：预览最多 20 张，超出的部分不生成（打印仍输出全部）。
5. **局部刷新**：预览与日志使用 `ValueNotifier` 局部重建，`Image.memory` 指定 `cacheWidth` 按显示尺寸解码。

实测（24 页 A4，Windows release exe）：

| 指标 | 优化前（全质量全量） | 当前 |
|---|---|---|
| 首张可见 | ~19.4 s | **~0.11 s** |
| 全部预览完成 | ~19.4 s | ~2.2 s（20 张） |
| 预览数据体积 | 7,375 KB（24 张） | 1,417 KB（20 张） |

---

## 构建

### 环境

- Flutter 3.50.x / Dart 3.14.x
- Android：JDK 17、Android SDK Platform 35/36
- Windows：Visual Studio Build Tools 2022、*Desktop development with C++* 工作负载、CMake、Windows SDK
- 国内网络可设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

### Android（仅 arm64）

```bash
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
```

产物：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。
项目刻意不产出 `armeabi-v7a` / `x86_64` 包。注意 Flutter Gradle 插件会覆盖手写的 `defaultConfig.ndk.abiFilters`，请通过构建参数控制 ABI。

### Windows

```bash
flutter pub get
flutter build windows --release
```

产物目录：`build/windows/x64/runner/Release/`（含 `pure_print.exe`、插件 DLL、`data/`）。

两个已知的构建期问题及处理：

- `pdfx` 与 `printing` 插件会在 CMake configure 阶段下载各自版本的 pdfium。离线环境可预下载 tgz 并通过 `PUREPRINT_LOCAL_PDFIUM` / `PUREPRINT_LOCAL_PDFIUM_PRINTING` 指向本地文件（补丁作用于 pub cache 中对应插件的 `windows/CMakeLists.txt`，不属于本仓库）。
- 中文 Windows（代码页 936）下插件源码可能触发 C4819 并被 `/WX` 升级为错误。项目 `windows/CMakeLists.txt` 已添加 `/utf-8 /wd4819`，并固定 `CMAKE_INSTALL_PREFIX` 到构建目录，保证运行包自包含。

### 自检（真实 Windows exe，端到端）

```bash
cd build/windows/x64/runner/Release
PUREPRINT_SELFTEST=1 PUREPRINT_OUT=D:\_pp_out PUREPRINT_HOST=192.168.1.100 pure_print.exe
```

结果写入 `$PUREPRINT_OUT/selftest_result.txt`，末尾为 `SELFTEST_OK`。常用环境变量：

| 变量 | 说明 |
|---|---|
| `PUREPRINT_HOST` / `PUREPRINT_PORT` | 实机打印机地址；**不设置则跳过实机探测**，仓库内不内置任何私有网络地址 |
| `PUREPRINT_SKIP_PRINT=1` | 只探测设备状态，不实际出纸 |
| `PUREPRINT_PRINT_XLSX=1` | 出一张中文 Excel 表头测试页，验证字体渲染 |
| `PUREPRINT_OUT` | 自检输出目录 |

纯 Dart 回归测试：

```bash
dart analyze lib
dart run tool/test_layout.dart        # 版式
dart run tool/test_drop_files.dart    # 拖入整理
dart run tool/test_office_font.dart   # 办公文档中文渲染
```

`tool/generate_notices.py` 可依据 `pubspec.lock` 重新生成 `assets/licenses/THIRD_PARTY_NOTICES.txt`。

---

## 目录结构

```
lib/
  ipp/           IPP/1.1 客户端（RFC 2817 TLS 升级、双层 HTTP 响应解析、Print-Job、状态查询）
  discovery/     mDNS 发现与手动添加
  print/         渲染管线、版式拼版、页码范围、文件类型、拖入整理、系统打印
  office/        docx/xlsx → PDF 简化转换（zip + xml 解析）
  ui/            移动端设置页、Windows 三栏工作台、共享版式控件、关于/历史
  storage/       本地持久化（SharedPreferences）
  share/         Android 分享导入
  dev/           Windows exe 端到端自检
assets/          中文字体、第三方许可声明
```

## 协议适配说明

部分 Epson 机型的嵌入式 IPP 服务要求 RFC 2817 就地 TLS 升级：明文 `OPTIONS *` + `Upgrade: TLS/1.0` → `101 Switching Protocols` → 同一连接 TLS 握手 → IPP POST；响应还包含外层 UPnP 与内层 IPP 两层 HTTP 头。客户端已按实测行为适配，但**不同机型固件差异较大**，不保证兼容所有设备。

`.docx` / `.xlsx` 采用简化解析（文本、表格、段落顺序）生成 PDF，**不追求与 Office/WPS 像素级一致**；复杂版式请先用 Office 导出为 PDF 再打印。

---

## 隐私与权限

- 文件全程在本机处理，打印数据仅发往用户自己填写的局域网打印机 IP，**不经过任何第三方服务器**。
- 无广告 SDK、无统计埋点、无账号体系、无云端上传。
- Android 权限仅 `INTERNET`、`ACCESS_NETWORK_STATE`、`ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE`。
- 默认设置与打印历史保存在本机 `SharedPreferences`。

## 商标与法律声明

- IPP / mDNS / AirPrint 等为公开标准；AirPrint、Epson 及各打印机品牌名称与商标归各自权利人所有。
- 本项目仅实现协议互操作，**不是任何厂商的官方产品**，也未提供官方背书。
- 未使用任何第三方商业打印应用的代码、资源、界面、文案或商标；未绕过任何会员、授权或服务端校验。
- 软件按「现状」提供，不附带适销性或特定用途适用性的担保。公开发布或商用前请自行补充隐私政策、应用商店合规材料并进行正式法律审查。

## 许可证

本项目源代码采用 **Apache License 2.0**，见 [LICENSE](LICENSE)。

第三方依赖（含传递依赖）的许可证全文由 `tool/generate_notices.py` 汇总在 [assets/licenses/THIRD_PARTY_NOTICES.txt](assets/licenses/THIRD_PARTY_NOTICES.txt)，涵盖 MIT、BSD-3-Clause、Apache-2.0、MPL-2.0 等。

随附中文字体 `DroidSansFallbackFull.ttf` 取自 AOSP `platform/frameworks/base` 的 `android-4.4.4_r2` 标签，Apache-2.0，文件字节与上游一致（SHA-256 见许可声明文件）。
