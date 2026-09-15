# AgentOS 桌面包（阶段一：HTTP 轮询版）

把 AgentOS 运行时呈现为 EmeraldOS 桌面的一组窗口。设计文档：
`agentos/docs/emerald-desktop-ui-design-2026-09-15.md`（桌面就是 World——
Registry 里每个 Endpoint 一扇窗，Human 也是系统居民）。

## 组件

| 文件 | 组件 | 说明 |
|---|---|---|
| `src/link.rb` | `AgentOSDesk::LinkCore` | 纯 CRuby 数据内核：Observer JSON → 归一状态、POST body 生成。零 UI/零 IO，完整单测 |
| `src/link.rb` | `AgentOSDesk::LinkService < Emerald::Service` | 桌面侧唯一碰网络的组件：`activation on_startup`、运行期单例 `.instance`、9 个只读 `Citrine::Signal`。Opal 下 fetch 每 2s 轮询 + `Beryl::Timer.after` 递归重排；POST 走 `text/plain` 规避 CORS 预检（Observer 不处理 OPTIONS）。CRuby 下轮询/POST 全部 no-op |
| `src/agent_window.rb` | `AgentOSDesk::AgentWindow`（`:agentos_agent`，多实例） | 每 Agent 一扇窗：状态徽标 + mailbox 会话流（thread 分组）+ 披露层级切换 + 互动条 |
| `src/service_window.rb` | `AgentOSDesk::ServiceWindow`（`:agentos_service`，多实例） | 每 Service 一扇窗：running 状态点 + state 键值面板 + pending/processing 双栏队列 + 互动条 |
| `src/inbox_window.rb` | `AgentOSDesk::InboxWindow`（`:agentos_inbox`，单例） | Human 收件箱：卡片流 + 待回答质询橙色高亮 + 内联回答框 |
| `src/world_window.rb` | `AgentOSDesk::WorldWindow`（`:agentos_world`，单例） | World 总览（桌面自检口）：观测端在线横幅、总览/配置键值、Registry 名单 + 「开窗」按钮 |

窗口全部零 IO：只读 `LinkService.instance` 的 signal（view 内 `.get` 即订阅）；
未启动时渲染「AgentOS 连接未启动」占位，任何情况下不崩溃。

## 数据契约（Observer HTTP，锁定于 agentos `test/observer_test.rb`）

- 轮询：`/api/overview`、`/api/config`、`/api/agents`（`{'agents'=>[...]}`）、
  `/api/services`（`{'services'=>[...]}`）、`/api/human`（`pending_questions`
  是 question 的 message_id 字符串数组，需与 `cards` 按 message_id 关联归一）、
  每 endpoint `/api/mailbox?agent=X`（`{'endpoint','pending','processing'}`）。
- 写：`POST /api/messages`，body `{to, content, kind?, priority?, thread_id?,
  task_id?, in_reply_to?}`，必须 `text/plain`。
- **kind 翻译**：窗口互动条统一传 `:ask`（人话动作），而 AgentOS
  `Message::KINDS` 只有 task/question/answer/result/alert/progress/stop——
  `LinkCore#build_post_body` 把 `:ask` 翻译为 `'task'`，其余 kind 原样字符串化。
  直发 `'ask'` 会被 Observer 判 400。

## 运行（开发期路径 A：require + register）

接线在 `examples/desktop.rb`：require 包 entry → `registry.register` 四个 App →
`hub.register(LinkService)` + 幂等 `activate_startup`（桌面启动即开轮询）→
注入 launcher 桥接（World 窗口「开窗」按钮经它走 `DesktopShell#launch_app`
真正开窗；裸 `AppRegistry#launch` 只建实例不开窗，D3）。

前置：AgentOS 运行时（`ruby/bin/agentos`）已在 `127.0.0.1:4470` 监听
（`LinkService.base_url=` 可改写，须在 activate 之前）。桌面图标双击
「AgentOS 桌面」开 World 窗口；Agent/Service 窗口经 World 名单行内
「开窗」按钮或 `launch(:agentos_agent, endpoint: "agent-1")` 打开。

## 测试

```sh
# emerald/ 目录内
bundle exec ruby -Ilib examples/apps/agentos/test/agentos_desk_test.rb
```

纯 CRuby（beryl F5）：内联 fixture 直喂内核/服务，零网络零 Observer 依赖。

## 已知限制

- **.emz 懒加载路径下 entry 的 `require_relative` 不可用**。AppHost
  （`lib/emerald/pkg/apphost.rb`）装载 entry 时是「VFS 读出源码文本 →
  `OpalParser.compile`（= `Opal.compile(src)`，无 load path 上下文）→
  `run_module` eval 产物」，Opal 编译器把字面量 `require`/`require_relative`
  当静态依赖解析——包内兄弟文件不在 load path，`require_relative` 无法
  解析（calculator 参照示例的单文件 entry 即此约束的产物）。因此本包
  现仅支持开发期 require 接线；打 .emz 前须把五个组件合并为单文件
  entry，或扩展 AppHost 支持包内多文件装载。
- **多 App 包与 AppHost 的 entry 校验冲突**：`AppHost#evaluate!` 要求 entry
  声明的 `app_id` 与包 id 一致，而本包含 4 个 App（`agentos_agent` /
  `agentos_service` / `agentos_inbox` / `agentos_world`），manifest 包 id
  `agentos` 是组织名。`.emz` 安装前需放宽该校验（按 entry 定义的全部
  App 子类注册）或拆包。
- **launcher 桥接是 `examples/desktop.rb` 的开发期接线**（替换
  `services[:launcher]` 为桥接对象）：`.emz` 路径下 ctx[:launcher] 仍是
  裸 AppRegistry，World 窗口「开窗」按钮降级为「（未接线）」纯文本
  （组件内建降级，不崩溃）；`agentos.open` 命令的贡献点接线（v1 归约为
  「打开该应用」）在打包后由 shell 的 `register_contributions` 统一处理。
- 阶段一覆盖「看 + 说」（展示状态、发消息、答质询）；停止 Agent、
  启停 endpoint、改/撤回队列、快照检查点等「管」的能力待阶段二
  WebSocket 协议（见设计文档 §5）。
