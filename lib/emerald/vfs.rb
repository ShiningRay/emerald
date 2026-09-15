# frozen_string_literal: true

module Emerald
  # 虚拟文件系统（PLAN §3.3）：内存规范树 + 适配器持久化 + 目录 watch 版本号语义。
  # 纯 CRuby 可测（D5）；storage 为 Emerald::Storage 适配器或 nil（不持久化）。
  #
  # 树结构：目录的 content 为子节点 Hash（name => Node），文件的 content 为 String。
  # 持久化格式：{ 'version' => 1, 'tree' => <递归 Hash> }（key: 'emerald.fs.v1'）。
  # mtime 用单调计数器（不依赖 Time，Opal/CRuby 一致）。
  class VFS
    # 自定义错误类：路径不存在（read/list/stat 之外的探查请用 exist?）
    NotFound = Class.new(StandardError)

    # 节点结构。注意：目录的 content 是内部子树 Hash，**只在 list/stat 的
    # 只读视图里隐藏**（见 view_node）——内部构造时原样保留
    Node = Struct.new(:name, :kind, :content, :mtime)

    STORAGE_KEY = 'emerald.fs.v1'
    DEBOUNCE_MS = 300
    ROOT = '/'

    # 路径工具（模块函数，也供 wave 2 的文件管理器/终端使用）：
    # 只收绝对路径（'/' 开头），折叠 `//`、`.`、`..`；`..` 越出根 → ArgumentError。
    def self.normalize(path)
      raise ArgumentError, '路径必须是 String' unless path.is_a?(String)

      cleaned = path.gsub('\\', '/')
      raise ArgumentError, "路径必须是绝对路径（'/' 开头）: #{path.inspect}" unless cleaned.start_with?(ROOT)

      parts = cleaned.split('/', -1).reject { |seg| seg.empty? || seg == '.' }
      stack = []
      parts.each do |seg|
        if seg == '..'
          raise ArgumentError, "路径越出根目录: #{path.inspect}" if stack.empty?

          stack.pop
        else
          stack << seg
        end
      end
      ROOT + stack.join('/')
    end

    def self.root?(path)
      normalize(path) == ROOT
    end

    def initialize(storage: nil)
      @storage = storage
      @timers = {}  # key => 未执行的持久化 Timer handle（同 key 取消重排）
      @watches = {} # 目录路径 => Citrine::Signal（版本号 bump 语义）
      @clock = 0    # 单调 mtime 计数器
      @root = dir_node('')
      load!
    end

    # 幂等初始化：/docs/readme.txt（有内容）、/Desktop、/images（空目录）；
    # 已存在不覆盖（重复调用内容不翻倍）
    def seed!
      commit('/docs', '/docs/readme.txt', '/Desktop', '/images') do
        docs = ensure_dir('/docs')
        docs.content['readme.txt'] = file_node('readme.txt', readme_text) unless docs.content['readme.txt']
        ensure_dir('/Desktop')
        ensure_dir('/images')
      end
      self
    end

    def read(path)
      node = node_at(path)
      raise NotFound, "路径不存在: #{normalize(path)}" if node.nil?
      raise NotFound, "不是文件: #{normalize(path)}" if node.kind == :dir

      node.content.dup
    end

    # 自动创建父目录（缺失的中间目录递归补齐）；content String
    def write(path, content)
      raise ArgumentError, 'content 必须是 String' unless content.is_a?(String)

      np = normalize(path)
      raise ArgumentError, '不能把根目录写成文件' if np == ROOT

      commit(np) do
        parent = ensure_dir(split(np)[0])
        parent.content[base_name(np)] = file_node(base_name(np), content.dup)
        bump_mtimes!(np)
      end
      content
    end

    # 递归创建
    def mkdir(path)
      np = normalize(path)
      commit(np) do
        ensure_dir(np)
        bump_mtimes!(np)
      end
      self
    end

    # => [Node]（只读视图）；目录在前、同 kind 按 name 升序；不存在 raise NotFound
    def list(path)
      node = node_at(path)
      raise NotFound, "目录不存在: #{normalize(path)}" if node.nil? || node.kind != :dir

      node.content.values
          .map { |child| view_node(child) }
          .sort_by { |n| [n.kind == :dir ? 0 : 1, n.name] }
    end

    # => Node | nil（只读视图；目录不暴露内部 content）
    def stat(path)
      node = node_at(path)
      node && view_node(node)
    end

    # dst 为已存在目录 → 移入保留文件名；否则改名为 dst（含覆盖语义）；
    # 在目录内部移动视为同名 → no-op 但仍是合法 commit。
    def move(src, dst)
      s = normalize(src)
      d = normalize(dst)
      raise ArgumentError, '不能移动根目录' if s == ROOT

      commit(s, d) do
        node = node_at(s)
        raise NotFound, "源路径不存在: #{s}" if node.nil?

        if node_at(d)&.kind == :dir
          target = node_at(d)
          node.name = base_name(s)
          target.content[node.name] = node
        else
          parent = parent_at!(d)
          node.name = base_name(d)
          parent.content[node.name] = node
        end
        detach(s)
        bump_mtimes!(s)
        bump_mtimes!(d)
      end
      self
    end

    # 递归删除
    def delete(path)
      np = normalize(path)
      raise ArgumentError, '不能删除根目录' if np == ROOT

      commit(np) do
        raise NotFound, "路径不存在: #{np}" if node_at(np).nil?

        detach(np)
        bump_mtimes!(np)
      end
      self
    end

    def exist?(path)
      !node_at(path).nil?
    end

    # => Citrine::Signal（初值 [dir, 0]）；该目录自身或直接子级任何变更
    # bump 为 [dir, 新版本号]（bump 沿祖先链上冒：父目录 watcher 也能感知直接子级变化）
    def watch(dir)
      d = normalize(dir)
      @watches[d] ||= Citrine.signal([d, 0])
    end

    def self.normalize_path(path)
      normalize(path)
    end

    private

    # ---- 变更操作统一入口：改树 → 触发相关 watch 信号（精确路径链）→ 调度持久化 ----
    # changed：本次 commit 变更过的路径；bump 规则 = watcher 目录落在任一
    # 变更路径的「自身 + 祖先链」上（目录自身变更与其直接子级变更都会命中，
    # 无关目录不触发）
    def commit(*changed)
      yield
      hit = changed.flat_map { |p| path_chain(p) }.to_h { |d| [d, true] }
      @watches.each do |dir, sig|
        sig.set!(bumped_value(sig)) if hit.key?(dir)
      end
      schedule_persist
      self
    end

    # 路径链：自身 + 每一级祖先（含根）
    def path_chain(path)
      np = normalize(path)
      chain = [np]
      until np == ROOT
        np = split(np)[0]
        chain << np
      end
      chain
    end

    def bumped_value(sig)
      dir, version = sig.peek
      [dir, version + 1]
    end

    def schedule_persist
      return if @storage.nil?

      @timers[STORAGE_KEY] = debounce(@timers[STORAGE_KEY]) do
        @storage.dump(STORAGE_KEY, serialize)
      end
    end

    def debounce(pending)
      Beryl::Timer.cancel(pending)
      Beryl::Timer.after(DEBOUNCE_MS) { yield }
    end

    # ---- 树结构 ----
    def dir_node(name)
      Node.new(name, :dir, {}, next_mtime)
    end

    def file_node(name, content)
      Node.new(name, :file, content, next_mtime)
    end

    def next_mtime
      @clock += 1
    end

    def normalize(path)
      self.class.normalize(path)
    end

    def split(path)
      np = normalize(path)
      return [nil, ''] if np == ROOT

      idx = np.rindex('/')
      idx.zero? ? [ROOT, np[1..]] : [np[0...idx], np[(idx + 1)..]]
    end

    def base_name(path)
      split(path)[1]
    end

    # 遍历返回内部节点（nil 表示不存在）；根路径返回 @root
    def node_at(path)
      np = normalize(path)
      return @root if np == ROOT

      dir, base = split(np)
      parent = node_at(dir)
      return nil if parent.nil? || parent.kind != :dir

      parent.content[base]
    end

    # 父目录必须已存在（与命令行 mkdir 语义一致）
    def parent_at!(path)
      node = node_at(split(path)[0])
      raise NotFound, "父目录不存在: #{path}" if node.nil? || node.kind != :dir

      node
    end

    # 递归建目录（已存在则复用）；返回目标节点。
    # 中间路径被同名文件挡住 → ArgumentError（ENOTDIR 语义）
    def ensure_dir(path)
      np = normalize(path)
      return @root if np == ROOT

      dir, base = split(np)
      parent = ensure_dir(dir)
      existing = parent.content[base]
      return existing if existing&.kind == :dir
      raise ArgumentError, "路径被同名文件挡住: #{np}" if existing

      parent.content[base] = dir_node(base)
    end

    def detach(path)
      dir, base = split(path)
      parent = node_at(dir)
      parent&.content&.delete(base)
    end

    # mtime 沿路径冒泡更新：该路径自身与其每一级祖先目录
    def bump_mtimes!(path)
      np = normalize(path)
      loop do
        node = node_at(np)
        node&.mtime = next_mtime
        break if np == ROOT

        np = split(np)[0]
      end
    end

    # 只读视图：目录的 content（内部子树）不暴露，防止外部改穿内部树；
    # 文件的 content 为内部串的 dup（Node 本身只读）
    def view_node(node)
      Node.new(node.name, node.kind, node.kind == :dir ? nil : node.content.dup, node.mtime).freeze
    end

    # ---- 持久化 ----
    def serialize
      { 'version' => 1, 'tree' => serialize_node(@root) }
    end

    def serialize_node(node)
      if node.kind == :dir
        { 'name' => node.name, 'kind' => 'dir', 'mtime' => node.mtime,
          'children' => node.content.transform_values { |child| serialize_node(child) } }
      else
        { 'name' => node.name, 'kind' => 'file', 'mtime' => node.mtime, 'content' => node.content }
      end
    end

    def deserialize_node!(hash, into)
      children = hash['children'] || {}
      children.each_value do |child|
        name = child['name']
        if child['kind'] == 'file'
          into.content[name] = Node.new(name, :file, child['content'], child['mtime'] || next_mtime)
        else
          sub = dir_node(name)
          sub.mtime = child['mtime'] if child['mtime']
          into.content[name] = sub
          deserialize_node!(child, sub)
        end
      end
    end

    # 无数据则先 seed 再读（seed 走 commit：watcher 注册前亦安全）
    def load!
      return if @storage.nil?

      data = @storage.load(STORAGE_KEY)
      if data.nil?
        seed!
        return
      end
      return unless data.is_a?(Hash) && data['version'] == 1 && data['tree'].is_a?(Hash)

      @root = dir_node('')
      @root.mtime = data['tree']['mtime'] if data['tree']['mtime']
      deserialize_node!(data['tree'], @root)
      @clock = max_mtime(@root)
    end

    def max_mtime(node)
      best = node.mtime || 0
      if node.kind == :dir
        node.content.each_value { |child| best = [best, max_mtime(child)].max }
      end
      best
    end

    def readme_text
      <<~TXT
        Welcome to Emerald OS!
        ======================
        This virtual file system is persisted to localStorage (key: emerald.fs.v1).
      TXT
    end
  end
end
