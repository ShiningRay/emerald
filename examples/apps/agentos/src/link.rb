# backtick_javascript: true
# frozen_string_literal: true

# AgentOS 桌面连线（阶段一：HTTP 轮询版）—— AgentOSDesk::LinkService < Emerald::Service。
# 桌面侧唯一碰网络的组件：Opal fetch 每 2s 轮询 AgentOS Observer，结果经
# AgentOSDesk::LinkCore（纯 CRuby 内核）归一化后写入 Citrine::Signal；
# 四个窗口 App 只读 signal（`LinkService.instance.agents.get`，view 块内 .get 即订阅）。
# entry 在运行时已加载（require 'emerald' 完成）的前提下求值，自身不 require
# （opal -c 会把字面量 require 当静态依赖）。
#
# 已确认的数据源形状（来源：agentos ruby/lib/agentos/observer.rb +
# test/observer_test.rb @ 2026-09-15）：
#   GET /api/overview   → { 'version','data_dir','checkpoint','git_commit',
#                           'history_events','mailbox_recovered', ... }（后附 agents/services 名单，忽略）
#   GET /api/config     → { 'driver','model','base_url','api_key_env','api_key_set',
#                           'max_steps','version','ruby','data_dir' }
#   GET /api/agents     → { 'agents' => [{ 'name','driver','model','last_status',
#                           'mailbox_pending','mailbox_processing' }] }（设计文档写裸数组，实测包一层，两种都收）
#   GET /api/services   → { 'services' => [{ 'name','running','state','mailbox_pending',
#                           'mailbox_processing' }] }（state 值已 inspect 截断为 String）
#   GET /api/mailbox?agent=X → { 'endpoint','pending' => [msg], 'processing' => [msg] }
#   GET /api/human      → { 'name','cards','pending_questions' }
#       cards 元素（observer.rb 对值全体 to_s）：{ 'message_id','kind','icon','title',
#       'body','from','thread_id','task_id','at' }；pending_questions 是 question 的
#       message_id 字符串数组——'from' 需与 cards 按 message_id 关联取得（本内核的归一职责）。
#   POST /api/messages  → body { 'to'（必填非空）,'content','kind?','thread_id?','task_id?',
#                           'priority?','in_reply_to?' }；必须以 text/plain 发送以规避 CORS 预检
#                           （Observer 不处理 OPTIONS）。
#       kind='answer' 时 Observer 交给 Human#answer：实际回复给 question.from、沿用原
#       thread_id/task_id，in_reply_to = 被回答问题的 message_id（to 仅校验非空、不用于路由）。
#
# 信号合同（与并行开发共用，键型严格一致）：
#   agents/services/overview/config —— symbol 键 Hash；mailboxes —— String endpoint 键，
#   内层 :pending/:processing 为 symbol 键；mailbox msg 与 pending_questions 元素 —— string 键。
module AgentOSDesk
  # 纯 CRuby 数据内核：Observer JSON Hash → 内核状态，及 POST body 生成。
  # 零 UI、零 IO、零 Opal，可完整单测。所有 ingest_* 接受 string/symbol 键的
  # 原始 Hash（JSON.parse / 测试夹具均可直喂），缺字段一律防御默认值。
  class LinkCore
    # /api/mailbox 消息的确切键集（AgentOS::Message#to_h，observer_test 锁定）
    MESSAGE_KEYS = %w[message_id from to thread_id task_id in_reply_to kind content
                      priority created_at].freeze

    attr_reader :human_name
    # 对接规格读口（test/agentos_desk_test.rb 头部锁定）：直查内核归一状态，
    # 与 snapshot 同源；signal 同步仍只走 LinkService#sync_signals。
    attr_reader :agents, :services, :mailboxes, :cards, :pending_questions,
                :overview, :config, :offline, :last_error

    def initialize
      clear
    end

    # ── 归一入口 ─────────────────────────────────────────

    def ingest_overview(data)
      data = pick_hash(data)
      @overview = {
        version: pick(data, 'version'),
        data_dir: pick(data, 'data_dir'),
        checkpoint: pick(data, 'checkpoint'),
        git_commit: pick(data, 'git_commit'),
        history_events: to_int(pick(data, 'history_events')),
        mailbox_recovered: pick(data, 'mailbox_recovered') == true
      }
      self
    end

    def ingest_config(data)
      data = pick_hash(data)
      @config = {
        driver: pick(data, 'driver'),
        model: pick(data, 'model'),
        base_url: pick(data, 'base_url'),
        api_key_env: pick(data, 'api_key_env'),
        api_key_set: pick(data, 'api_key_set') == true,
        max_steps: to_int(pick(data, 'max_steps'))
      }
      self
    end

    def ingest_agents(payload)
      @agents = unwrap(payload, 'agents').map { |a| normalize_agent(a) }
      prune_mailboxes!
      self
    end

    def ingest_services(payload)
      @services = unwrap(payload, 'services').map { |s| normalize_service(s) }
      prune_mailboxes!
      self
    end

    # /api/human（调用即 drain）：cards 透传存储（元素为不透明 string 键 Hash，
    # 渲染方防御未知/缺失字段）；pending_questions 归一为保证含 'id'/'from' 的
    # string 键 Hash（'from' 与 cards 按 message_id 关联；卡片缺失时尽力而为）。
    def ingest_human(data)
      data = pick_hash(data)
      @human_name = pick(data, 'name')
      cards = pick(data, 'cards')
      @cards = cards.is_a?(Array) ? cards.dup : []
      raw = pick(data, 'pending_questions')
      @pending_questions = normalize_pending_questions(raw.is_a?(Array) ? raw : [])
      self
    end

    # /api/mailbox?agent=<name>：按响应 'endpoint' 落键（缺省退回参数 name）。
    # 单参调用（name 缺省）时第一参数即信封本身——endpoint 取自信封；
    # msg 逐个归一为 MESSAGE_KEYS 的 string 键 Hash（值原样保留）。
    def ingest_mailbox(data, name = nil)
      data = pick_hash(data)
      endpoint = pick(data, 'endpoint').to_s
      endpoint = name.to_s if endpoint.empty?
      pending = pick(data, 'pending')
      processing = pick(data, 'processing')
      @mailboxes[endpoint] = {
        pending: (pending.is_a?(Array) ? pending : []).map { |m| normalize_message(m) },
        processing: (processing.is_a?(Array) ? processing : []).map { |m| normalize_message(m) }
      }
      self
    end

    # ── 连接状态（由 Service 侧轮询结果驱动）──────────────

    def mark_online
      @offline = false
      @last_error = nil
      self
    end

    def mark_offline(error)
      @offline = true
      @last_error = error.to_s
      self
    end

    # ── 查询 ────────────────────────────────────────────

    # 已知 endpoint 名单（agents + services 的 name）——轮询 mailbox 的名单。
    def endpoint_names
      (@agents + @services).map { |e| e[:name].to_s }.uniq
    end

    # 按 id 查待回答质询（answer_question 用来解析发问人）；=> Hash 或 nil。
    def pending_question(id)
      @pending_questions.find { |q| q['id'] == id.to_s }
    end

    # POST /api/messages 的 JSON body：to/content 恒在，其余仅在非 nil 时写入。
    # kind/priority 缺省即人话动作 :ask/:normal；:ask 在 post_kind 翻译为线
    # 格式 'task'（Observer 的 Message::KINDS 不认 :ask，直发会被判 400）。
    def build_post_body(to:, content:, kind: :ask, priority: :normal, thread_id: nil,
                         task_id: nil, in_reply_to: nil)
      body = { 'to' => to.to_s, 'content' => content.to_s }
      body['kind'] = post_kind(kind) unless kind.nil?
      body['priority'] = priority.to_s unless priority.nil?
      body['thread_id'] = thread_id.to_s unless thread_id.nil?
      body['task_id'] = task_id.to_s unless task_id.nil?
      body['in_reply_to'] = in_reply_to.to_s unless in_reply_to.nil?
      Emerald::Pkg::Json.generate(body)
    end

    # 内核状态只读快照：{ agents:, services:, mailboxes:, cards:, pending_questions:,
    # overview:, config:, offline:, last_error: }。顶层 mailboxes 为浅拷贝（防外部
    # 改穿容器）；内层结构与 signal 共享——消费方（窗口 view）只读。
    def snapshot
      {
        agents: @agents, services: @services, mailboxes: @mailboxes.dup,
        cards: @cards, pending_questions: @pending_questions,
        overview: @overview, config: @config,
        offline: @offline, last_error: @last_error
      }
    end

    private

    def clear
      @agents = []
      @services = []
      @mailboxes = {}
      @cards = []
      @pending_questions = []
      @overview = {}
      @config = {}
      @human_name = nil
      @offline = true   # 尚未成功建立过连接即视为离线
      @last_error = nil
    end

    # symbol / string 键兼容取值（JSON.parse 产 string 键，测试夹具常用 symbol 键）
    def pick(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def pick_hash(data)
      data.is_a?(Hash) ? data : {}
    end

    # 实测 API 把列表包在 key 里（{ 'agents' => [...] }）；合同文档另有裸数组写法，两种都收。
    def unwrap(payload, key)
      list = pick(payload, key) if payload.is_a?(Hash)
      list = payload if list.nil? && payload.is_a?(Array)
      list.is_a?(Array) ? list : []
    end

    def normalize_agent(raw)
      raw = pick_hash(raw)
      status = pick(raw, 'last_status')
      {
        name: pick(raw, 'name').to_s,
        driver: pick(raw, 'driver'),
        model: pick(raw, 'model'),
        last_status: status.nil? || status.to_s.empty? ? nil : status.to_s.to_sym,
        mailbox_pending: to_int(pick(raw, 'mailbox_pending')),
        mailbox_processing: to_int(pick(raw, 'mailbox_processing'))
      }
    end

    def normalize_service(raw)
      raw = pick_hash(raw)
      state = pick(raw, 'state')
      {
        name: pick(raw, 'name').to_s,
        running: pick(raw, 'running') == true,
        state: state.is_a?(Hash) ? state : {},
        mailbox_pending: to_int(pick(raw, 'mailbox_pending')),
        mailbox_processing: to_int(pick(raw, 'mailbox_processing'))
      }
    end

    def normalize_message(raw)
      raw = pick_hash(raw)
      MESSAGE_KEYS.to_h { |k| [k, pick(raw, k)] }
    end

    # pending_questions 归一：API 给的是 question message_id 数组（observer_test 锁定），
    # 防御 Hash 元素（'id'/'message_id'）。保证每个元素含 string 键 'id' 与 'from'；
    # 其余字段（content/thread_id/task_id/at）仅在对应卡片存在时带上，渲染方防御缺失。
    def normalize_pending_questions(list)
      list.map do |item|
        id = item.is_a?(Hash) ? (pick(item, 'id') || pick(item, 'message_id')).to_s : item.to_s
        card = @cards.find { |c| c.is_a?(Hash) && (pick(c, 'message_id') || '').to_s == id }
        from = card_value(card, 'from') || (item.is_a?(Hash) ? pick(item, 'from') : nil)
        # 'from' 键恒在、值可 nil（卡片缺失的质询无发问人可查；消费方 to_s 兜底）
        q = { 'id' => id, 'from' => from }
        %w[thread_id task_id].each do |k|
          v = card_value(card, k)
          q[k] = v unless v.nil?
        end
        body = card_value(card, 'body') || card_value(card, 'content')
        q['content'] = body unless body.nil?
        # 时间键两种形状都收：Observer 人话卡片用 'at'，原始 Message 用 'created_at'
        at = card_value(card, 'at') || card_value(card, 'created_at')
        q['at'] = at unless at.nil?
        q
      end
    end

    def card_value(card, key)
      card.is_a?(Hash) ? pick(card, key) : nil
    end

    # 人话动作 → Observer 线格式：窗口互动条统一传 :ask，而 AgentOS
    # Message::KINDS 只有 task/question/answer/result/alert/progress/stop——
    # :ask 翻译为 'task'，其余 kind 原样字符串化。
    def post_kind(kind)
      kind.respond_to?(:to_sym) && kind.to_sym == :ask ? 'task' : kind.to_s
    end

    # 消失的 endpoint 其 mailbox 一并清掉（名单取当前 agents+services）；
    # 轮询顺序 agents → services → mailboxes，同轮内先清后拉，无空窗。
    def prune_mailboxes!
      known = endpoint_names
      @mailboxes.delete_if { |endpoint, _| !known.include?(endpoint) }
    end

    def to_int(v)
      v.respond_to?(:to_i) ? v.to_i : 0   # nil.to_i = 0；"3"→3；防御非数值
    end
  end

  # AgentOS 连线服务：activation on_startup；运行期单例（activate 登记、
  # deactivate 清除——窗口一律经 LinkService.instance 读，instance 为 nil 时
  # 由窗口渲染"AgentOS 连接未启动"占位，与本服务无耦合）。
  class LinkService < Emerald::Service
    activation on_startup: true

    # 数据源：AgentOS Observer 默认地址（PLAN：可配置常量）；集成阶段可在
    # activate 前改写 LinkService.base_url（activate 时快照进实例）。
    DEFAULT_BASE_URL = 'http://127.0.0.1:4470'
    # 轮询间隔（毫秒）
    POLL_INTERVAL_MS = 2000

    class << self
      # 运行期单例：窗口 App 的数据入口。
      attr_accessor :instance

      attr_writer :base_url

      def base_url
        @base_url ||= DEFAULT_BASE_URL
      end
    end

    # 只读 signal（Citrine::Signal）：窗口经 LinkService.instance.<name>.get 读，
    # view 块内 .get 即建立订阅、数据更新自动重渲染；写入只归本服务。
    attr_reader :agents, :services, :mailboxes, :cards, :pending_questions,
                :overview, :config, :offline, :last_error, :core

    def initialize(core: LinkCore.new)
      @core = core
      @agents = Citrine::Signal.new([])
      @services = Citrine::Signal.new([])
      @mailboxes = Citrine::Signal.new({})
      @cards = Citrine::Signal.new([])
      @pending_questions = Citrine::Signal.new([])
      @overview = Citrine::Signal.new({})
      @config = Citrine::Signal.new({})
      @offline = Citrine::Signal.new(true)
      @last_error = Citrine::Signal.new(nil)
      @polling = false
      @timer = nil
    end

    def activate(ctx)
      super
      @base_url = self.class.base_url
      self.class.instance = self
      start_polling if defined?(Opal)
      self
    end

    def deactivate
      stop_polling if defined?(Opal)
      self.class.instance = nil if self.class.instance.equal?(self)
      super
    end

    # 发消息：POST /api/messages（to 为目标 endpoint 名；kind/priority 缺省
    # :ask/:normal——:ask 在 build_post_body 翻译为线格式 'task'，窗口按需
    # 显式传 question/stop 等其余 kind）。
    def send_message(to:, content:, kind: :ask, priority: :normal,
                     thread_id: nil, task_id: nil, in_reply_to: nil)
      post_body @core.build_post_body(to: to, content: content, kind: kind,
                                      priority: priority, thread_id: thread_id,
                                      task_id: task_id, in_reply_to: in_reply_to)
    end

    # 回答质询：沿 Observer 的 answer 通路——in_reply_to 指向问题 id，to 取其
    # 发问人（Human#answer 按 in_reply_to 找回原问题，to 仅校验非空、不用于路由；
    # 本内核已查不到该问题时退化为 'user'，由 Observer 侧再判 400）。
    def answer_question(question_id, content)
      from = @core.pending_question(question_id)&.dig('from').to_s
      send_message(to: from.empty? ? 'user' : from, content: content,
                   kind: :answer, in_reply_to: question_id)
    end

    # ── 同名 ingest 薄委托（对接规格：宿主/测试可直接喂 Observer envelope
    #    驱动 signal，与轮询生产路径同一条归一链路）。每个委托同步一次 signal；
    # 生产轮询不走这里（ingest_response 直喂内核、poll_finished 统一 sync）。

    def ingest_overview(data)
      @core.ingest_overview(data)
      sync_signals
    end

    def ingest_config(data)
      @core.ingest_config(data)
      sync_signals
    end

    def ingest_agents(payload)
      @core.ingest_agents(payload)
      sync_signals
    end

    def ingest_services(payload)
      @core.ingest_services(payload)
      sync_signals
    end

    def ingest_human(data)
      @core.ingest_human(data)
      sync_signals
    end

    def ingest_mailbox(data, name = nil)
      @core.ingest_mailbox(data, name)
      sync_signals
    end

    # 内核 → signal 全量同步。轮询每轮收尾调用；公开以便 CRuby 测试在直接喂内核后
    # 驱动 signal（生产写入路径仍只在本服务内）。
    def sync_signals
      snap = @core.snapshot
      Citrine::Scheduler.batch do
        @agents.set(snap[:agents])
        @services.set(snap[:services])
        @mailboxes.set(snap[:mailboxes])
        @cards.set(snap[:cards])
        @pending_questions.set(snap[:pending_questions])
        @overview.set(snap[:overview])
        @config.set(snap[:config])
        @offline.set(snap[:offline])
        @last_error.set(snap[:last_error])
      end
      nil
    end

    private

    # ── Opal 适配层：全部 JS 集中在以下方法内，defined?(Opal) 守卫，
    #    CRuby 下为安全 no-op（测试零网络）。─────────────────

    # POST JSON body；必须 text/plain——Observer 不处理 OPTIONS，默认
    # application/json 会触发 CORS 预检导致整个 POST 失败。
    def post_body(body)
      return nil unless defined?(Opal)

      url = "#{@base_url}/api/messages"
      %x{
        fetch(#{url}, {
          method: 'POST',
          headers: { 'Content-Type': 'text/plain' },
          body: #{body}
        }).then(function(r) {
          if (!r.ok) {
            return r.text().then(function(t) { #{post_failed(`t`)}; });
          }
          return null;
        }).catch(function(e) {
          #{post_failed(`(e && e.message) ? '' + e.message : String(e)`)};
        })
      }
      nil
    end

    def post_failed(message)
      @core.mark_offline("消息发送失败：#{message}")
      sync_signals
      nil
    end

    # 轮询：activate 起、deactivate 停。递归重排——每轮的收尾（poll_finished）
    # 里排下一轮，请求天然不重叠；任一请求失败即整轮中止（fetch 对 HTTP 错误
    # 状态不 reject，须查 r.ok 手动抛错），offline=true、记 last_error、
    # 旧数据保留，下一轮重试。
    def start_polling
      @polling = true
      schedule_tick(0)   # 激活立即首轮，之后按 POLL_INTERVAL_MS 循环
      nil
    end

    def stop_polling
      @polling = false
      Beryl::Timer.cancel(@timer)
      @timer = nil
      nil
    end

    def schedule_tick(delay = POLL_INTERVAL_MS)
      return nil unless @polling

      @timer = Beryl::Timer.after(delay) { poll_cycle }
      nil
    end

    # 一轮轮询：依次 overview → config → agents → services → human → 各 endpoint
    # mailbox（名单取本轮刚归一的 agents+services）。顺序 await，全部成功才
    # mark_online；catch 到任一出错即 mark_offline。两种结局都同步 signal 并排下一轮。
    def poll_cycle
      return nil unless @polling

      base = @base_url.to_s
      %x{
        (async function() {
          var jf = function(url) {
            return fetch(url).then(function(r) {
              if (!r.ok) throw new Error('HTTP ' + r.status + ' @ ' + url);
              return r.json();
            });
          };
          try {
            var ov = await jf(#{base} + '/api/overview');
            #{ingest_response(:overview, `ov`)};
            var cf = await jf(#{base} + '/api/config');
            #{ingest_response(:config, `cf`)};
            var ag = await jf(#{base} + '/api/agents');
            #{ingest_response(:agents, `ag`)};
            var sv = await jf(#{base} + '/api/services');
            #{ingest_response(:services, `sv`)};
            var hu = await jf(#{base} + '/api/human');
            #{ingest_response(:human, `hu`)};
            var names = #{@core.endpoint_names};
            for (var i = 0; i < names.length; i++) {
              var mb = await jf(#{base} + '/api/mailbox?agent=' + encodeURIComponent(names[i]));
              #{ingest_mailbox_response(`names[i]`, `mb`)};
            }
            #{poll_finished(nil)};
          } catch (e) {
            #{poll_finished(`(e && e.message) ? ('' + e.message) : String(e)`)};
          }
        })();
      }
      nil
    end

    # JS 原生 JSON → Ruby（Opal 下 from_native 递归转换，CRuby 原样返回）后喂内核。
    def ingest_response(kind, data)
      data = Emerald::Storage.from_native(data)
      case kind
      when :overview then @core.ingest_overview(data)
      when :config then @core.ingest_config(data)
      when :agents then @core.ingest_agents(data)
      when :services then @core.ingest_services(data)
      when :human then @core.ingest_human(data)
      end
    end

    def ingest_mailbox_response(name, data)
      @core.ingest_mailbox(Emerald::Storage.from_native(data), name.to_s)
    end

    def poll_finished(error)
      error.nil? ? @core.mark_online : @core.mark_offline(error.to_s)
      sync_signals
      schedule_tick
      nil
    end
  end
end
