# v0.8.97 UI 与平台迁移

上游基准：`db0388057962e83958dd355bc41fc22bfa1e901a`

## 已落地：SSID、热键、托盘

- 引入上游 `wifi_ssid` 四平台插件，补充当前 Android Kotlin 插件配置与 macOS CocoaPods 兼容
- 排除列表随网络配置保存，提供定位授权入口；冷启动查询、恢复前台查询、10 秒同传输类型漫游刷新，丢弃过期异步结果；未配置时不读取 SSID
- 桌面监听器操作串行执行，网络恢复不会越过用户停止；暂停时恢复系统代理所有权并让应用 HTTP 请求直连
- Android 原生 RemoteService 独立监控 Wi-Fi，排除列表传入持久化小部件参数；不依赖 Flutter Activity。排除时释放 TUN 并关闭代理监听，恢复时先恢复监听，再建立 TUN。Go 内核单独保留网络排除和用户运行意图，配置重载不能越过排除策略
- 引入 Rust 热键，保留原有按键与修饰键配置、应用动作及关闭窗口行为；注册、解绑串行，平台事件线程沿用上游处理
- 引入新托盘，保留 oixCloud 菜单动作、环境变量复制及系统代理所有权处理，平台图标和菜单事件按 capability 分发
- 新插件测试纳入 CI；中文与日文本地化末尾移除中文句号，保留句中句号

验证：

- Dart analyze `lib test`：无问题
- Flutter 根包与 proxy、wifi_ssid、tray 插件：1345 项通过，6 项环境跳过；设置 `FLCLASH_TEST_SCRIPT_LIB` 与 `FLCLASH_TEST_CORE` 使用实际 Rust FFI 与 Go 测试构建
- Rust API：39 项通过
- Go 包装层 `CGO_ENABLED=0 go test -tags with_gvisor ./...`：通过，新增真实监听端口的网络排除/重载/手动停止回归
- Android `:app:compileDebugKotlin :app:testDebugUnitTest :service:testDebugUnitTest`：通过
- macOS Debug 整包构建：通过；补齐 Rust Carbon 框架链接和 SwiftPM 插件切换后的 FlutterMacOS 显式链接
- 尚未执行 Android 9/13 实机 Wi-Fi 切换、小部件和权限交互，也未执行 Windows/Linux 桌面托盘/热键交互，以上编译与测试不等于这些设备行为已验证

## 已落地：Linux Helper

- Unix socket 以安装用户 UID 校验连接，Core 地址必须属于该用户，沿用协议 6、Core SHA256 校验和会话启动/停止语义
- systemd 服务从 root 管理的固定目录启动匹配的 Helper/Core，避免 AppImage 临时挂载失效；服务和二进制升级失败恢复旧版本，包括 Core SHA 不变的 Helper 升级
- 安装拒绝覆盖其他用户的服务，取消提权直接结束；非 systemd 或未打包 Helper 时保留现有启动路径
- deb/rpm 安装在 systemd 下移除旧 Core setuid，已有服务按原用户升级；包升级不误卸载服务，最终卸载清理服务与安装副本；非 systemd 保留旧 setuid 路径
- setup.dart 生成 Linux Core manifest 并编译打包 Helper，Windows SHA/会话保护保持原实现

验证：Linux Helper 29 项 Rust 测试、macOS 上共享 Helper 22 项测试、Dart Helper 32 项测试、deb/rpm 脚本 2 项测试通过，Dart 定向分析无问题

安装回归使用离线、去除 capabilities 的一次性 Linux 容器，systemctl 为记录调用/注入失败的替身；覆盖固定目录副本、同 Core 回滚、用户隔离和 AppImage 删除后卸载，脚本位于 services/helper/tests/linux_installation.sh
尚未验证真实 systemd 管理器、桌面 polkit 提权窗口和实际 deb/rpm 包管理器安装事务

## 已落地：Material UI、动作层与数据库

- 全部页面与公共控件接入 `material_ui 1.0.1` / `material_new_shapes 1.0.0`，包含 oixCloud 账户、商店、已购套餐和自定义覆写页；适配新卡片、形状、加载和空状态，保留 Android 动态取色、主题设置及 TV 方向键焦点
- 窄屏与软键盘同时出现时，成员选择器的搜索和列表整体滚动；卡片进入操作区和仪表盘模式切换保留遥控器可达性；关闭动画时加载／空状态遵守设置
- 动作层分为 Update、AppState、Profile、Logs、Proxies、Setup、Core、System、Backup、BackBlock、Store、Common 共 12 个 Riverpod action，页面从自身 ProviderScope 获取动作；异步流程先捕获动作，dispose 不读取失效 context
- 原 AppController 成为兼容入口，生命周期、恢复事务和保存队列仍由同一个实例拥有；避免按 action 重新创建 Core 所有者
- 本地数据库从 schema 3 升至 4，增加规范化代理组、图标历史、结构化规则、规则来源 ID 及配置 MATCH 目标；规则原始文本和旧配置 JSON 快照同时保留，兼容旧备份、未知规则动作及 oixCloud 自定义字段
- 配置快照与规范化组／规则在同一事务保存；仅更新节点选择不重建组 ID；相同自定义规则 ID 在不同配置间保持隔离，不覆盖全局规则
- 显式 MATCH 目标接入覆写编辑、生成和节点重命名／删除；未设置时继续从订阅末尾 MATCH 推断
- 图标历史最多保留 1000 条，图标解码缓存最多 64 个；异步图标加载具有版本校验，修改图标后旧请求不能覆盖新结果

## 已落地：窗口与原生构建 hooks

- 窗口切换改用串行可见性控制器，合并快速连续切换；macOS Dock 切换留出系统稳定时间，窗口关闭沿用本地退出／最小化动作
- 接入上游 `window_manager v0.5.1-flclash.3` 和新标题栏，移除 `window_ext`；窗口尺寸、坐标保存避开最大化／全屏／最小化状态，Wayland 不写入不支持的绝对坐标
- macOS terminate/reopen 回调、Linux GApplication 激活令牌和 AppImage URL desktop entry 已接入，保留旧实例唤醒、身份／安全存储迁移及 Windows taskbar 防崩溃补丁
- `plugins/setup` 通过 Dart hooks 自动编译 Go Core 和 Linux/Windows Helper，`rust_api` 使用 Flutter Rust Bridge 2.13.0 Native Assets；删除旧 Cargokit 和平台 FFI 壳层
- 保留 `dart setup.dart <platform> --arch ... [--out core]`、flutter_distributor、混淆参数注入、Core SHA256 manifest 和 Windows Helper 会话校验
- Flutter 需要 3.44+、Dart 3.12+；Rust API 固定 Rust 1.95.0，并显式选择 rustup 对应的 rustc，避免 Homebrew 编译器误用缺少 Android 标准库的 sysroot
- hooks 固定在 `>=2.0.2 <2.1.0`，与 Flutter 3.44 的 meta 约束匹配；Android bindgen 使用当前 NDK 的 libclang，Go/Gradle 共用 minSdk；macOS Rust 保持最低系统 11.0
- Core 构建参数和源码纳入缓存，修复 Go 规范路径与符号链接工作区路径不同导致新增源文件漏检；仅登记源码目录，避开 Flutter 3.44 对 framework 符号链接的目录遍历限制
- Core、Helper、manifest 和 Android JNI／头文件安装具有锁与回滚；Helper 构建失败恢复原配套产物；回滚自身失败保留备份并释放锁，后续重试不会死锁
- Android 原生消费者排在 Flutter hooks 之后；Linux 在安装阶段收集 Helper/manifest；macOS 在 Flutter assemble 后暂存并检查 Core 架构，再签名复制到应用

## 构建与测试入口

完整包继续使用 setup.dart，密钥从调用进程的环境读取；首次构建必须提供 DNS_AUTH_PRIVATE_KEY 和 DNS_AUTH_DOMAINS，发布包还需要原有 Dart 编译参数对应的环境变量
后续 `flutter run/build` 自动更新 Core，不再要求修改 Go 文件后手动重编译；更换 DNS 构建参数时先用新环境执行 setup.dart，更新 hooks 缓存依赖

`.dart_tool/setup_core_secrets.json` 仅保存与 Core 相同的 v2 混淆值及变更摘要，Unix 权限 0600，属于忽略的构建设置，不能提交；构建日志对密钥和混淆值脱敏
hooks 没有自动读取 `.env.local`，也不会在缺少已准备参数时静默覆盖成无密钥 Core

单元测试可使用 `dart tool/set_native_build_assets.dart false` 关闭 hooks，并通过 `FLCLASH_TEST_SCRIPT_LIB` / `FLCLASH_TEST_CORE` 指定独立测试产物；运行／打包前执行 `dart tool/set_native_build_assets.dart true` 恢复两项开关，setup.dart 会拒绝关闭开关的整包构建
CI 已切换到 Native Assets Android 三 ABI 编译和 hooks 分析／测试，独立 Rust、Go、Windows Helper 门禁继续保留

## 最终验收与边界

以下使用临时数据库、回环监听器和公开占位构建参数；没有读取真实账户、订阅或 `.env.local`，构建后恢复原有 Core／JNI 产物及已准备设置

| 验证 | 结果 |
| --- | --- |
| Dart 分析：整个根包，以及定向 lib、test、setup.dart、tool、两个 hook 入口 | 无问题 |
| setup_hooks Dart 分析与测试 | 无问题，52 项通过，含真实 Go 编译／缓存失效和失败回滚 |
| Rust API 2.13.0 | 39 项通过，格式检查通过 |
| Linux Helper／共享 Helper | Linux 29 项、macOS 共享 22 项通过 |
| Linux 安装夹具 | 离线容器通过固定目录安装、同 Core SHA 回滚、用户隔离、AppImage 删除后卸载 |
| Android Native Assets | arm64-v8a、armeabi-v7a、x86_64 三 ABI 编译通过 |
| Android Kotlin／服务单元测试 | 通过 |
| Android 完整 Debug APK | 三 ABI 整包构建通过，包含 Go CGO／JNI／Rust Native Assets |
| macOS Debug 应用 | 删除预编译 Core 后整包构建通过，Rust Native Assets framework 正确打入应用 |

Flutter 根包及 proxy、wifi_ssid、tray 插件最终全量回归：1437 项通过，6 项环境跳过；直接加载 macOS 应用包内的 Rust framework，并使用独立 Go Core 测试构建，覆盖实际 FFI、数据库迁移、动作作用域、窗口串行动作、TV 焦点和 Windows taskbar C++ 夹具

仍需设备验收：Android 9/13 小部件视觉闪烁、真实 SSID／权限切换，Windows/Linux 桌面托盘、热键和窗口交互，真实 systemd／polkit 及 deb/rpm 包管理事务
本机 Flutter 3.44.7 的 `flutter analyze` 在中文工作区路径下，LSP 发送端以字符串长度而非 UTF-8 字节数写入 Content-Length，导致分析服务解析报文失败；使用 `dart analyze` 完成同一仓库的全量分析，CI 同步使用该入口，没有修改 Flutter SDK

这些属于设备和发布验收，不是尚未接入的代码组；Debug 构建使用公开占位参数，不能作为正式客户端分发
本次仅作本地提交，没有推送、发布、修改版本号或标签
