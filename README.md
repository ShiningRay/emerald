# Emerald（绿宝石 · 工作名）

[Beryl](../beryl) 桌面外壳之上的**完整 Web 桌面操作系统**——壁纸、桌面图标、
菜单栏、任务栏、多窗口、应用启动器、通知、设置、文件管理与一组内置应用，
全部用 Ruby 组件书写，经 [Opal](../citrine) 编译在浏览器里运行。

```
citrine   = 内核（Signal/Effect/Component/渲染器抽象）
beryl     = 组件库 + 外壳原语（窗口框、窗口管理器、菜单、z 序、任务栏）
emerald   = 整机系统（应用框架、虚拟文件系统、设置/主题、启动器、可分发包格式）
rubyworld = 第三个真实消费者（对外应用）
```

**"OS" 是隐喻不是内核**：单用户单会话，没有多进程/权限/网络栈——
一个跑在浏览器里的 Ruby 桌面环境，外加一套源码级可分发的应用生态。

## 快速上手

```bash
# 开发（在 citrine 仓库内起 dev server，热编译）
cd citrine && bin/citrine dev ../emerald/examples -I ../beryl/lib -I ../emerald/lib
# → 打开 http://127.0.0.1:4402/desktop.html

# 测试（纯 CRuby，无需浏览器）
cd emerald && bundle exec rake test

# 编译验收 + opal-parser 独立 chunk（安装/编辑源码应用时懒加载）
cd emerald && bundle exec rake compile parser_chunk
```

依赖 `citrine`、`beryl` 均为 path 依赖（Gemfile 已配好），要求 ruby 3.x +
bundler（`.ruby-version` 已钉）。

## 架构分层

```
L6  内置应用     About · Files · Editor · Settings · Terminal
L5  系统服务     AppRegistry · VFS · SettingsStore · NotificationCenter ·
                 ShortcutRegistry · Clipboard · FileTypeRouter ·
                 Installer/AppHost/Lock · CommandRegistry · ServiceHub
L4  桌面外壳     DesktopShell（壁纸/图标网格/菜单栏/任务栏/托盘组装）
L3  桌面外壳     beryl：WindowFrame · WindowManager · Taskbar · MenuBar
L2  控件层       beryl：Menu · Select · Tabs · Dialog · Table · List · Tree
L1  原语层       beryl：drag · front · menu · hover · dblclick · wheel · scroll
L0  内核         citrine：Signal / Effect / Component / Renderer
```

依赖单向向下；系统服务与应用逻辑保持**纯 CRuby 可测**（浏览器侧只是适配层）。

## 写一个应用

```ruby
class Calculator < Emerald::App
  app_id    :calculator
  app_title '计算器'
  app_icon  '🧮'
  singleton true
  default_geometry { { x: 220, y: 140, w: 280, h: 420 } }

  state :display, default: '0'

  def view
    stack(gap: 8) do
      label { display }
      button(on_click: ->(_e) { press('1') }) { '1' }
    end
  end
end
```

## 可分发源码应用（.emz）

包内只有源码，编译产物是安装方本地可丢弃缓存（Emacs `.el` + byte-compile 模式）：

```
hello.emz
├── manifest.json      # 声明式元数据：id/version/contributes/activation/window
├── src/main.rb        # entry：定义一个 Emerald::App 子类
└── assets/            # 图标等（v1 按文本写入 VFS）
```

安装来源（统一语法；浏览器内经安装界面接收，CLI/AgentOS 端共用同一解析器）：

```bash
./hello.emz                           # 本地包（Files 双击 .emz 即安装）
./hello-dir                           # 裸目录（开发期）
git:https://github.com/u/repo#v1.2.0  # git 导入（支持 ?path= 子目录，monorepo 友好）
```

- 安装落 VFS `/Applications/<id>/`，记录固化在 `/System/installed.json`
  （git 来源固化 `resolved_commit` + 内容指纹）；编译缓存键 = 源码 sha256 + Opal 版本。
- 浏览器端安装/编辑源码应用时**按需加载** opal-parser chunk（不占核心包预算）；
  编译失败保留上一好版本继续跑 + 通知提示修复。
- 完整标准见 [docs/SPEC-package-format.md](docs/SPEC-package-format.md)。

## 文档

- [docs/PLAN.md](docs/PLAN.md) —— **唯一规划事实源**：分层架构、关键决策
  （D1–D12）、里程碑与验收、实施记录与遗留。
- [docs/SPEC-package-format.md](docs/SPEC-package-format.md) —— 包格式标准
  （Emerald / AgentOS 共用，App/Agent/Skill 三型容器）。
- [docs/SPEC-endpoint-protocol.md](docs/SPEC-endpoint-protocol.md) —— 运行时通讯协议。

## 状态

**E0–E7 全部落地**（2026-09-15）：骨架 → 最小桌面 → 应用框架 → VFS/Files/Editor →
图标/设置/主题 → 系统服务（通知/快捷键/剪贴板/终端）→ 打包 → 可分发源码应用。
测试 361 项（+ beryl 82、citrine 283），Opal 编译验收全绿；
浏览器端到端验收通过（安装 → 刷新持久 → 热更新 → 开窗渲染）。

## License

MIT（见 [LICENSE](LICENSE)）。
