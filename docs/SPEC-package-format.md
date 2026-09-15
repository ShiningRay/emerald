# SPEC：可分发包格式（.emerald package）

> 状态：v1 草案（2026-09-15）。生态级标准——Emerald / AgentOS 共用，
> 实现侧落地时若需偏离，先修订本文档。
> 关联：PLAN.md 3.9/3.10（Emerald 侧架构）、SPEC-endpoint-protocol.md（运行时通讯）。

## 1. 设计原则

1. **源码为正本**：包内只有源码与声明式元数据；任何编译产物都是安装方本地
   可丢弃缓存（Emacs `.el` + byte-compile 模式）。缓存键 = 源码 hash + 运行时版本。
2. **一种容器，三种内容**：App / Agent / Skill 共用容器与 manifest schema，
   用 `kind` 区分——安装管线、Registry、工具链只做一套。
3. **声明式优先**：能力、贡献点、激活条件全部在 manifest 声明，安装器读
   manifest 即可完成注册，不必执行包内代码。
4. **可复现**：安装记录锁定解析后的 commit 与内容 hash，同一来源同一时刻
   重装结果一致。

## 2. 容器

包 = 一个 zip 文件（扩展名 `.emz`，或裸目录用于开发与 git 导入）：

```
hello.emz
├── manifest.json      # 必需，见 §3
├── src/               # 源码（kind 语义见 §4）
├── assets/            # 图标等资源，安装后落 VFS / 数据目录
└── docs/              # 可选，README 等
```

裸目录等价于未压缩的包：开发期直接指向目录，git 导入时仓库根（或 `path`
子目录）即包目录。

## 3. manifest.json（公共 schema）

```json
{
  "spec": 1,
  "kind": "app | agent | skill",
  "id": "hello",
  "name": "Hello",
  "version": "0.1.0",
  "description": "一句话",
  "authors": ["..."],
  "homepage": "https://...",
  "min_runtime": { "emerald": ">=0.1.0", "agentos": ">=0.2.0" },
  "permissions": []
}
```

- `spec`：本标准版本号，解析器按它分流；未知 `spec` 拒绝安装。
- `id`：全小写 `[a-z][a-z0-9-]*`，安装后作为目录名、安装记录（lock）与编译
  缓存的键；同 id 重装 = 更新。（包内 App 在 App 注册表里的键是各自的 `app_id`，
  与包 id 独立，见 §4.1。）
- `version`：semver。`min_runtime` 不满足 → 拒绝并提示"应用需要更新/系统需要升级"。
- `permissions`：v1 仅占位不执行（系统无沙箱，见 PLAN 非目标），但作者必须
  如实声明意图（如 `vfs:write`、`net`），为将来强制执行与审计留数据。

## 4. 各 kind 的扩展字段

### 4.1 App（运行于 Emerald）

```json
{
  "kind": "app",
  "entry": "src/main.rb",
  "contributes": {
    "commands": [{ "id": "hello.say", "title": "问好", "hotkey": "meta+h", "app": "hello" }],
    "file_types": [".hello"],
    "menus": [{ "path": "应用/工具", "command": "hello.say" }]
  },
  "activation": { "on_command": ["hello.say"], "on_file_type": [".hello"], "on_startup": false },
  "window": { "singleton": false, "default_geometry": { "x": 120, "y": 80, "w": 560, "h": 420 } }
}
```

- `entry` 指向的源码**至少定义一个** `Emerald::App` 子类并完成 manifest 四宏中
  与 manifest.json 不冲突的部分；两者冲突时 **manifest.json 为准**（声明式优先）。
  一个包可以定义**多个** `App` 子类（例如一个桌面包同时提供总览窗、列表窗、
  收件箱），装载时全部注册；包 `id` 只作安装/卸载/缓存/更新记录的键，**不要求
  等于任何 App 的 app_id**。
- `entry` 也可定义 `Emerald::Service` 子类（无 UI 的常驻逻辑，见 §4.3 的服务
  形态约定）：宿主在安装与启动扫描时把包内 Service 子类注册进 ServiceHub，
  并按其自身的激活声明（如 `activation on_startup: true`）激活——包内不自启。
  与 App 相同，多 App 包的包 `id` 与 App 的 app_id 各自独立，命令归约见下。
- `contributes.commands[]` 每项：`id`（必备，形如 `pkg.action`）、`title`、
  可选 `hotkey`、可选 `app`——`app` 指明该命令应打开的 App（多 App 包用它把
  命令落到具体窗口）；缺省时取**包内首个已注册的 App**，包内一个 App 都没
  注册成功则该命令不接线（宿主发一条 warning，不使整体安装失败）。
- v1 只支持单文件 entry；多文件（包内 `require` 经虚拟 $LOAD_PATH）v1.1。

### 4.2 Agent（运行于 AgentOS）

Agent 包分发的是**出生证明**：初始代码版本 + 初始状态。安装后 Agent 的经验
积累走 checkpoint/记忆机制，**更新包不重置已有 Agent**，除非显式 `--reset`。

```json
{
  "kind": "agent",
  "profile": {
    "model": { "base_url": "...", "model": "...", "api_key_env": "OPENAI_API_KEY" },
    "sampling": { "temperature": 0.7 },
    "timeouts": { "open": 15, "read": 120 }
  },
  "seed": { "codebase": "seed/codebase/", "memory": "seed/memory/" },
  "skills": ["skill:bash@^1.0"]
}
```

- `profile` 参数遵守 agentos 白名单纪律：连接/身份、采样、超时三类；
  **未填的键不发送**；密钥只允许 `*_env` 引用环境变量名，包内禁止出现密钥值。
- `seed` 目录在首次安装时复制进 Agent 的数据目录，作为初始 World 代码与记忆。
- `skills` 声明依赖的 Skill 包（registry id + semver 范围），安装器递归解析。

### 4.3 Skill（工具/服务，运行于 AgentOS，Service endpoint 形态）

```json
{
  "kind": "skill",
  "entry": "src/main.rb",
  "interface": "interface.json"
}
```

- `interface.json`：JSON Schema 描述的任务输入/输出（对应 MCP tool 的
  inputSchema），供 Agent 在 prompt 中获得稳定的工具说明。
- 运行时形态 = `AgentOS::Service` 子类：固定代码处理器，协议与 Agent 一致
  （task 投递 → 同步 step → result 回投）。

## 5. 安装来源与 git 直接导入

安装器接受三类来源（统一语法，CLI 与系统内一致）：

```
emerald install ./hello.emz                     # 本地包文件
emerald install ./hello-dir                     # 本地裸目录（开发期）
emerald install git:https://github.com/u/repo#v1.2.0        # git 导入
emerald install git:https://github.com/u/repo#main?path=pkgs/hello
```

**git 导入语义**：

- `git:<URL>[#<ref>][?path=<subdir>]`。`ref` 支持分支、标签、完整 commit sha；
  缺省 = 默认分支 HEAD。`path` 支持 monorepo 子目录，缺省 = 仓库根。
- **浏览器端**（Emerald 内安装）：不实现 git 协议，走平台 archive HTTP：
  GitHub → `https://codeload.github.com/<owner>/<repo>/zip/<ref>`；
  GitLab → `https://gitlab.com/<group>/<repo>/-/archive/<ref>/<repo>-<ref>.zip`。
  私有仓库 v1 不支持（浏览器侧无凭据管理），提示改用 CLI。
- **CLI / AgentOS 端**（有真实 git）：`git clone --depth 1`；ref 为 commit sha
  时 fetch 该 sha。clone 结果即裸目录包，走同一安装管线。
- 解析后必须把 `ref` 固化为 `resolved_commit`（sha）写入安装记录——
  分支/标签是会移动的，安装结果不允许随之漂移。

**安装记录（lock）**：`installed.json`（Emerald 存 VFS `/System`，AgentOS 存
数据目录），每包一条：

```json
{
  "id": "hello", "kind": "app", "version": "0.1.0",
  "source": { "type": "git", "url": "https://github.com/u/repo",
              "ref": "v1.2.0", "resolved_commit": "abc123...",
              "content_sha256": "..." },
  "installed_at": "...", "updated_at": "..."
}
```

**更新**：`update <id>` 重新解析 ref → `resolved_commit` 无变化则跳过；
pin 到 sha 的包永不自动更新（可复现优先）。**卸载**：删除安装目录 +
lock 记录 + 注销注册表；Agent 包的 World 数据默认保留（出生证明语义），
`--purge` 才删除。

## 6.  Registry（git 索引，Homebrew tap 模式）

v1 分发平台 = 一个 git 仓库：

```
registry/
├── packages/<id>/manifest.json    # 与包内 manifest 一致（发布审核以 PR 为准）
└── packages/<id>/source.json      # { "type": "git", "url": "...", "ref": "..." }
```

`emerald install hello`（无来源前缀的裸 id）→ 查 Registry → 得 source →
走 §5 的 git 导入。索引站、签名、permissions 强制执行均为后续阶段，
不在本标准 v1 范围。

## 7. 明确不做（v1）

- 二进制/预编译产物入包（与原则 1 冲突）
- 包内脚本钩子（pre-install 等——声明式优先，拒绝任意执行）
- 依赖的自动版本求解器（skills 只支持 semver 范围 + 取已装/最新兼容，
  冲突报错给人看）
- 签名与权限强制执行（占位字段先行）
