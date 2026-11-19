# 私人导航 NavApp — iOS 版（全能签可用）

把你的单文件网页《第一人称实景导航》（`web/index.html`）原封不动打包成 iOS App：**WKWebView 壳 + 原生定位/罗盘桥**。页面代码零改动，功能与浏览器版完全一致，并额外获得比浏览器更稳的定位与罗盘。

## 它是怎么工作的

```
NavApp.app
└── WKWebView（全屏，加载打包的 web/index.html）
      ├── navigator.geolocation   → 被注入脚本替换 → CoreLocation（原生 GPS）
      ├── deviceorientation 事件   → 被注入脚本伪造  → CLLocationManager.heading（原生磁力计）
      └── 高德 JS API / 路线规划 / 3D 楼块 → 与浏览器完全一致（https 加载，无改动）
```

- **定位**：WKWebView 自带的 Web 定位在弱网下经常直接超时，这里改用原生 CoreLocation
  （`kCLLocationAccuracyBestForNavigation`），页面里所有 `getCurrentPosition / watchPosition`
  调用都桥接到原生，回调格式与 W3C 规范一致，页面代码无感知。
- **罗盘**：原生磁力计优先输出**真北**航向（不可用时磁北），以 `webkitCompassHeading`
  字段派发合成事件——正好命中页面中"iOS 分支"的取值逻辑，所以车头向上、转向跟随都能用。
- **安全区**：已注入 `viewport-fit=cover` 与安全区 CSS，刘海屏/底部小白条不会遮挡搜索框和面板。
- **权限**：Info.plist 已声明 `NSLocationWhenInUseUsageDescription`，首次启动会弹系统授权框。

## 项目结构

```
NavApp/
├── NavApp.xcodeproj/        ← Xcode 工程（含共享 scheme）
├── NavApp/
│   ├── NavApp.swift         ← 入口
│   ├── ContentView.swift    ← 全屏容器
│   ├── WebView.swift        ← WKWebView + 注入脚本（geo 桥的核心）
│   ├── LocationBridge.swift ← CoreLocation 采集与回灌
│   ├── web/index.html       ← 你的网页（除安全区 CSS 外零改动）
│   ├── Info.plist           ← 定位权限声明
│   └── Assets.xcassets/     ← 图标（已生成）与主题色
├── build_ipa.sh             ← 一键产出未签名 IPA
├── .github/workflows/       ← 云端编译（GitHub Actions，无需 Mac）
└── README.md
```

## 出未签名 IPA（与 probe 仓库同一套流程）

### 方式 A：云端编译（无需 Mac）

1. 把 `NavApp` 文件夹内容建成 GitHub 仓库（Public，免费不限时长）
2. 推送后自动构建，或 Actions → `build-unsigned-ipa` → **Run workflow**
3. 运行页底部 **Artifacts** 下载 `NavApp-unsigned-ipa` → 解压得 `NavApp-unsigned.ipa`

### 方式 B：本地 Mac

```bash
cd NavApp
chmod +x build_ipa.sh
./build_ipa.sh        # 产物 build/NavApp-unsigned.ipa
```

### 方式 C：不用 GitHub（网络不通时）

如果 github.com 打不开（和 probe 遇到的一样），可以直接用 API 脚本上传本仓库：

```powershell
$env:GITHUB_TOKEN = "ghp_你的token"    # classic token，勾 repo + workflow
python (probe 仓库里的) tools\push_via_api.py   # 把 --repo 改成新仓库
```

## 全能签签名

和之前的 probe 完全一样：拖入 IPA → 选证书（个人证书需 UDID）→ 签名 → 安装 →
**设置 → 通用 → VPN 与设备管理** 信任证书。

> 首次打开 App 会弹「允许"私人导航"使用你的位置」——**必须点允许**，否则地图能看但定位/导航不可用。

## 排错速查

| 现象 | 原因与处理 |
|---|---|
| 地图能看，点📍没反应 | 定位权限被拒：设置 → 隐私 → 定位服务 → 私人导航 → 使用 App 期间 |
| 高德提示 INVALID_USER_SCODE | securityJsCode 与 key 不匹配；核对 `web/index.html` 顶部两处密钥 |
| 车头方向反了 | 页面里 `MARKER_ROTATES_WITH_MAP` 开关改成 `false` |
| 罗盘不动 | 真机才有磁力计（模拟器没有）；远离磁铁/车内支架磁吸盘 |
| 3D 楼块看不到 | 楼块只在 zoom≥16 出现，双指捏合放大即可 |
| 全能签提示签名冲突 | 用 `build_ipa.sh` 新产出的 IPA（本工程产出即为无签名包） |
| App 打开白屏 | 极少见：web/index.html 未随包编译，重跑 `build_ipa.sh`（脚本已内置校验） |

## 打开就闪退怎么查

**先抓崩溃日志**（30 秒，比猜快得多）：

设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 在列表里找 `NavApp-2026-11-19-xxxxxx.ips`
（列表按时间倒序，装完 App 点开就崩的那条在最上面）→ 点开 → 把最开头一段
（`incident`、`exception`、`termination` 那几行）截图或复制发我。

按日志里的关键字对症：

| 日志关键字 | 含义 | 处理 |
|---|---|---|
| `NSUnknownKeyException` / `not key value coding-compliant` | 代码用了私有 KVC 属性 | 已在本版移除（`WebView.swift` 里的 `allowFileAccessFromFileURLs`） |
| `dyld: Library not loaded` / `code signature invalid` | 签名环节坏了 | 换证书重签；确认用的是 `build_ipa.sh` 产出的**未签名**包 |
| `terminated due to uncaught exception` + `scene` | 场景清单缺失 | 已补 `UIApplicationSceneManifest` |
| 装完点图标完全没反应、无日志 | 描述文件不含这台设备的 UDID | 全能签里「添加 UDID」后重签 |
| 启动后白屏不闪退 | `web/index.html` 没进包 | 重跑 `build_ipa.sh`（脚本有校验，缺文件会直接报错） |

## 想改页面？

直接改 `NavApp/web/index.html`，重新构建即可——页面就是一个普通网页，
未来你在浏览器里迭代的新版本，直接覆盖这个文件就能升级 App。
