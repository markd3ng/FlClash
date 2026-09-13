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

## 继续范围

1. Linux 实际设备交互与包管理器验收
2. provider action 与 profile/icon/数据库迁移：本地和上游均为 schema 3 但结构不同，须使用新的本地 schema 版本，保留 oixCloud 自定义组、规则和代理链
3. material_ui 全页面与 oixCloud 独有页面、TV 焦点适配
4. 窗口组件和 build hooks 迁移，保留密钥混淆、Windows Helper SHA256/会话校验及本地构建入口
