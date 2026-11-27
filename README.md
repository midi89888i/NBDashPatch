# NBDashPatch — 原版 NinebotDash 注入补丁

向**原版 NinebotDash v1.3.1**（保留全部 6 套主题）注入动态库，新增两个能力：

## 功能

### 1. 蚂蚁 ANT BMS（原只有小哈）
- 后台静默连接蚂蚁保护板（FFE0/FFE1，严格只读）
- 电量数据通过原 App 自己的 `HBB...SOC` 蓝牙管道注入——**六套主题原生显示 ANT 电量**，与原版渲染路径完全一致，无任何外加界面
- 开启方式：在原 App「电量设置」里打开小哈扫描即可（ANT 数据就是走这条管道上屏的）

### 2. 免九号出行投屏（carwithin 连接逻辑）
- 在原 App 主页面底部内嵌原生卡片（不是悬浮窗，随页面滚动）：扫描车辆 → 点选 → 等震动提示 → 按车上 P 键，**配对一次永久有效**
- 配对后：App 在前台时自动维持 BLE 认证 + 0x71 导航唤醒——仪表通电即进入投屏模式，你直接点原 App「启动仪表投屏」即可，**永远不用再开九号出行**
- 配对密钥存本机钥匙串；「重配（P键）」可应对九号出行顶号

## 构建

GitHub Actions「Build injected NinebotDash IPA」自动完成：下载原版 IPA → 编译补丁 dylib → Mach-O 注入 `LC_LOAD_DYLIB` → 打包 `NinebotDash-1.3.1-ANT-injected.ipa`。产物未签名，TrollStore / Sideloadly / AltStore / 爱思助手签名安装。

## 原理

- 原版二进制未加密无签名，load commands 后有 8KB 空闲，注入 `LC_LOAD_DYLIB` 指向 `@executable_path/NBDashPatch.dylib`
- dylib `+load` 启动：ANT BMS 客户端（carwithin 移植）、车辆连接管理（carwithin V2 加密握手原样移植）、方法注入器
- 电量注入：swizzle 宿主 `CoreBluetoothTransport` 的 `centralManager:didDiscover:advertisementData:rssi:`，ANT 电量以伪造小哈广播形式进入原管道
- 投屏自动化：`NBAutoProjection` 维持 0x71 导航会话

## 许可

车辆连接/加密与 ANT 协议移植自 [carwithin](https://github.com/ZaNgVVB/carwithin)（AGPL-3.0-only；ANT 帧解析源自 maibms MIT）。本补丁按 AGPL-3.0-only 分发。仅供个人研究学习，请支持原开发者。
