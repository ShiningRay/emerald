# SPEC：Endpoint 消息协议（Emerald ↔ AgentOS）

> 状态：v1 草案（2026-09-15）。生态级标准——语言无关。AgentOS 各语言实现
> （ruby / erlang / nodejs）与 Emerald 之间的通讯契约；语义以 AgentOS Ruby
> 实现的 Endpoint/Mailbox 模型（见 agentos docs/discussion-log-2026-09-15）
> 为参照实现。
> 关联：SPEC-package-format.md（包格式）、emerald PLAN.md 3.9（Service/View）。

## 1. 定位与原则

- 本协议是 **Endpoint 之间**的消息协议：Agent、Service、Human 三类 Endpoint
  通讯上平等（权力上不平等：Human 独占 control 通道，见 §4）。
- **语义先于传输**：§2–§5 定义语言无关的消息语义，任何传输都必须完整承载；
  §6 定义 v1 的 WebSocket 传输绑定。
- 设计继承 Smalltalk/AgentOS 纪律：**mailbox 透明**——消息可枚举、可索引、
  pending 可改写，每次变更留审计。

## 2. 身份与寻址

- Endpoint 地址：`"<class>:<name>"`，如 `agent:alice`、`service:bash`、
  `human:local`。`class ∈ {agent, service, human}`。
- 路由按名（小数量假设：个位数到十几个有名有姓的 Endpoint），由运行时内的
  Registry 解析；协议层不做目录服务。
- 连接 ≠ 身份：传输连接断开重连后，同一地址的 Endpoint 语义不变
  （mailbox 是持久的一等对象，不随连接生灭）。

## 3. 消息信封

```json
{
  "proto": 1,
  "message_id": "01J…ULID",
  "thread_id": "01J…",
  "task_id": "01J…",
  "from": "human:local",
  "to": "agent:alice",
  "priority": "normal",
  "kind": "ask",
  "in_reply_to": null,
  "payload": { "text": "查询所有账户余额" },
  "sent_at": "2026-09-15T08:00:00Z"
}
```

- **三层归属**：`thread_id`（业务线索）→ `task_id`（工作单元）→
  `message_id`（一次投递）。新会话发起方生成 thread/task；同一工作单元的
  后续消息沿用既有 task_id。
- **kind**：
  - `post`：投递，无回执语义；
  - `ask`：投递并期待 `result` 回投发起方 mailbox（`in_reply_to` 指向本消息）；
  - `result`：结果回投；
  - `update` / `retract`：修改 / 撤回一条 **pending** 消息（`in_reply_to` 指向目标）；
  - `event`：状态广播（mailbox 变化、任务生命周期），订阅制，见 §6.3。
- **payload 不透明**：协议层不解释 payload；结构化程度由收发双方约定
  （Skill 包用 interface.json 的 JSON Schema 约束）。
- id 用 ULID（可排序、可生成于任何端）；时间 ISO 8601 UTC。

## 4. 优先级与投递语义

- `normal`：入 mailbox，FIFO 排队。
- `urgent`：入 mailbox，take 时优先于所有 normal。
- `control`：**绕过 mailbox**，直送 Endpoint 控制入口（stop 等）。仅
  `human:*` 地址有 control 发送权；运行时必须拒绝其他来源的 control。
- 接收确认 ≠ 处理完成：消息先入日志（post）再确认接收；
  `take` 不销毁，`ack` 才完结；处理中崩溃 → 重启后自动 `requeue` 回 pending
  （重复副作用风险按"标为待核实、不盲目重做"纪律处理）。
- `update`/`retract` 只允许针对 pending 消息；每次变更写审计日志。

## 5. 生命周期与同步应答

- 任务生命周期（task 级，经 `event` 广播）：
  `submitted → working → input-required? → completed | failed | canceled`。
  长任务允许流式部分结果（同一 task_id 的多个 `result`，末条带 `final: true`）。
- Service Endpoint 支持**同步应答**：调用方回合内 step 处理并立即回 result；
  协议形态与异步一致（都是 ask/result），时序由实现决定——
  调用方不允许假设同步性。
- Human Endpoint 的处理器是 UI：投递给 human 的消息渲染为通知/对话，
  human 的"处理结果"由其显式动作产生（回消息、点按钮），协议不区分。

## 6. WebSocket 传输绑定（v1）

### 6.1 连接

- 端点：`ws://<host>/ws`（AgentOS 运行时监听；与只读观测 HTTP 端口并存，
  观测 API 维持现状：只接受 GET、永不返回密钥值）。
- 握手：客户端首帧发 `hello`：

```json
{ "proto": 1, "type": "hello", "endpoint": "human:local", "subscribe": ["mailbox", "tasks"] }
```

  服务端回 `welcome`（含运行时版本、已注册 Endpoint 列表）或 `error` 并关闭。
  proto 不兼容 → `error { code: "unsupported_proto" }`。

### 6.2 帧

- 数据帧 = §3 信封的 JSON 序列化，一帧一条消息。
- 会话帧（不进 mailbox）：`hello` / `welcome` / `ping` / `pong` / `error`。
- 断线重传：客户端重连后发 `resume { "after": "<最后收到的 message_id>" }`，
  服务端从 mailbox 日志补发其后的、发往该地址的消息。

### 6.3 订阅

- `subscribe` 声明事件流：`mailbox`（队列变更）、`tasks`（生命周期）、
  `endpoints`（注册表变更）。事件以 `kind: "event"` 帧下发，
  `payload.type` 区分细类。
- Emerald 的桌面壳与 App Service 层共用一个 `human:local` 连接；
  每条连接声明一个身份，多窗口共享身份不额外占地址。

### 6.4 安全（v1 明示边界）

- 监听仅绑 `127.0.0.1`；无认证（单用户单机假设，与"OS 是隐喻"非目标一致）。
- 暴露到非 loopback 之前必须先定义认证与 control 通道的鉴权——
  属于 v2 议题，届时修订本文档。

## 7. 版本与扩展

- `proto` 字段单调递增；新增信封字段必须可选（旧实现忽略未知字段）；
  破坏性变更升 `proto` 并在 hello 握手期拒绝。
- 新增 `kind` / `priority` 属于破坏性变更；新增 `payload` 结构、
  `subscribe` 类别属于兼容扩展。
