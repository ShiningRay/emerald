# frozen_string_literal: true

# AgentOS 桌面包单测（阶段一 · HTTP 轮询版）：LinkCore 数据归一 + build_post_body、
# LinkService 生命周期/只读 signal/CRuby 零轮询，四个窗口 App 的 manifest 与渲染冒烟。
# 纯 CRuby（beryl F5）：不启动 Observer、不发起任何真实 HTTP，数据全部内联 fixture。
# 运行（emerald/ 目录内，集成阶段统一跑，勿单独提前跑——其余 src 文件由并行开发补齐）：
#   bundle exec ruby -Ilib examples/apps/agentos/test/agentos_desk_test.rb
#
# 本文件同时是并行开发的对接规格（src/link.rb 与四个窗口文件须遵守的约定）：
# - AgentOSDesk::LinkCore.new 无参；读口：agents/services/mailboxes/cards/
#   pending_questions/overview/config/offline/last_error；ingest_* 方法吃 Observer
#   原始 envelope（string 键：'agents'/'services'/'endpoint'/'pending'/'processing'/
#   'cards'/'pending_questions'，HTTP 契约锁定于 agentos ruby/test/observer_test.rb）。
# - LinkCore#build_post_body(to:, content:, kind: :ask, priority: :normal,
#   thread_id: nil, task_id: nil, in_reply_to: nil) → JSON 字符串。
# - AgentOSDesk::LinkService < Emerald::Service：activation on_startup: true；
#   activate(ctx) 设 LinkService.instance（deactivate 清 nil）；同名 ingest_* 薄委托
#   LinkCore 并同步对应 Citrine::Signal——读口是只读 signal，经 #get 取值；
#   CRuby 下轮询与 POST 一律不启动（no-op，IO 仅在 defined?(Opal) 的适配层）。
# - 窗口 App：AgentWindow/ServiceWindow 经 argv = { endpoint: '<name>' } 指定实例
#   （attr_accessor 直写）；LinkService.instance 为 nil 时渲染固定占位文案
#   「AgentOS 连接未启动」，不得崩溃、不得要求先 boot。
require 'minitest/autorun'
require 'emerald'
require 'json'
require_relative '../src/link'
require_relative '../src/agent_window'
require_relative '../src/service_window'
require_relative '../src/inbox_window'
require_relative '../src/world_window'

# 内联 fixture：模拟 Observer 各端点的真实返回形状（string 键 envelope）。
# pending_questions 在真实 API 里是 message_id 字符串数组，卡片里才有完整消息。
module AgentOSDeskFixture
  AGENTS = {
    'agents' => [
      { 'name' => 'agent-1', 'driver' => 'anthropic', 'model' => 'claude-sonnet-4',
        'last_status' => 'completed', 'mailbox_pending' => 2, 'mailbox_processing' => 1 },
      { 'name' => 'agent-2', 'driver' => 'scripted', 'model' => nil,
        'last_status' => nil, 'mailbox_pending' => 0, 'mailbox_processing' => 0 },
      # 字符串计数：归一须转 Integer（类型转换锁）
      { 'name' => 'agent-3', 'driver' => 'scripted', 'model' => nil,
        'last_status' => 'running', 'mailbox_pending' => '3', 'mailbox_processing' => '0' }
    ]
  }.freeze

  SERVICES = {
    'services' => [
      { 'name' => 'bash', 'running' => true,
        'state' => { 'commands_run' => 3, 'last_error' => nil },
        'mailbox_pending' => 1, 'mailbox_processing' => 0 },
      # 'false' 是 truthy 字符串：归一须转成 false（running 类型转换锁）
      { 'name' => 'cron', 'running' => 'false', 'state' => {},
        'mailbox_pending' => '0', 'mailbox_processing' => 2 }
    ]
  }.freeze

  MSG_TASK = {
    'message_id' => 'msg-1', 'from' => 'user', 'to' => 'agent-1',
    'thread_id' => 't-1', 'task_id' => 'task-1', 'in_reply_to' => nil,
    'kind' => 'task', 'content' => '待办任务', 'priority' => 'normal',
    'created_at' => '2026-09-15T10:00:00Z'
  }.freeze

  MSG_QUESTION = {
    'message_id' => 'msg-q1', 'from' => 'agent-1', 'to' => 'user',
    'thread_id' => 'ui', 'task_id' => 'task-1', 'in_reply_to' => nil,
    'kind' => 'question', 'content' => '选 A 还是 B？', 'priority' => 'urgent',
    'created_at' => '2026-09-15T10:05:00Z'
  }.freeze

  MAILBOX_AGENT = {
    'endpoint' => 'agent-1', 'pending' => [MSG_TASK], 'processing' => []
  }.freeze

  MAILBOX_SERVICE = {
    'endpoint' => 'bash', 'pending' => [], 'processing' => [MSG_QUESTION]
  }.freeze

  HUMAN = {
    'name' => 'user',
    'cards' => [
      MSG_QUESTION.merge('icon' => '❓'),
      { 'message_id' => 'msg-i1', 'from' => 'agent-1', 'to' => 'user',
        'thread_id' => 'ui', 'task_id' => 'task-1', 'in_reply_to' => nil,
        'kind' => 'info', 'content' => '任务已完成', 'priority' => 'normal',
        'created_at' => '2026-09-15T10:06:00Z', 'icon' => '✅' }
    ],
    # 'msg-ghost' 无对应卡片：归一后仍须保留该质询，from 给 nil（契约保证 'id'/'from' 键）
    'pending_questions' => %w[msg-q1 msg-ghost]
  }.freeze

  OVERVIEW = {
    'version' => '1.2.3', 'data_dir' => '/tmp/agentos-data',
    'checkpoint' => 'cp-2026', 'git_commit' => 'abc1234',
    'history_events' => 42, 'mailbox_recovered' => false,
    'agents' => %w[agent-1 agent-2 agent-3], 'services' => %w[bash cron]
  }.freeze

  CONFIG = {
    'driver' => 'anthropic', 'model' => 'claude-sonnet-4',
    'base_url' => 'https://api.anthropic.com', 'api_key_env' => 'ANTHROPIC_API_KEY',
    'api_key_set' => true, 'max_steps' => 40,
    'version' => '1.2.3', 'ruby' => '3.4.0', 'data_dir' => '/tmp/agentos-data'
  }.freeze

  # 把全套 fixture 喂给 LinkCore 或 LinkService（同名 ingest 薄委托走同一条路径）
  def feed_all(link)
    link.ingest_agents(AGENTS)
    link.ingest_services(SERVICES)
    link.ingest_mailbox(MAILBOX_AGENT)
    link.ingest_mailbox(MAILBOX_SERVICE)
    link.ingest_human(HUMAN)
    link.ingest_overview(OVERVIEW)
    link.ingest_config(CONFIG)
  end
end

# ── LinkCore：纯逻辑内核的归一化 ─────────────────────────────────────
class LinkCoreTest < Minitest::Test
  include AgentOSDeskFixture

  def setup
    @core = AgentOSDesk::LinkCore.new
  end

  def test_default_state
    assert_equal [], @core.agents
    assert_equal [], @core.services
    assert_equal({}, @core.mailboxes)
    assert_equal [], @core.cards
    assert_equal [], @core.pending_questions
    assert_nil @core.last_error
    assert_includes [true, false], @core.offline
  end

  def test_ingest_agents_normalizes_symbol_keys_and_types
    @core.ingest_agents(AGENTS)
    a1, a2, a3 = @core.agents
    [a1, a2, a3].each do |a|
      assert_equal %i[driver last_status mailbox_pending mailbox_processing model name],
                   a.keys.sort
    end
    assert_equal 'agent-1', a1[:name]
    assert_equal 'anthropic', a1[:driver]
    assert_equal 'claude-sonnet-4', a1[:model]
    assert_equal :completed, a1[:last_status] # 字符串 → Symbol
    assert_equal 2, a1[:mailbox_pending]
    assert_equal 1, a1[:mailbox_processing]
    assert_nil a2[:last_status]                # nil 容忍
    assert_equal :running, a3[:last_status]
    assert_kind_of Integer, a3[:mailbox_pending]   # '3' → 3
    assert_equal 3, a3[:mailbox_pending]
    assert_equal 0, a3[:mailbox_processing]
  end

  def test_ingest_services_normalizes_running_and_counts
    @core.ingest_services(SERVICES)
    bash, cron = @core.services
    [bash, cron].each do |s|
      assert_equal %i[mailbox_pending mailbox_processing name running state], s.keys.sort
    end
    assert_equal true, bash[:running]
    assert_equal({ 'commands_run' => 3, 'last_error' => nil }, bash[:state])
    assert_equal false, cron[:running] # 'false' 字符串 → false
    assert_equal 1, bash[:mailbox_pending]
    assert_kind_of Integer, cron[:mailbox_pending] # '0' → 0
    assert_equal 2, cron[:mailbox_processing]
  end

  def test_ingest_mailbox_buckets_by_endpoint
    @core.ingest_mailbox(MAILBOX_AGENT)
    @core.ingest_mailbox(MAILBOX_SERVICE)
    mbs = @core.mailboxes
    assert_equal %w[agent-1 bash], mbs.keys.sort        # 外层 endpoint 字符串键
    assert_equal [MSG_TASK], mbs['agent-1'][:pending]   # 内层 symbol 键
    assert_equal [], mbs['agent-1'][:processing]
    assert_equal [], mbs['bash'][:pending]
    assert_equal [MSG_QUESTION], mbs['bash'][:processing]
    # msg 保持 string 键原样透传
    assert_equal '待办任务', mbs['agent-1'][:pending].first['content']
  end

  def test_ingest_human_passthrough_cards_and_normalizes_questions
    @core.ingest_human(HUMAN)
    assert_equal AgentOSDeskFixture::HUMAN['cards'], @core.cards # 透传
    by_id = @core.pending_questions.to_h { |q| [q['id'], q] }
    assert_equal %w[msg-ghost msg-q1], by_id.keys.sort
    assert_equal 'agent-1', by_id['msg-q1']['from'] # 从卡片查到 from
    assert_nil by_id['msg-ghost']['from']           # 卡片缺失也不丢质询
  end

  def test_ingest_overview_and_config_pick_contract_keys
    @core.ingest_overview(OVERVIEW)
    ov = @core.overview
    %i[version data_dir checkpoint git_commit history_events mailbox_recovered]
      .each { |k| assert ov.key?(k), "overview 缺键 #{k}" }
    assert_equal '1.2.3', ov[:version]
    assert_equal 'abc1234', ov[:git_commit]
    assert_kind_of Integer, ov[:history_events]
    assert_equal false, ov[:mailbox_recovered]

    @core.ingest_config(CONFIG)
    cfg = @core.config
    %i[driver model base_url api_key_env api_key_set max_steps]
      .each { |k| assert cfg.key?(k), "config 缺键 #{k}" }
    assert_equal 'anthropic', cfg[:driver]
    assert_equal 'ANTHROPIC_API_KEY', cfg[:api_key_env]
    assert_equal true, cfg[:api_key_set]
    assert_kind_of Integer, cfg[:max_steps]
    assert_equal 40, cfg[:max_steps]
  end

  def test_build_post_body_roundtrips_with_defaults
    parsed = JSON.parse(@core.build_post_body(to: 'agent-1', content: '帮我看看日志'))
    assert_equal 'agent-1', parsed['to']
    assert_equal '帮我看看日志', parsed['content']
    # 人话动作 :ask 翻译为 Observer 线格式 'task'（Message::KINDS 无 :ask）
    assert_equal 'task', parsed['kind']
    assert_equal 'normal', parsed['priority']
  end

  def test_build_post_body_carries_optional_envelope_fields
    parsed = JSON.parse(@core.build_post_body(to: 'agent-1', content: '选 A',
                                              kind: :answer, priority: :urgent,
                                              thread_id: 'ui', task_id: 'task-1',
                                              in_reply_to: 'msg-q1'))
    assert_equal 'answer', parsed['kind']
    assert_equal 'urgent', parsed['priority']
    assert_equal 'ui', parsed['thread_id']
    assert_equal 'task-1', parsed['task_id']
    assert_equal 'msg-q1', parsed['in_reply_to']
  end
end

# ── LinkService：生命周期、单例、只读 signal、CRuby 零轮询 ──────────
class LinkServiceTest < Minitest::Test
  include AgentOSDeskFixture

  def teardown
    AgentOSDesk::LinkService.instance&.deactivate
  end

  def test_activation_declared_on_startup
    assert_operator AgentOSDesk::LinkService, :<, Emerald::Service
    assert_equal true, AgentOSDesk::LinkService.activation_events[:startup]
  end

  def test_activate_sets_instance_and_deactivate_clears
    assert_nil AgentOSDesk::LinkService.instance
    service = AgentOSDesk::LinkService.new
    assert_same service, service.activate({})
    assert_same service, AgentOSDesk::LinkService.instance
    service.deactivate
    assert_nil AgentOSDesk::LinkService.instance
    refute service.activated?
  end

  def test_signals_reflect_ingested_fixtures
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)

    agents = service.agents.get
    assert_equal 3, agents.size
    assert_equal :completed, agents.first[:last_status]

    bash, = service.services.get
    assert_equal 'bash', bash[:name]
    assert_equal true, bash[:running]

    mailboxes = service.mailboxes.get
    assert_equal '待办任务', mailboxes['agent-1'][:pending].first['content']

    assert_equal AgentOSDeskFixture::HUMAN['cards'], service.cards.get
    q, = service.pending_questions.get
    assert_equal 'msg-q1', q['id']
    assert_equal 'agent-1', q['from']

    assert_equal 42, service.overview.get[:history_events]
    assert_equal false, service.overview.get[:mailbox_recovered]
    assert_equal 40, service.config.get[:max_steps]
    assert_equal true, service.config.get[:api_key_set]
    assert_includes [true, false], service.offline.get
    assert_nil service.last_error.get
  end

  def test_signals_are_read_only
    service = AgentOSDesk::LinkService.new
    service.activate({})
    %i[agents services mailboxes cards pending_questions overview config offline last_error]
      .each do |name|
        assert_kind_of Citrine::Signal, service.public_send(name)
        refute service.respond_to?(:"#{name}="), "#{name} 必须是只读 signal"
      end
  end

  def test_cruby_never_starts_polling_or_post
    threads_before = Thread.list
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)
    # 动作方法在 CRuby 下可安全调用（no-op，不发 IO）
    service.send_message(to: 'agent-1', content: 'hi')
    service.answer_question('msg-q1', '选 A')
    service.deactivate
    assert_equal threads_before, Thread.list, 'CRuby 下不得启动轮询线程/定时器'
  end
end

# ── 四个窗口 App：manifest 宏 + 渲染冒烟 ────────────────────────────
class AgentOSDeskWindowsTest < Minitest::Test
  include AgentOSDeskFixture

  WINDOW_CLASSES = [
    AgentOSDesk::AgentWindow, AgentOSDesk::ServiceWindow,
    AgentOSDesk::InboxWindow, AgentOSDesk::WorldWindow
  ].freeze

  PLACEHOLDER = 'AgentOS 连接未启动'

  def teardown
    AgentOSDesk::LinkService.instance&.deactivate
  end

  def test_agent_window_manifest
    k = AgentOSDesk::AgentWindow
    assert_equal :agentos_agent, k.app_id
    assert_equal 'Agent', k.app_title
    assert_equal '🤖', k.app_icon
    assert_equal false, k.singleton
    assert_equal({ x: 80, y: 60, w: 540, h: 580 }, k.default_geometry.call)
  end

  def test_service_window_manifest
    k = AgentOSDesk::ServiceWindow
    assert_equal :agentos_service, k.app_id
    assert_equal 'Service', k.app_title
    assert_equal '⚙️', k.app_icon
    assert_equal false, k.singleton
    assert_equal({ x: 140, y: 100, w: 480, h: 460 }, k.default_geometry.call)
  end

  def test_inbox_window_manifest
    k = AgentOSDesk::InboxWindow
    assert_equal :agentos_inbox, k.app_id
    assert_equal '收件箱', k.app_title
    assert_equal '📥', k.app_icon
    assert_equal true, k.singleton
    assert_equal({ x: 200, y: 120, w: 500, h: 540 }, k.default_geometry.call)
  end

  def test_world_window_manifest
    k = AgentOSDesk::WorldWindow
    assert_equal :agentos_world, k.app_id
    assert_equal 'AgentOS', k.app_title
    assert_equal '🌐', k.app_icon
    assert_equal true, k.singleton
    assert_equal({ x: 60, y: 40, w: 560, h: 620 }, k.default_geometry.call)
  end

  def test_placeholder_rendering_without_link
    assert_nil AgentOSDesk::LinkService.instance
    WINDOW_CLASSES.each do |klass|
      html = Citrine.render(klass.new)
      assert_includes html, PLACEHOLDER, "#{klass} 未渲染占位文案"
    end
  end

  def test_agent_window_renders_endpoint_and_status
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)
    inst = AgentOSDesk::AgentWindow.new
    inst.argv = { endpoint: 'agent-1' } # attr_accessor 直写启动参数
    html = Citrine.render(inst)
    assert_includes html, 'agent-1'
    assert_includes html, 'completed'
    refute_includes html, PLACEHOLDER
  end

  def test_service_window_renders_endpoint_and_status
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)
    inst = AgentOSDesk::ServiceWindow.new
    inst.argv = { endpoint: 'bash' }
    html = Citrine.render(inst)
    assert_includes html, 'bash'
    assert_includes html, 'running'
    refute_includes html, PLACEHOLDER
  end

  def test_inbox_window_renders_cards_and_questions
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)
    html = Citrine.render(AgentOSDesk::InboxWindow.new)
    assert_includes html, '待回答质询（2）' # 质询区（含无卡片兜底项）
    assert_includes html, '选 A 还是 B？'    # 质询正文（与 cards 关联归一取得）
    assert_includes html, '卡片流（2）'
  end

  def test_world_window_renders_overview
    service = AgentOSDesk::LinkService.new
    service.activate({})
    feed_all(service)
    html = Citrine.render(AgentOSDesk::WorldWindow.new)
    assert_includes html, '1.2.3'     # version
    assert_includes html, 'abc1234'   # git_commit
  end
end
