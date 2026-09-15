# Emerald OS · 桌面系统架构设计与开发计划

> 工作名 **Emerald（绿宝石）**——矿物学上 Emerald 是 Beryl（绿柱石）的一个变种，
> 寓意"长在 Beryl 之上的完整系统"，与 Citrine/Beryl 同族命名。
> 定位：**Beryl 桌面外壳之上的完整 Web 桌面操作系统**——应用框架、虚拟文件系统、
> 设置/主题、通知、快捷键、启动器与一组内置应用。citrine ≈ 内核，beryl ≈ 组件库 +
> 外壳原语，emerald ≈ 整机系统。Beryl 的第二个真实消费者（第一个是 RubyWorld）。
>
> 状态：**E0–E7 已落地（2026-09-15，emerald 361 项测试 + Opal 编译验收全绿，
> beryl 82 项、citrine 286 项全绿）**——E7（可分发源码应用）当日设计定稿并实施完毕：
> .emz 包格式、Installer（zip/目录/git 来源）、/Applications 扫描 + 编译缓存、
> CommandRegistry、Service 生命周期（deactivate 链）、About 降级为预装源码应用；
> 浏览器端到端验收通过（安装 → 刷新持久 → 热更新 → 开窗渲染）。
> 核心包 gzip 1.0MB、opal-parser 独立 chunk gzip 1.58MB（D12 懒加载，不占核心预算）。
> 实施中的定稿决策与遗留见 §9。本文档是唯一的规划事实源，变更须同步修订。
> 2026-09-15 修订：新增 3.9 / 3.10、D10–D12、E7——可分发源码应用（.emap）
> 与 Service/View 双子架构（VS Code 插件模型）。
> 2026-09-15 修订②：包格式与 Endpoint 协议升格为生态级标准文档
> （docs/SPEC-package-format.md、docs/SPEC-endpoint-protocol.md）；
> 安装来源新增 git 仓库直接导入（SPEC §5）。

---

## 0. 目标与非目标

**目标**
- 在浏览器（Opal）里跑起一个"完整感"的桌面：壁纸、桌面图标、菜单栏、任务栏、
  多窗口、应用启动器、通知、设置、文件管理——全部用 Ruby 组件写就。
- 内置一组真实可用的应用，形成 dogfood 闭环：文件管理器 + 文本编辑器 +
  设置 + 终端（VFS shell）+ 关于。
- 全部系统服务与应用逻辑保持**纯 CRuby 可测**（beryl F5 同款纪律）；
  经 citrine packager 可打包为 macOS .app。

**非目标（v1 不做）**
- 多用户/权限/进程隔离——单用户单会话，"OS"是隐喻不是内核。
- 真实网络协议栈/真实二进制执行。
- Canvas 渲染后端适配（跟 beryl M6 评估走）。
- 移动端布局。

## 1. 分层架构

```
L6  内置应用    emerald   About · Files · Editor · Settings · Terminal · Viewer(stretch)
L5  系统服务    emerald   AppRegistry · Launcher · VFS · SettingsStore ·
                        NotificationCenter · ShortcutRegistry · Clipboard · FileTypeRouter
L4  桌面外壳    emerald   DesktopShell（壁纸/图标网格/菜单栏/任务栏组装/托盘）
                        ── 稳定 ≥1 个里程碑后按"反哺通道"上提 beryl ──
L3  桌面外壳    beryl     WindowFrame · WindowManager · Taskbar · MenuBar · z 序 · 吸附
L2  控件层      beryl     Menu · Select · Tabs · Dialog · Table · List · Tree · …
L1  原语层      beryl     drag · front · menu · hover · dblclick · wheel · scroll · tip ·
                        drag_payload/on_drop · auto_dismiss · textarea
L0  内核        citrine   Signal / Effect / Component / Renderer 家族
```

依赖单向向下。Emerald 只通过 citrine/beryl 的公共 API 组合，不 fork、
不猴子补丁；发现缺口先在 emerald 落地，稳定后反哺（见第 5 节清单）。

## 2. 仓库与构建

```
emerald/
  lib/emerald.rb               入口（Opal 守卫加载存储适配层）
  lib/emerald/shell.rb         DesktopShell + 桌面图标网格 + 托盘
  lib/emerald/app.rb           App 基类 + AppRegistry + manifest 宏
  lib/emerald/runtime.rb       服务运行时（桌面无关服务构造，shell/Standalone 共用；
                               ServiceHub 正式化第一步，PLAN §3.9）
  lib/emerald/standalone.rb    独立宿主（应用脱离桌面外壳运行，自带 Runtime + Toast 堆叠）
  lib/emerald/vfs.rb           虚拟文件系统（纯 CRuby）+ 路径工具
  lib/emerald/storage.rb       持久化适配协议 + localStorage 后端（仅 Opal）
  lib/emerald/settings.rb      SettingsStore（schema 版本化）
  lib/emerald/notify.rb        NotificationCenter（Toast 堆叠封装）
  lib/emerald/hotkey.rb        ShortcutRegistry（citrine window_key 之上）
  lib/emerald/clipboard.rb     系统剪贴板（DragBus 同文档 + navigator.clipboard）
  lib/emerald/router.rb        FileTypeRouter（扩展名/mime → app）
  lib/emerald/apps/            内置应用（about/files/editor/settings/terminal）
  emerald.gemspec              发布名 citrine-emerald（rubygems 的 emerald 名必被占，
                               对齐 citrine-beryl 先例），Gemfile 走 gemspec + path 依赖
  examples/desktop.rb          演示入口（= 整机）
  examples/desktop.html        页面壳（box-sizing: border-box 必备，beryl 踩坑）
  examples/standalone/         独立宿主示例（about.rb + about.html，rake standalone 编译）
  test/                        minitest（按子系统分文件）
  docs/PLAN.md                 本文档
```

- Gemfile：`gem 'citrine', path: '../citrine'`、`gem 'citrine-beryl', path: '../beryl'`
  （require 名 'beryl'）。浏览器编译：`bundle exec opal -c -I../citrine/lib -I../beryl/lib
  -Ilib -o examples/desktop.js examples/desktop.rb`（借 citrine 的 bundle，同 beryl 惯例）。
- 开发：`cd citrine && bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib`。
- **工具链钉死**：ruby 3.x + bundler 与 citrine 同版本（beryl 仓 Gemfile.lock 要
  bundler 2.7.2，系统 ruby 2.6 跑不起来——新仓一开始就把 `.ruby-version` 钉上）。
- CI：复制 beryl 的 GitHub Actions 矩阵（CRuby 测试 + Opal 编译验收）。

## 3. 核心子系统设计

### 3.1 DesktopShell（L4，shell.rb）

整机根组件，单一 WindowManager 实例的 owner。职责：

- 组装：壁纸层 → 桌面图标网格 → 所有窗口（`wm.windows` 条件渲染，见 D4）→
  MenuBar → Taskbar → 托盘（时钟/通知角标）→ Toast 堆叠 → 全局 Dialog。
- viewport 跟踪：`window.innerWidth/Height` 注入 `wm.viewport=`（resize 事件回调里，
  不在 view 里——F6）。
- 启动序列：initialize 里建服务（settings 先 load）→ 注册内置应用到
  AppRegistry → 恢复上次窗口布局（可选，v1.1）→ 注册自启应用（事件外安全区）。
- **不持有业务状态**：shell 自己的交互态（菜单开合、图标选择集）全部受控
  signal（beryl F4）。

### 3.2 App 框架（L5，app.rb）——本设计的心脏

**问题**：beryl 的 WindowManager 管"窗口"，OS 需要管"应用"——
窗口与 app 实例的绑定、单例/多实例、启动参数、退出回收。

```ruby
class Emerald::Apps::Editor < Emerald::App
  app_id      :editor
  app_title   '文本编辑器'
  app_icon    '📝'              # emoji（v1）；图标体系化随 beryl M5
  singleton   false             # true 时重复启动 = focus 已有窗口
  default_geometry { { x: 120, y: 80, w: 560, h: 420 } }

  def boot(ctx)                 # ctx: services Hash（:vfs/:settings/:notify/...，见 R3）
    super
    open_file(argv[:path]) if argv[:path]   # argv 是独立属性，不在 ctx 里（R2）
  end

  def view                      # 窗口内容（挂进 frame 的 content 槽，beryl F2）
    textarea(value: signal(:buf), on_submit: -> { save })
  end
end
```

- `Emerald::App < Citrine::Component`：manifest 四宏（类级声明）+ `boot(ctx)`
  生命周期 + `view` 内容。app 内部仍可用全部 beryl 组件。
- `AppRegistry`（纯服务，非组件）：
  - `register(AppClass)` / `launch(app_id, **argv)` / `dispose(win_id)` /
    `running?(app_id)` / `instance(win_id)` / `each_running` / `apps`。
  - **窗口 id 方案**：singleton → `:"editor"`；多实例 → `:"editor#2"`
    （per-app 自增，跳过仍占用的号）。id 即 WindowManager 注册键。
  - `launch` 流程：`klass.new → 赋 win_id → argv= → boot(ctx)`，**只建实例
    不开窗**（开窗是 shell 的事，见 R2）；singleton 命中 → `wm&.focus` 返回
    已有实例。launch/dispose 只能从事件回调进入（beryl F6 守卫内置）。
  - 关闭链路：shell 渲染窗口时把 `wm.frame` 的 `on_close` 覆写为
    `-> { close_window(win_id) }`——先 `wm.close` 注销窗口再 `registry.dispose`
    回收实例。
- shell view 渲染窗口：

```ruby
registry.each_running do |inst|
  next unless wm.windows.include?(inst.win_id)   # D4：关闭后必须条件渲染
  wm.frame(inst.win_id, content: -> { inst.view },
           on_close: -> { close_window(inst.win_id) }).view
end
```

### 3.3 虚拟文件系统 VFS（L5，vfs.rb）

- 内存规范树：`Node = { name, kind: :dir|:file, content: String, mtime: }`，
  路径工具 `join/normalize/resolve`（支持 `.`/`..`，禁止逃逸根）。
- API：`read / write / mkdir / list / stat / move / delete / exist?`；
  写操作统一走 `commit { }`，内部完成持久化调度 + 变更信号触发。
- 变更通知：`watch(dir) -> Signal`（版本号 bump 语义；Files 应用它订阅目录刷新）。
  集合用 `Citrine.signal_list`（beryl F9）。
- 持久化：adapter 协议 `load -> Hash | nil` / `dump(Hash)`，**写后防抖 300ms**
  （Beryl::Timer，CRuby 测试注入同步后端）。v1 后端 localStorage
  （key `emerald.fs.v1`，JSON 序列化）；OPFS 后端列为 v1.1 评估项
  （容量与二进制友好，API 异步需预研）。
- 初始镜像：首次启动 seed 一份——`/docs/readme.txt`（有内容）、`/Desktop`、
  `/images`（空目录）；幂等，已存在不覆盖。
- 纯 CRuby 可测：树操作、路径规范化、commit 语义全部 StringRenderer 级单测。

### 3.4 SettingsStore 与持久化（L5，settings.rb + storage.rb）

- 分 key 存储（各自版本号，互不因 schema 升级陪葬）：
  `emerald.settings.v1`（主题/壁纸/密度）、`emerald.icons.v1`（图标位置）、
  `emerald.windows.v1`（窗口布局，v1.1）、`emerald.fs.v1`。
- 读取即 Signal：`settings.get(:theme)` 订阅式；`set` 同步持久化（防抖）。
- 启动时**首渲染前**完成 load（同步读 localStorage），避免主题闪变。
- localStorage 适配层是 emerald 唯一的 Opal 代码集中地之一
  （`defined?(Opal)` 守卫；CRuby 测试用 Hash 后端注入——Beryl::Timer 同款模式）。

### 3.5 NotificationCenter（L5，notify.rb）

- `notify.push(msg, kind:, actions:)` → 内部 `Citrine.signal_list` +
  `push_bounded(limit: 5)`（beryl demo 既有模式正式化）。
- shell view map 渲染 `Beryl::Toast`（auto_dismiss 到期回调里 delete_at）。
- v1.1：托盘角标 + 历史列表。

### 3.6 ShortcutRegistry（L5，hotkey.rb）

- `Emerald.hotkey.register('meta+s', scope: :editor) { save }`；
  chord 解析（`meta/ctrl/alt/shift+key`）、scope 路由（全局 vs 激活窗口所属 app）。
- 底层用 citrine L0 的 `window_key`；beryl PLAN M-WM+ 已列 `Beryl.hotkey` 待办——
  **在 emerald 先做，稳定后反哺 beryl**。
- 内置默认：⌘S 保存、⌘W 关窗、⌘` 循环窗口、⌘Space 启动器（v1.1）。

### 3.7 桌面图标与启动器（L4/L5）

- 图标网格：绝对定位（位置存 `emerald.icons.v1`），单击选中（受控 signal 选择集）、
  双击启动（L1 `on_dblclick`）、拖拽换位（L1 drag 原语，落点写回——
  用 beryl setup_drag 的"纯数学回写"模式规避手势/重渲染竞争）。
- 图标来源：VFS 桌面目录 `/Desktop`（文件即图标，拖进拖出真实移动文件）+
  系统固定项（关于/设置）。
- MenuBar 即 v1 启动器（"应用"菜单列出注册表）；Spotlight 式启动器列 v1.1。
- 框选（rubber-band）多选：v1.1。

### 3.8 主题（L4 消费）

- **beryl M5 deferred（实施修正，2026-09-15）**：token 表自包含于 emerald——
  `theme.rb` 持有 dark/light 调色板 + comfortable/compact 密度档（纯函数
  `Theme.vars`，可 JSON 序列化），`Theme.apply` 在 Opal 下写
  `document.documentElement`；`desktop.html` 的 `:root` 默认值与 dark 表逐一
  相等。beryl M5 上游迁移仍在 beryl 路线图，届时 emerald 切换为消费方。
- Settings 应用只做切换：RadioGroup/ColorPicker/Select 受控件 →
  `settings.set` + `Theme.apply` 即时重应用；`settings.get(:theme)` 订阅 +
  shell `watch` 兜底重应用。首渲染前 `Theme.apply` 一次防闪变。
- 壁纸：CSS 渐变预设（aurora/graphite/meadow）存 settings；图片壁纸依赖 VFS
  `/images` + data URL（v1.1）。

### 3.9 App 的 Service/View 双子结构（VS Code 插件模型）

**问题**：窗口是渲染轮次的产物，应用逻辑却要活得比窗口久——响应命令、
文件关联、后台任务都不能随关窗死。借鉴 VS Code 插件模型（声明式贡献点 +
Extension Host + API 面 + 惰性激活），App 拆成两半：

- **Service**（无 UI 逻辑，`Emerald::Service`）：`activate(ctx)` / `deactivate`，
  生命周期跟**激活事件**（manifest 声明 `activation: { on_command: /
  on_file_type: / on_startup: }`），与窗口开关无关。应用状态一律 signal。
- **View**（窗口内容，现 `App#view` 形态不变）：跟窗口生死，只是 Service
  状态的投影——Signal/Effect 天然充当"UI 反映状态"的胶水，无需手工 IPC。
- **ctx 是唯一能力面**（ServiceHub 演进）：commands / vfs / notify / settings /
  subscriptions（deactivate 时统一回收）。Service 禁碰 DOM 与 beryl 组件——
  纯 CRuby 可测纪律天然封锁（D5 同款）。
- **CommandRegistry**（新 L5 服务）：命令统一注册入口，同时喂给启动器 /
  MenuBar / ShortcutRegistry——一次注册三处可达。
- v1 同 realm 逻辑隔离；ctx 一律按**异步消息式**设计，v1.1+ Service 层可整体
  迁入 Web Worker（= VS Code Extension Host；Opal 产物跑裸 JS 引擎已经
  citrine M0 Hermes spike 逐字节验证），获得"UI 卡死、服务仍活"的性质。

### 3.10 可分发应用：.emap 源码包与 Installer

**定调：包内只有源码，编译产物是本地可丢弃缓存**（Emacs `.el` + byte-compile
模式）。系统本身是浏览器里的 Ruby 运行时，Ruby 源码就是它的原生可执行格式；
源码分发同时换来三样性质：可审计、可在系统内编辑（Editor/Terminal dogfood
闭环）、作者侧 CRuby 可测。

- **包格式与安装来源**：正式标准见 docs/SPEC-package-format.md（容器 `.emz`，
  kind = app/agent/skill 三型共用；git 仓库直接导入语法
  `git:<URL>[#ref][?path=subdir]`，浏览器端走平台 archive HTTP，CLI 端真实
  clone，安装记录 lock 固化 resolved_commit）。FileTypeRouter 注册 `.emz` →
  Installer：解包 → 校验 manifest → 写 VFS `/Applications/<app_id>/` → 编译 →
  AppRegistry.register → 通知。启动序列加"扫描 /Applications"一步；
  **内置应用 = 预装应用**（E7 拿 About 验证）。
- **编译缓存**：产物 JS 存 `/System/Cache/<app_id>.js`，键 = 源码 hash +
  Opal 版本。启动直接注入缓存、不碰 parser；源码变更或 Opal 升级自动重编；
  编译失败保留上一个好版本继续跑 + 通知提示修复。
- **opal-parser 是懒加载系统服务**（独立 chunk，首次安装/编辑源码应用时动态
  加载，浏览器 HTTP 缓存接管后续），**不占核心 300KB gzip 预算**——
  rake size 守门对象不变（修订 D9 的 stretch 定位，见 D12）。
- **隔离**：维持"OS 是隐喻"的非目标——第三方应用同 realm 执行，无沙箱；
  `permissions` 字段仅占位。无隔离模型下的信任机制 = 每个应用源码可看。

## 4. 关键设计决策

| # | 决策 | 理由 / 依据 |
|---|---|---|
| D1 | **新仓独立演进**，不并入 beryl | beryl 是通用组件库（定位 MUI/AntD + 外壳原语）；OS 是应用。与 rubyworld 同级消费者 |
| D2 | **AppRegistry 拥有 WindowManager 的全部变更权** | beryl F6：WM 变更禁止在 view 内；集中入口（launch/dispose/focus）便于守卫与持久化挂钩 |
| D3 | **窗口内容走 `content:` Proc 槽**（app.view 挂进去） | beryl F2 唯一正规组合方式；实例生命周期归 registry，不归渲染轮次（规避 F4 自焚） |
| D4 | **渲染窗口一律 `wm.windows.include?` 守卫** | beryl 踩坑：✕ 注销后无守卫 frame 会 raise，重渲染半途崩掉任务栏 |
| D5 | **VFS 纯 CRuby + 适配器持久化** | beryl F5 / Beryl::Timer 同款；OPFS 异步不确定性与核心解耦 |
| D6 | **持久化分 key 分版本**，启动同步 load | 局部 schema 升级不牵全身；首渲染前 load 防主题闪变 |
| D7 | **快捷键/主题先在 emerald 验证，反哺 beryl** | beryl M5 / M-WM+ 已列同名待办；遵守"反哺通道：稳定 ≥1 个里程碑再上提" |
| D8 | **窗口布局持久化 v1.1 而非 v1** | 恢复语义与最大化/吸附 restore 几何耦合深，先跑通核心再回 |
| D9 | **Terminal v1 = VFS shell**（ls/cd/cat/mv/echo>），opal-parser REPL 列 stretch | opal-parser 引入显著体积（gzip 预算 300KB 守门），v1 不冒进；D12 后 REPL 与 Installer 共用懒加载 chunk，定位不变 |
| D10 | **App 架构 = Service/View 双子 + ctx 唯一能力面**（VS Code 插件模型） | 逻辑寿命独立于窗口；Signal 天然做 UI 投影胶水；ctx 异步消息式为 Worker 化与远期 AgentOS 伴生进程（citrine 路线 B）留可换传输层 |
| D11 | **分发包源码为正本、编译产物为本地缓存** | 可审计（无隔离下唯一信任机制）、系统内可编辑 dogfood、作者侧 CRuby 可测；缓存键含源码 hash + Opal 版本防漂移 |
| D12 | **opal-parser 懒加载系统服务，不占核心预算**（修订 D9 前提） | 核心包 gzip ≤300KB 守门不变；parser 独立 chunk 首次安装/编辑时按需加载，HTTP 缓存接管后续 |

## 5. 与 beryl/citrine 的边界（反哺清单）

| 能力 | 先在 emerald | 反哺目标 | 触发条件 |
|---|---|---|---|
| 快捷键注册表 | hotkey.rb | beryl `Beryl.hotkey`（M-WM+ 已定） | E5 稳定后 |
| 主题 token 表 | —（直接在 beryl 做 M5） | beryl M5 | E4 前置，进 beryl 仓开发 |
| 吸附实时预览 | —（beryl M-WM+） | beryl WindowManager | 桌面 dogfood 痛点确认后 |
| 桌面图标网格 | shell.rb | 评估留应用层（桌面语义重，暂不上提） | — |
| Timer 防抖模式 | settings/vfs 复用 | 已在 beryl | — |
| `render(key:)` 插槽 block | — | citrine S3 待办 | 窗口 live 拖拽跟随彻底修复依赖它 |

## 6. 里程碑与验收

| 里程碑 | 内容 | 验收 | 预估 | 状态（2026-09-15） |
|---|---|---|---|---|
| **E0** 骨架 | 仓库/Gemfile path 依赖/Rakefile/minitest/Opal 编译验收/CI（抄 beryl）/`.ruby-version` | `bundle exec rake` 绿；`opal -c` 通过；CI 绿 | 0.5d | ✅ 落地 |
| **E1** 最小桌面 | DesktopShell（壁纸+MenuBar+Taskbar+WM）+ About 应用 + 菜单启动 | 浏览器：菜单启动 About→开/关/最小化/最大化/吸附；任务栏联动；`bin/citrine dev` 可跑 | 1d | ✅ 落地（dev server 冒烟 200；浏览器逐项交互验收待人过） |
| **E2** App 框架 | App 基类 + manifest 宏 + AppRegistry（singleton/多实例/argv/dispose）+ 关闭链路 | CRuby 单测：注册/启动/单例命中/回收；浏览器：双开 Editor 两窗口互不干扰 | 1–2d | ✅ 落地（launch 不开窗，shell.launch_app 统一开窗——R2） |
| **E3** VFS + Files + Editor | VFS 核心 + localStorage 适配 + Files（Tree+Table+面包屑+右键菜单）+ Editor（textarea 保存）+ FileTypeRouter（.txt→Editor） | 单测：VFS 全 API + 路径边界 + commit 语义；浏览器：新建/编辑/保存/刷新页面仍在；Files 双击 .txt 起 Editor | 3–4d | ✅ 落地（beryl Table 无行级 dblclick/on_menu，Files 主区手搓 b-table 类名表格） |
| **E4** 图标 + 设置 + 主题 | 桌面图标网格（选择/双击/拖拽换位持久化）+ Settings 应用 + 暗/亮主题 + 壁纸 | 前置 beryl M5 完成；浏览器：拖图标刷新后位置保持；主题切换无闪变 | 2–3d | ◐ 部分：图标网格（固定布局）/设置/主题切换已落地；**beryl M5 deferred**（token 自包含，R4）；图标拖拽换位 v1.1 |
| **E5** 系统服务 | NotificationCenter + ShortcutRegistry（⌘S/⌘W）+ Clipboard + 跨应用拖拽（Files→Editor 落下即开）+ Terminal（VFS shell） | 单测：hotkey chord 解析/scope 路由；浏览器：拖文件到编辑器窗口打开；终端 ls/cat 真实读写 VFS | 2–3d | ◐ 部分：通知/快捷键/剪贴板/终端已落地（⌘W、⌘1-9 已接线）；跨应用文件拖拽 v1.1（依赖 citrine render(key:) 插槽） |
| **E6** 打包与打磨 | citrine packager → Emerald.app + 体积审计 + 启动性能 + 文档 + 反哺 beryl 首批 | .app 双击可用；gzip 体积对照预算；beryl 收到 hotkey 上提 PR | 1–2d | ✅ 落地（packager 增 `-I`/目录/`-n` 支持，citrine 286 项绿；`build/Emerald.app` 启动验证通过；体积超预算见 R7） |
| **E7** 可分发应用 | .emz 包格式（SPEC-package-format）+ Installer（本地包/目录 + git 导入）+ installed.json lock + /Applications 扫描注册 + 编译缓存 + CommandRegistry + Service/View 重构 + About 降级为预装源码应用 | 单测：manifest 校验 / git 来源解析与 lock 固化 / 缓存失效 / 激活事件 / 命令注册；浏览器：双击 .emz 与 git URL 导入均 → 启动器出现 → 开窗口 → 刷新仍在；Editor 改源码保存 → 重编生效 | 2–3d | ✅ 落地（2026-09-15 当日实施：pkg 管线 8 文件 + CommandRegistry/ServiceHub + AppHost + shell 接线；单测 361 项绿；浏览器实测 .emz 安装/双击路由/刷新持久/热更新/卸载全通。偏差与遗留见 §9 R8–R14） |

关键路径：E0 → E1 → E2 → E3（VFS 是最长单项）→ E4（等 beryl M5，可并行）→ E5 → E6 →
E7（依赖 E3 的 VFS 与 E5 的 FileTypeRouter/通知）。
整体约 **2 周**专职量级；beryl M5 若由他人/并行推进，E4 不阻塞 E5。

## 7. 测试策略

1. **单元（纯 CRuby，`bundle exec rake`）**：AppRegistry 生命周期、VFS 全 API
   （含路径逃逸防御）、SettingsStore schema/版本、hotkey chord/scope、
   FileTypeRouter、组件渲染断言（`Citrine.render` → StringRenderer）。
   目标覆盖率向 beryl 看齐（beryl 现 79 项）。
2. **Opal 编译验收**：CI 里 `opal -c` 全量编译 examples（beryl 同款）。
3. **浏览器 E2E**：唯一交互验收场——启动/关窗/拖拽/保存/主题/快捷键逐项过
   （beryl 第 6 节同款策略）。注意 ZCode 内置浏览器 `press("Enter")` 不派发
   keydown，回车用合成 KeyboardEvent（citrine 已知环境缺陷）。
4. **演示页即整机**：`examples/desktop.rb` 就是产品本体，不是玩具画廊。

## 8. 风险与既有坑位映射

| 风险/坑 | 应对 |
|---|---|
| view 内 set Signal 无限重入（beryl F6） | WM/AppRegistry 变更全部事件回调进入；`assert_outside_effect!` 已有守卫；E2 单测锁定 |
| 子组件实例随父块重建自焚（beryl F4） | app 实例归 registry 管（D3）；交互态一律受控 signal 注入 |
| 忘 `.view` 控件"消失"（beryl F8） | 约定：shell/app 的 helper 方法一律返回 `.view` 结果；review 清单 |
| 关闭窗口后渲染崩溃（beryl 踩坑） | D4 条件渲染；`close_window` 统一入口 |
| 拖拽手势与重渲染竞争（beryl setup_drag 已修一半） | 图标拖拽用落点回写（不追求 live 跟随）；live 跟随等 citrine `render(key:)` 插槽支持（S3） |
| 尺寸口径"呼吸"bug | 页面壳 `box-sizing: border-box` 写进 E1 验收 |
| localStorage 容量（~5MB）与同步阻塞 | VFS v1 面向文本场景够用；OPFS v1.1 评估；dump 防抖 |
| prop 名撞元素 DSL（beryl F3） | 命名避让（不用 label/text 等）；citrine 已有同名守卫 |
| `::Signal` 撞 stdlib（citrine F14） | 服务类 `include Citrine::Reactive` 或 `Citrine.signal(...)`，beryl WindowManager 同款 |
| opal-parser 体积 | Terminal REPL 列 stretch（D9），不进关键路径；Installer 路径走 D12 懒加载 chunk |
| 第三方应用同 realm 执行无沙箱 | 非目标明示 + permissions 占位 + 源码可审计；v1.1 Worker 隔离评估 |
| opal-parser chunk 独立体积（首次安装时的真实下载） | 懒加载 + HTTP 缓存；安装进度走 NotificationCenter |
| 用户改坏 /Applications 内源码 | 编译失败 ≠ 系统崩：缓存保留上一好版本 + 通知修复提示 |
| 编译缓存与 Opal 版本漂移 | 缓存键含 Opal 版本；manifest `min_emerald`；失败报"应用需更新" |


## 9. 实施记录（2026-09-15，E0–E7 落地当日）

实施方式：E0 骨架 → 两波并行子任务（系统服务层 → 外壳与内置应用）→
集成修正 → E6 打包 → E7 可分发应用（pkg 管线 → 安装器/扫描 → 命令与
Service 生命周期 → 预装降级 → 外壳接线 → 浏览器端到端验收）。
测试现状：**emerald 361 项**（1072 断言）、**beryl 82 项**、
**citrine 286 项**，全部 0 失败；emerald 侧 Opal 编译验收与 dev server 冒烟通过。

### 实施中对本文档的定稿修正

| # | 记录 |
|---|---|
| R1 | **ctx 与 argv 分离**：`boot(ctx)` 的 ctx = services Hash；启动参数是 App 实例独立属性 `attr_accessor :argv`（修正 §3.2 原示例的 `ctx.argv` 写法） |
| R2 | **launch 不开窗**：`AppRegistry#launch` 只建实例（boot 抛错不留幽灵实例）；开窗由 shell 的 `launch_app` 统一执行——`registry.launch` + `wm.open`（title 取 `inst.class.app_title`，geometry 取 `default_geometry` 块 + 按存活序号 x/y 级联 +24）；单例复防以 `wm.windows.include?` 短路。dispose 只回收实例，窗口归 shell/wm |
| R3 | **services 键定稿**：`:vfs :settings :notify :clipboard :router :launcher :apps :open_file`；`:launcher` 与 `:apps` 是同一 AppRegistry 的两个别名（前者「启动」语义，后者「应用列表」语义）；`:open_file` 是 lambda——router 命中 → `launcher.launch(app, path:)`，未命中 → 通知 warning |
| R4 | **beryl M5 deferred**（D7 的例外）：主题 token 自包含于 `theme.rb` + `desktop.html`，不动 beryl 仓；M5 完成时 emerald 切换为消费方（§3.8） |
| R5 | **beryl 上游修复**：`WindowManager#each_window` 空表时块返回值 `[]` 被渲染层 tos 成可见 `"[]"` 文本——已修（显式 `nil`）并在 beryl `window_test.rb` 加回归测试 `test_taskbar_empty_renders_no_brackets` |
| R6 | **ctx 与 argv 分离不变；storage E7 前置修复**：`LocalStorage#load` 返回的裸 JS 对象（JSON.parse 产物）无任何 Ruby 方法，浏览器带数据重载在 VFS/Settings 的 `is_a?(Hash)` 处 TypeError——新增 `Emerald::Storage.from_native`（对象→Hash、数组原生直通、null→nil）并接入 load |
| R7 | **体积审计（E6）维持**：核心 `desktop.js` 3.94MB / gzip 1.01MB（E7 pkg 管线入 bundle 增加约 0.1MB）；opal-parser 独立 chunk `desktop-parser.js` gzip 1.58MB（`rake parser_chunk` 产出，D12 懒加载，不占核心预算） |

### E7 实施记录（2026-09-15）

**落地子系统**（均为纯 CRuby 可测 + Opal 同构，字节底座自研——opal 1.8.3 无
Zlib/Digest/pack('C*')）：

- `lib/emerald/pkg/`：`json`（双端 JSON 适配）、`manifest`（schema 校验，§3/§4）、
  `source`（安装来源语法 + GitHub/GitLab archive URL）、`bytes`（Array<Integer>
  字节表示 + latin1/UTF-8 边界）、`sha256`（纯 Ruby，lock 指纹 + 缓存键）、
  `inflate`（RFC 1951 解码器）、`zip`（只读 central directory，stored/deflate）、
  `lock`（installed.json）、`installer`（三类来源 → /Applications + lock 固化、
  内容指纹幂等、archive 顶层目录剥离、monorepo subpath）、`apphost`（扫描 +
  编译缓存键 = 源码 sha256 + Opal 版本 + 子类捕获注册 + reload reopen 语义）、
  `opal_parser`（D12 懒加载 chunk 适配，同步 XHR 兜底）。
- `lib/emerald/commands.rb`：CommandRegistry（一次注册喂启动器/菜单/快捷键）。
- `lib/emerald/service.rb`：Service（activation 宏）+ ServiceHub（on_command /
  on_file_type / on_startup 幂等激活、deactivate_all）。
- `lib/emerald/packages.rb`：About 预装包正本（源码文本形态随 bundle 分发），
  桌面首次启动 seed 进 /Applications/about 并打 `bundled` 标记（类已随 bundle
  定义，开机不求值——**内置应用 = 预装应用**落地）。
- shell 接线：启动扫描 → 贡献点接线（contributes.commands → 命令 + 快捷键、
  file_types → FileTypeRouter）→ `.emz` 打开路由 → `install_package_bytes` /
  `install_git_url` / `uninstall_package` → Editor 保存钩子 `reload_source`
  （/Applications 下源码保存 → 重编 + reopen 热更新）。
- Editor `deactivate`：窗口关闭即 dispose dirty 追踪 Effect（多开多关不再累积）。
- `rake parser_chunk`：独立编译 opal-parser chunk（核心 bundle 不 require）。

**浏览器端到端验收**（dev server + 真实浏览器）：构造 .emz → `install_package_bytes`
安装 → 启动器出现 → 开窗渲染；`/Desktop/demo.emz` 双击路由安装；刷新页面 →
/Applications 与编译缓存命中 → 应用自动注册；改包源码保存 → 热更新生效（v2 视图）；
卸载 → 目录/lock/命令清理。全部通过。

**实施中对本文档的定稿修正（E7 增补）**：

| # | 记录 |
|---|---|
| R8 | **contributes.commands v1 归约**：包声明的命令 v1 一律归约为「打开该应用」；命令体真正执行包内代码、菜单路径（contributes.menus）暂不消费（接线点已留） |
| R9 | **resolved_commit 推导**：浏览器端 archive 不回传 sha；从 zip 顶层目录 `<repo>-<sha>` 形态推导，推不出时以 content_sha256 固化（SPEC §5 的等价实现） |
| R10 | **浏览器端 git 导入受 GitHub CORS 限制**：codeload.github.com 的 ACAO 白名单不含任意源、api.github.com zipball 302 后仍受制于最终响应头——fetcher 注入点保留，浏览器侧需平台代理（Registry 站，v1.1+）；CLI/AgentOS 真实 clone 不受影响 |
| R11 | **Opal x-string 表达式陷阱**：单行 backtick 在含前置 return 的方法里被编译为 `return <js>`（必须是合法 JS **表达式**）；多行 %x{} 语句化、作为表达式赋值时返回值被丢弃——统一口径：需要返回值处用 IIFE 或「先声明 Ruby 局部变量、%x 语句内赋值」（json.rb/storage.rb/bytes.rb） |
| R12 | **boxed String eval 静默失败**：VFS 读出的字符串可能是 boxed JS String 对象，`(0, eval)` 对它不执行——`OpalParser.run_module` 入口强制 `String(js)` 原生化，并临时接管 `Opal.queue` 收集模块函数、同步调用（绕开 last_promise 微任务链，满足 evaluate! 同步可见契约） |
| R13 | **shell 窗口层订阅缺失**（E1 遗留暴露）：mount 时无存活实例 → `each_window_frame` 循环体不执行 → `wm.windows` 信号未被读 → 之后 launch/close 均不触发重渲染——修复为无条件先读一次 windows 信号建立订阅 |
| R14 | **beryl 上游修复②**：`MenuBar#toggle` 直接 `event[:clientX]`——`Citrine::Event` 无 `[]` 访问器，浏览器点菜单必炸（NoMethodError、静默无下拉）——改为 `event.raw[:clientX]` 并在 beryl `menu_test.rb` 加回归测试；R5 的 each_window 修复此前未实际落盘，本次补齐实现 + 回归测试 |
| R15 | **包源码字符集限制**：浏览器内 opal-parser（JS parser）解析 astral 平面字符（如 🌐 U+1F310）报语法错，BMP（中文/常用符号）不受影响；内置应用走 CRuby native parser 无此限制——**包源码须避免 emoji 字面量**（About 图标 💎→◈），SPEC 待增补 |

### 已知遗留（v1.1+ 待办）

- ~~**App 无 dispose 钩子**~~ **已解决（E7）**：`AppRegistry#dispose` 逐实例触发
  `deactivate`，Editor 的 dirty 追踪 Effect 随窗口关闭清理；Service 生命周期
  （activation 宏 + ServiceHub）就绪，内置应用向 Service/View 双子的完整迁移
  （后台任务、Worker 化）列 v1.1+。
- **beryl Tree 空 children tos `"[]"`**：beryl 既有行为（其 display_test 同样存在），
  留 beryl 侧修。
- **v1.1 清单**：桌面图标拖拽换位/框选；窗口布局持久化（D8）；⌘Space 启动器、
  ⌘S 全局保存（现由 Editor 自管）；Terminal ↑ 历史 recall（Session#history 已备好）；
  跨应用文件拖拽（Files→Editor 落下即开，依赖 citrine `render(key:)` 插槽支持 S3）；
  通知中心托盘角标点击展开历史。
- **E7 增补（v1.1+）**：包命令体真正执行包内代码（v1 归约为打开应用）+
  contributes.menus 消费；浏览器端 git 导入的平台代理（GitHub CORS 限制，R10）；
  OPFS 二进制资产（包内 assets/ 目前按 UTF-8 文本写 VFS）；多文件包
  （require 虚拟 $LOAD_PATH）；SPEC 增补 astral 字符限制条款（R15）。
- **textarea 的 StringRenderer 语义**：`value:` Signal 在 SSR 下渲染为 inspect 串
  （框架 dev-mode 警告明示），测试断信号本身，不断言 HTML 文本。

### 体积审计（E6）

`desktop.js` 3.48MB / gzip -9 后 **890KB**——超 gzip 300KB 预算。诊断：64%
（2.2MB）是 opal 默认内联 source map（packager 用 `opal -c` 未带
`--no-source-map`）。收敛方向（未实施）：packager 加 `--no-source-map`（对齐
`rake stubs` 形态）+ corelib 按需裁剪（citrine GOALS P1）；整机 OS 全量依赖后
即使去 map 预计仍超预算，E7 的 opal-parser 懒加载 chunk（D12）落地后重评预算口径。

### 工具链备忘

系统 ruby 2.6 无 bundler 2.7.2——所有命令先 `export PATH="$HOME/.rbenv/shims:$PATH"`
（rbenv ruby 3.3.5）。CI 走 ruby/setup-ruby 无此坑。


### 独立宿主与首个第三方应用（2026-09-15 追加）

| # | 记录 |
|---|---|
| R16 | **Runtime/Standalone 独立宿主落地**：`Emerald::Runtime`（服务运行时：storage→settings→vfs→notify/clipboard/router + `boot_app`，DesktopShell 改为基于它组装、行为零变化）+ `Emerald::Standalone`（独立宿主组件：满视口 + 应用视图 + Toast 堆叠，`.boot` 收类或实例）。**Emerald App 由此可在不启动桌面的情况下直接运行**——`Beryl::Renderer.mount_at('app', Emerald::Standalone.boot(SomeApp))` 即整机。`emerald.gemspec`（citrine-emerald 0.1.0）使 emerald 可被第三方仓 path 依赖 |
| R17 | **首个第三方应用 emerald-calc（科学计算器，独立仓）**：`Rational` 精确求值表达式引擎（deg/rad 三角、^、%、sqrt/ln/log/abs、π/e、50 条历史、中文错误模型）+ beryl 视图（2nd 功能切换/历史召回），55 项测试全绿；`bin/citrine package calculator ../emerald-calc/examples -I … -n EmeraldCalc` 产出独立 **EmeraldCalc.app 并启动验证通过**（不启桌面）；dev server 冒烟 200。计算器不读 ctx 任何服务——独立性的直接证明。engine 词法层十进制字面量转 Rational（`0.1+0.2=0.3` 精确）；无理运算按语义吸附（三角 1e-9 有理网格、开方完全平方回整、对数吸附最近整数） |
