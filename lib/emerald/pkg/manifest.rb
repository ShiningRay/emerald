# frozen_string_literal: true

module Emerald
  module Pkg
    # manifest.json 的模型与校验器（docs/SPEC-package-format.md §3/§4）。
    # 构造即全量校验（fail fast）：任何不合法当场 raise Invalid，错误消息带
    # 字段路径。声明式优先——安装器/注册表只读本模型，不执行包内代码。
    #
    # v1 口径：
    # - 三种 kind 共用公共 schema；agent/skill 的扩展字段（profile/seed/
    #   interface）v1 未消费、不做深度校验，Installer 层拒绝安装；
    # - 未知字段一律忽略（向后兼容）；未知 spec 拒绝；
    # - min_runtime 只支持 '>=X.Y.Z' 等四则比较算符（SPEC 示例口径）。
    class Manifest
      Invalid = Json::Invalid

      SPEC_VERSION = 1
      KINDS = %w[app agent skill].freeze
      ID_RE = /\A[a-z][a-z0-9-]*\z/
      VERSION_RE = /\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/
      MIN_RUNTIME_RE = /\A(>=|<=|==|>|<)\s*(\d+)\.(\d+)\.(\d+)\z/
      EXT_RE = /\A\.[a-z0-9][a-z0-9._-]*\z/

      attr_reader :data

      def self.parse(str)
        new(Json.parse(str))
      end

      def initialize(data)
        raise Invalid, 'manifest 顶层必须是 JSON 对象' unless data.is_a?(Hash)

        @data = data
        validate!
      end

      # ── 公共字段 ────────────────────────────────────────
      def spec
        @data['spec']
      end

      def kind
        @data['kind']
      end

      def id
        @data['id']
      end

      def name
        @data['name']
      end

      def version
        @data['version']
      end

      def description
        @data['description']
      end

      def authors
        @data['authors'].is_a?(Array) ? @data['authors'].dup : []
      end

      def homepage
        @data['homepage']
      end

      def permissions
        @data['permissions'].is_a?(Array) ? @data['permissions'].dup : []
      end

      def id_sym
        @id_sym ||= id.to_sym
      end

      def app?
        kind == 'app'
      end

      # ── kind=app 扩展字段（§4.1）────────────────────────
      def entry
        @data['entry']
      end

      # => [{ id:, title:, hotkey: }]（无声明 → []）
      def commands
        @commands ||= fetch_array(%w[contributes commands]).map do |c|
          { id: c['id'], title: c['title'], hotkey: c['hotkey'] }
        end
      end

      # => ['.hello', ...]（小写、带点）
      def file_types
        @file_types ||= fetch_array(%w[contributes file_types]).map { |e| normalize_ext(e) }
      end

      # => [{ path:, command: }]
      def menus
        @menus ||= fetch_array(%w[contributes menus]).map do |m|
          { path: m['path'], command: m['command'] }
        end
      end

      # => { on_command: [], on_file_type: [], startup: bool }
      def activation
        act = @data['activation'].is_a?(Hash) ? @data['activation'] : {}
        {
          on_command: (act['on_command'] || []).map(&:to_s),
          on_file_type: (act['on_file_type'] || []).map { |e| normalize_ext(e) },
          startup: act['on_startup'] == true,
        }
      end

      def singleton?
        window['singleton'] == true
      end

      # => { x:, y:, w:, h: }（Symbol 键）| nil
      def default_geometry
        g = window['default_geometry']
        return nil unless g.is_a?(Hash)

        { x: g['x'], y: g['y'], w: g['w'], h: g['h'] }
      end

      # ── 运行时版本要求（§3 min_runtime）─────────────────
      def runtime_ok?(current = Emerald::VERSION)
        req = min_runtime['emerald']
        return true if req.nil?

        op, triple = parse_min_runtime(req)
        mine = semver_triple(current)
        compare_triple(mine, op, triple)
      end

      def require_runtime!(current = Emerald::VERSION)
        return self if runtime_ok?(current)

        raise Invalid,
              "系统版本不满足 #{id} 的要求（需要 emerald #{min_runtime['emerald']}，" \
              "当前 #{current}）——应用需要更新或系统需要升级"
      end

      def min_runtime
        @min_runtime ||= @data['min_runtime'].is_a?(Hash) ? @data['min_runtime'] : {}
      end

      private

      def window
        @window ||= @data['window'].is_a?(Hash) ? @data['window'] : {}
      end

      # data['contributes'][key]（缺级安全 → []）
      def fetch_array(path)
        node = @data
        path.each do |k|
          node = node[k] if node.is_a?(Hash)
        end
        node.is_a?(Array) ? node : []
      end

      def normalize_ext(ext)
        e = ext.to_s.downcase
        e.start_with?('.') ? e : ".#{e}"
      end

      def parse_min_runtime(req)
        m = MIN_RUNTIME_RE.match(req.to_s.strip)
        raise Invalid, "min_runtime.emerald 不合法: #{req.inspect}（支持 >=/<=/==/>/< X.Y.Z）" if m.nil?

        [m[1], [m[2].to_i, m[3].to_i, m[4].to_i]]
      end

      def semver_triple(v)
        m = /\A(\d+)\.(\d+)\.(\d+)/.match(v.to_s)
        raise Invalid, "系统版本号不合法: #{v.inspect}" if m.nil?

        [m[1].to_i, m[2].to_i, m[3].to_i]
      end

      def compare_triple(a, op, b)
        cmp = (a <=> b)
        case op
        when '>=' then cmp >= 0
        when '>'  then cmp.positive?
        when '<=' then cmp <= 0
        when '<'  then cmp.negative?
        when '==' then cmp.zero?
        end
      end

      # ── 校验 ───────────────────────────────────────────
      def validate!
        validate_common!
        validate_app_fields! if kind == 'app'
        validate_contributes!
        validate_activation!
        validate_window!
      end

      def validate_common!
        raise Invalid, '缺少 spec 字段' unless key?('spec')
        raise Invalid, "不支持的包规格版本 spec=#{spec.inspect}（本系统支持 #{SPEC_VERSION}）" unless spec == SPEC_VERSION

        raise Invalid, '缺少 kind 字段' unless key?('kind')
        raise Invalid, "未知 kind=#{kind.inspect}（支持 #{KINDS.join('/')}）" unless KINDS.include?(kind)

        raise Invalid, '缺少 id 字段' unless key?('id')
        raise Invalid, "id 不合法: #{id.inspect}（须匹配 #{ID_RE}）" unless id.is_a?(String) && ID_RE.match?(id)

        raise Invalid, '缺少 name 字段' unless key?('name')
        raise Invalid, 'name 必须是非空字符串' unless name.is_a?(String) && !name.empty?

        raise Invalid, '缺少 version 字段' unless key?('version')
        raise Invalid, "version 不合法: #{version.inspect}（须为 semver X.Y.Z）" unless version.is_a?(String) && VERSION_RE.match?(version)

        raise Invalid, 'description 必须是字符串' unless description.nil? || description.is_a?(String)
        raise Invalid, 'authors 必须是字符串数组' unless array_of_strings?(@data['authors'])
        raise Invalid, 'permissions 必须是字符串数组' unless array_of_strings?(@data['permissions'])
        raise Invalid, 'homepage 必须是字符串' unless homepage.nil? || homepage.is_a?(String)

        return unless key?('min_runtime') && !min_runtime.is_a?(Hash)

        raise Invalid, 'min_runtime 必须是对象'
      end

      def validate_app_fields!
        raise Invalid, "kind=app 缺少 entry 字段" unless entry.is_a?(String) && !entry.empty?
        raise Invalid, "entry 必须是包内相对路径: #{entry.inspect}" if entry.start_with?('/')
        raise Invalid, "entry 不得越出包根（..）: #{entry.inspect}" if entry.split('/').include?('..')
      end

      def validate_contributes!
        contributes = @data['contributes']
        return if contributes.nil?
        raise Invalid, 'contributes 必须是对象' unless contributes.is_a?(Hash)

        seen = []
        fetch_array(%w[contributes commands]).each do |c|
          raise Invalid, 'contributes.commands 每项必须是对象' unless c.is_a?(Hash)
          raise Invalid, "命令缺少 id: #{c.inspect}" unless c['id'].is_a?(String) && c['id'].include?('.')
          raise Invalid, "命令 #{c['id']} 缺少 title" unless c['title'].is_a?(String) && !c['title'].empty?
          raise Invalid, "命令 #{c['id']} 的 hotkey 必须是字符串" unless c['hotkey'].nil? || c['hotkey'].is_a?(String)
          raise Invalid, "命令 id 重复: #{c['id']}" if seen.include?(c['id'])

          seen << c['id']
        end

        fetch_array(%w[contributes file_types]).each do |e|
          raise Invalid, "file_types 每项须为扩展名字符串: #{e.inspect}" unless e.is_a?(String) && EXT_RE.match?(normalize_ext(e))
        end

        fetch_array(%w[contributes menus]).each do |m|
          raise Invalid, 'contributes.menus 每项必须是对象' unless m.is_a?(Hash)
          raise Invalid, "菜单缺少 path: #{m.inspect}" unless m['path'].is_a?(String) && !m['path'].empty?
          raise Invalid, "菜单缺少 command: #{m.inspect}" unless m['command'].is_a?(String) && !m['command'].empty?
        end
      end

      def validate_activation!
        act = @data['activation']
        return if act.nil?
        raise Invalid, 'activation 必须是对象' unless act.is_a?(Hash)

        raise Invalid, 'activation.on_command 必须是字符串数组' unless string_array?(act['on_command'])
        raise Invalid, 'activation.on_file_type 必须是字符串数组' unless string_array?(act['on_file_type'])
        raise Invalid, 'activation.on_startup 必须是布尔值' unless [nil, true, false].include?(act['on_startup'])
      end

      def validate_window!
        win = @data['window']
        return if win.nil?
        raise Invalid, 'window 必须是对象' unless win.is_a?(Hash)

        raise Invalid, 'window.singleton 必须是布尔值' unless [nil, true, false].include?(win['singleton'])

        g = win['default_geometry']
        return if g.nil?
        raise Invalid, 'window.default_geometry 必须是对象' unless g.is_a?(Hash)
        raise Invalid, 'window.default_geometry 须含整数 x/y/w/h' unless %w[x y w h].all? { |k| g[k].is_a?(Integer) }
      end

      def key?(k)
        @data.key?(k)
      end

      def string_array?(v)
        v.nil? || (v.is_a?(Array) && v.all?(String))
      end

      def array_of_strings?(v)
        v.nil? || (v.is_a?(Array) && v.all?(String))
      end
    end
  end
end
