# FlClash for oixCloud：v0.8.97 移植汇总

## 结论与固定基线

本记录汇总前 26 批选择性移植及本次核心完整合并。应用侧保留 oixCloud
账户、商店、配置加密、主题和 TV 界面；核心合并至上游 v0.8.97 所引用的
mihomo 提交，并保留已验证的本地修复。应用整体没有改成上游新版界面，
`pubspec.yaml` 仍为 `0.8.96+2026081901`。

- 上游应用 v0.8.96：`e2f678909dd9738015a5c032a8e25288ed79d4f1`。
- 上游应用 v0.8.97：`db0388057962e83958dd355bc41fc22bfa1e901a`。
- 固定核心目标：`70f0570405c3c2c47bb113b88db95006d239b346`。
- 合并前定制核心：`fbb1d931adf946f701779c70668fc9ee2aa462d2`。
- 本次核心提交：`0c0fb18ed45084c1fd320e6bdeecfe4ff6cf2c91`。
- 本次应用提交前 HEAD：`d27da715d5424ad54b045f60b9678f7ebcd47880`；其中
  Windows 配置恢复由并行任务独立提交，不计作本次上游移植。

核心采用双亲合并记录。合并前 `HEAD..70f05704` 有 216 个上游独有提交；
这表示 Git 图中的提交数，包含此前已选择移植的内容，不是 216 项新增功能。
源码来自本地已缓存的固定 Git 对象，没有把移动分支当成此次目标。

## 本次补齐的核心范围

| 范围 | 本次集成内容 | 兼容处理 |
| --- | --- | --- |
| OpenVPN | 完整 rekey、data-ciphers、tls-auth、tls-crypt-v2、控制通道与旧密钥过渡 | 保留 peer-info 输入校验和副本隔离；旧测试改用真实会话 ID、当前时间及新的数据通道注册接口 |
| Sudoku | v0.4.8 的 HTTP-mask 隧道、连接池、预连接、拨号器及复用配套 | 保留第 26 批 RESET、半关闭、缓冲释放和所有短写/零进度保护；补齐新上游测试 |
| WireGuard/AWG | AWG v3.1、版本选择及依赖更新 | 旧版与 v3 分别覆盖短数据包、填充和握手类型识别 |
| 用户态网络 | Tailscale、gVisor、sing-tun、sing-wireguard、mipstack、ZeroTier | 使用固定依赖图；跨平台编译覆盖，真实 TUN/控制平面另见限制 |
| TLS 与新协议 | JLS、ShadowQUIC、新 ShadowTLS、TLSMirror、mKCP、Mekya 及协议组合 | 保留 Restls、证书、自定义 CA、Vision 和握手资源回收修复 |
| Snell | 接入新 ShadowTLS、Restls、JLS obfs 模式 | 保留 ECH/TLS identity、旧 shadow-tls 配置入口、连接池与会话缓存；仅 identity v4 会话预热，避免标准服务端 pong 后关闭导致复用 EOF |
| 配置与路由 | rematch、default-selected、provider override-expr、DNS listen mark、XHTTP 会话 ID 选项 | 保留文件路径检查、模式回调、Geo 更新事务、旧 uplinkHttpMethod 别名与证书校验语义 |
| 代理快照 | AllProxies 按 provider 版本缓存不可变快照，配置替换和显式 GC 可清除缓存 | 宿主遍历 provider 改用锁内快照；补充刷新、旧快照不变、配置替换及并发测试 |

本次没有直接换掉定制核心引用：先解决双方源代码和依赖差异，再在隔离
工作区运行回归，最后让原子模块快进到已经验证的合并提交。

## 整合中确认并修复的问题

### 监听器握手与关闭

通用握手监听器在 Close 时等待握手结果通道，可能被阻塞的握手卡住；
晚到的握手又可能向已关闭通道发送。改为独立结束信号并取消未完成握手，
不关闭供握手提交结果的通道。成功 Accept 的连接移交调用者，不再随监听器
关闭；保留底层连接解包接口，避免破坏 REALITY/Vision。

回归覆盖阻塞握手、Close 后晚到的成功结果、已交付连接存活和父上下文
取消。旧实现的前两项确定性失败；修复后的定向竞态测试重复五轮通过。
源文件：`core/Clash.Meta/common/net/listener_lifecycle_test.go`。

新上游监听器与旧 Restls 生命周期适配时，统一失败回滚、原始 socket 关闭、
原子 closed 状态和默认监听器引用。失败构造不发布全局监听器；回滚闭包持有
实际创建的对象，避免命名返回值赋 nil 后异步访问 nil。

### Shadowsocks 2022 快速回复竞态

`sing-shadowsocks2 v0.2.7` 在初始 socket Write 和剩余载荷写完后才保存
request salt。服务端提前回复时，读线程可能判定合法回复的 salt 错误，
并与写线程发生数据竞态。完整入站竞态测试确认了同一字段的读写冲突。

最小修复是在发送请求前通过 atomic.Value 发布独立、不可变的 salt。
没有用一个锁串行化整个收发方向。确定性用例让服务端回复先于首次 Write
返回；AES-128 与 AES-256 在未修复版本均返回 bad request salt，修复后
连续 100 轮通过。核心和宿主模块都指向
`core/Clash.Meta/third_party/sing-shadowsocks2`，保留原 LICENSE 和修复说明。

### Restls 服务端流控死锁与快速应答

整套竞态测试两次在 Restls TLS 1.2 / Shadowsocks / yamux 组合停顿约 40 秒，
表现为 keepalive timeout 或 EOF。改成独立测试程序重复运行后捕获阻塞栈：
应用写入在等待客户端记录时持有 writeMu，读线程为了发送控制应答也等待
同一锁；伪装目标的握手后 TLS 记录同样无法发送。另一个时序是客户端应答
先到达，随后发送线程才设置等待标记，导致已经收到的应答丢失。

修复将“整次应用写入排序”和“单条记录发送”分成两个锁；等待期间释放记录
锁，控制应答和伪装 TLS 记录仍可发送。等待标记在网络 Write 前发布，发送失败
时释放等待。应用字节顺序、认证和计数仍按原协议处理。

`third_party/restls-client-go/restls_server_flow_control_test.go` 两项确定性测试
在原实现均失败，修复后各重复 100 轮通过。实际 TLS 1.2 下两个 Shadowsocks
加密算法的 yamux 原始场景连续 25 轮通过，共 275 条测试记录。诊断仅对隔离
测试程序发送 SIGQUIT，没有中断正在运行的应用或核心服务。

证据：`/private/tmp/flclash-port27-restls-stacks.log`、`restls-flow-before.json`、
`restls-flow-after.json`、`restls-yamux-fixed.json`（同一文件名前缀）。

### 既有本地语义的保留

- Restls 不支持的 ECH、客户端证书、REALITY、Vision 等组合继续在构造期报错；
  XHTTP download-settings 按最终下载侧 SNI/fingerprint 独立构造 Restls 配置。
- AnyTLS 认证继续完整读取分片的密码、填充长度及填充内容。
- Sudoku 编码路径继续循环处理短写，不能因合并恢复成一次 Write 即成功。
- OpenVPN 旧测试中的手工数据通道赋值不再适配新 key-ID 查找，改走生产注册接口；
  失败重协商的阻塞读取测试验证实际关闭行为。
- Sudoku 填充请求/响应的死锁测试改用 testing/synctest 虚拟时间，避免密码表
  初始化和其他并行编译消耗一秒墙钟预算；测试仍检查超时退出，没有跳过用例。

## 应用上游 10 个提交的处理清单

“适配”表示按当前 oixCloud 架构接入行为；“保留差异”表示相应重构没有照搬。
不能把下表理解为上游应用所有文件已经相同。

| 上游提交 | 内容 | 处理结果 |
| --- | --- | --- |
| `62addf73` | changelog | 保留本地产品版本及更新说明；本文件记录实际移植范围 |
| `96fcb9ab` | agents、工具、lint、CI | 已采用适用的分拆测试门禁、平台和依赖检查；保留本地开发规则、版本及发布工具 |
| `c6eaa0a6` | Go IPC、hub、ownership | 已适配 JNI/protect、文件所有权、现有 IPC/lease 安全边界；本次补齐快照/GC 配套，保留本地 Geo/恢复事务 |
| `adf715f8` | Rust、plugins、Helper、hooks | 已接入有时限/内存限制的 rquickjs、Windows Helper 恢复；Rust IPC 已存在。Linux Helper、新托盘/热键和原生 hooks 保留差异 |
| `ae29f38f` | Android VPN、tile、仲裁 | 已适配 protect 失败传播、JNI 清理、广播租约、授权取消、应用列表/权限/刷新、DNS 和 UID 生命周期；保留安全密钥、启动回滚和无界面快捷入口 |
| `c0fcbc03` | 桌面 runner 与打包 | 已适配 Windows 代理退出恢复和窗口崩溃修复；保留当前插件和打包拓扑 |
| `aaf934c2` | app/provider/model/database/manager | 已适配启动失败保护、代理认证、控制协议及相关回归；保留账户、商店、配置加密和现有数据库/动作层组织 |
| `26cfbaf4` | material_ui、页面、控件、本地化 | 保留差异：没有整体替换 UI，避免覆盖 oixCloud 主题、账户、商店及 TV 交互 |
| `d0b1562e` | 并行 CI 与缓存 | 已接入独立 Flutter/Go/Rust/Android 等门禁；本次核心门禁改为完整 vet/race 及本地依赖修复回归 |
| `db038805` | 版本发布 | 核心指向的源码已合并；不改变应用版本号、签名、标签或发布状态 |

## 明确保留、尚未移植的应用范围

这些仍是功能或架构差异，不计入“已完成移植”：

1. material_ui 全页面/控件改版，以及与之耦合的 provider action、profile/icon
   和数据库组织重构。需要连同 oixCloud 独有页面、持久化兼容和 TV 焦点整体适配。
2. SSID 排除策略和 wifi_ssid 插件。当前没有该插件，需接通配置、系统权限和
   网络切换行为；上游 Windows WLAN 动态加载修复不能作为本地已有缺陷直接套用。
3. Linux systemd Helper 的安装/卸载、用户 socket、提权进程、deb/rpm/AppImage
   升级迁移和非 systemd 兼容；保留现有 Linux 启动路径。
4. 新托盘、Rust 热键、窗口组件和原生 build hooks/打包拓扑整体迁移；保留现有
   系统代理所有权恢复、Windows Helper 会话校验和本地构建链。

上述范围已作出保留决定；此前清单中的“完整核心分支合并、Sudoku HTTP-mask、
OpenVPN rekey、Tailscale/gVisor/sing-tun 基线”不再作为下一批待移植项目。

## 本次验证

最终核心合并修改 312 个文件；原子模块已快进到上述双亲合并提交，
固定上游核心目标是其祖先。Go 数量统计包含子测试，包的“无测试文件”不会计为测试通过。测试仅使用
本机回环、临时文件和固定互通测试程序，没有访问真实用户配置、账号或订阅节点。

| 检查 | 最终结果 | 证据 |
| --- | --- | --- |
| 完整 mihomo vet/race（with_gvisor） | 7,021 条通过：891 顶层 + 6,130 子测试；无失败/测试跳过 | `/private/tmp/flclash-port27-core-final4.json`、`core-final-vet.log` |
| 宿主 Go core vet/test（CGO_ENABLED=0） | 175 通过，1 项环境跳过 | `/private/tmp/flclash-port27-parent-final3.json` |
| Flutter core/models | 245 个实际测试通过；排除 22 条文件加载记录 | `/private/tmp/flclash-port27-flutter.json` |
| Shadowsocks 2022 依赖完整 vet/race | 3 个测试记录通过 | `/private/tmp/flclash-port27-ss2022-full.json` |
| Restls 依赖 CI 精确竞态门禁 | 164 条测试记录通过 | `/private/tmp/flclash-port27-restls-dependency-final.json` |
| Restls 流控回归 100 轮 | 两个确定性测试共 200 条通过记录 | `/private/tmp/flclash-port27-restls-flow-after.json` |
| Restls TLS 1.2 / yamux 真实协议复验 | 两个加密算法、25 轮，共 275 条通过记录 | `/private/tmp/flclash-port27-restls-yamux-fixed.json` |
| salt 快速回复回归 100 轮 | 300 个通过记录，包含每轮父测试和两个密码子测试 | `/private/tmp/flclash-port27-ss2022-after.json` |
| Android arm64 / arm / amd64 | 三种均通过 JNI 故障回归、Go vet、c-shared 及 C++ 链接 | `/private/tmp/flclash-port27-android-final2-{arm64,arm,amd64}.log` |
| Windows / Linux / macOS | 每个平台 amd64、arm64 核心均编译通过，共六种 | 隔离目录 `/private/tmp/flclash-port27-parent/` 中的核心可执行文件 |
| 依赖一致性 | 两个 Go 根模块九项更新依赖及四个本地 replace 完全一致 | `go list -m` 解析并比较实际路径 |
| 源码一致性 | 隔离宿主的 80 个受管文件与最终工作区逐字节一致 | 包含 core、Android core/JNI 和检查脚本 |
| 格式与门禁 | Go 格式、git diff --check、CI YAML 解析通过 | 新 CI 运行全核心 vet/race 及四个依赖修复 |

核心有测试的 89 个包通过，另有 99 个包没有测试文件；完整入站套件重新执行耗时
282.315 秒。全部最终命令退出 0。

宿主环境跳过项是 `TestPersonalOverlayRuntimeFromGeneratedConfig`，隔离验证未
准备它要求的生成配置。没有设置 SKIP_CONCURRENT_TEST 或 SKIP_INTEROP_TEST；
固定版本的 V2Ray 互通夹具在临时目录构建，目标是本机监听器。

完整测试期间还出现过一次 XHTTP split/mTLS+ECH 请求 unexpected EOF，记录于
`/private/tmp/flclash-port27-core-final2.json`；原始场景独立重复 10 轮通过
（150 条测试记录），下一轮全量也未再次出现。该一次性 EOF 的根因尚未定位，
复验通过不能证明问题已修复。没有用自动重试或忽略失败断言掩盖它。
Restls/yamux 在第二、三轮的重复失败已定位并修复，见上文。

Restls 依赖的全项 go vet 还会报告上游 `tls_test.go:884` 的反射复制原子值，
以及 `u_conn.go:76` 的不可达代码；这两处未由本次修改产生，未修改或宣称消除。
应用/核心自身完整 vet 和既有 Restls 精确竞态测试门禁仍分别验证。

最后一轮全量测试在跨架构编译结束后运行；未变动且已成功的包允许复用 Go 测试缓存，
此前失败的 listener/inbound 重新完整执行。包级并发和测试并发均限制为 2；
CI 同步该资源限制。

可复现命令（NDK 28.2.13676358，Go 1.26.3）：

```sh
# 在 core/Clash.Meta 内
GOCACHE=/private/tmp/flclash-go-network-cache go vet -tags with_gvisor ./...
GOCACHE=/private/tmp/flclash-go-network-cache go test -race -tags with_gvisor -p=2 -parallel=2 -timeout=900s ./...
go test -race github.com/metacubex/sing-shadowsocks2/...
# 在应用 core 内
CGO_ENABLED=0 go vet -tags with_gvisor ./...
CGO_ENABLED=0 go test -tags with_gvisor ./...
# 在应用根目录内
flutter test --no-pub test/core test/models
ANDROID_NDK_HOME=/path/to/ndk bash tool/check_android_core.sh arm64
# arm / amd64 同样执行；未调用 setup.dart 生成签名安装包
```


## 设备与交付限制

- Android 三种 ABI 的 Go vet、c-shared 和真实 JNI 链接不等于 APK/真机验收。
  最初 Android 9/13 桌面切换小部件的视觉闪烁仍待真机确认。
- Windows/macOS/Linux 的 Go 核心交叉编译不等于完整安装包或平台原生 UI 测试。
- TUN、Tailscale、ZeroTier、OpenVPN 的真实网络部署和外部控制平面未在此执行；
  本次通过的是本地协议回归、静态检查和编译。
- 仅创建本地提交；没有推送、移动标签、生成签名安装包或部署。

## 后续 UI 与平台迁移

用户已授权继续四组保留项，SSID、Rust 热键和新托盘已接入，详细实现、验证和剩余范围见 [迁移记录](upstream-v0.8.97-ui-platform-migration.md)
