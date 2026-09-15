# frozen_string_literal: true

module Emerald
  module Pkg
    # 安装器（docs/PLAN.md §3.10 / SPEC §5）：三类来源（本地 .emz / 裸目录 /
    # git 导入）→ 校验 manifest → 写 VFS /Applications/<id>/ → lock 固化。
    #
    # IO 边界全部注入（纯 CRuby 可测，D5 同款）：
    # - git 来源的浏览器拉取：fetcher = callable(source) →
    #   { bytes: Array<Integer>, resolved_commit?: String }（CLI/测试另配）
    # - 目录来源：install_dir 直接收 { 相对路径 => 文本内容 } 文件映射
    class Installer
      APPS_DIR = '/Applications'

      attr_reader :vfs, :lock

      def initialize(vfs:, lock: nil, fetcher: nil)
        @vfs = vfs
        @lock = lock || Lock.new(vfs)
        @fetcher = fetcher
      end

      # ── 三类来源 ───────────────────────────────────────

      # 本地 .emz（bytes: 包文件的字节 Array）
      def install_file(source_str, bytes)
        source = Source.parse(source_str)
        raise ArgumentError, "来源不是 .emz 文件: #{source_str}" unless source.file?

        install_entries(source, Zip.read(bytes))
      end

      # git 导入（浏览器走平台 archive HTTP；fetcher 注入）
      def install_git(source_str)
        source = Source.parse(source_str)
        raise ArgumentError, "来源不是 git 形态: #{source_str}" unless source.git?
        raise ArgumentError, 'git 来源需要注入 fetcher' unless @fetcher

        payload = @fetcher.call(source)
        entries = payload[:entries] || Zip.read(payload.fetch(:bytes))
        commit = payload[:resolved_commit] || derive_commit(entries)
        install_entries(source, entries, resolved_commit: commit)
      end

      # 裸目录包（开发期 / 测试 / 预装 seed）：files = { 'manifest.json' => 文本 }
      def install_dir(source_str, files)
        source = Source.parse(source_str)
        raise ArgumentError, "来源不是目录形态: #{source_str}" unless source.dir?

        entries = files.map do |name, text|
          text.is_a?(String) or raise ArgumentError, "目录包内容必须是文本: #{name}"
          Zip::Entry.new(name, name.end_with?('/'), text.b.bytes)
        end
        install_entries(source, entries)
      end

      # ── 卸载 ───────────────────────────────────────────

      # => true 卸载了（lock 或应用目录存在即算）；false 本就没装
      #（窗口注销/实例回收归调用方）
      def uninstall(id)
        dir = "#{APPS_DIR}/#{id}"
        removed_lock = @lock.remove(id)
        had_dir = @vfs.exist?(dir)
        @vfs.delete(dir) if had_dir
        removed_lock || had_dir
      end

      def installed?(id)
        @lock.installed?(id)
      end

      def list
        @lock.entries
      end

      # ── 核心：entries（zip 形态或目录形态）→ /Applications ──

      # => { status: :installed|:updated|:skipped, manifest:, app_dir: }
      def install_entries(source, entries, resolved_commit: nil)
        entries = strip_archive_root(entries)
        entries = apply_subpath(entries, source.subpath) if source.git? && source.subpath

        manifest = manifest_from(entries)

        manifest.require_runtime!
        sha = content_sha256(entries)
        resolved_commit ||= derive_commit(entries) if source.git?

        prev = @lock.get(manifest.id)
        status = if prev && prev['source'] && prev['source']['content_sha256'] == sha
                   :skipped # 同一内容重装：幂等跳过（可复现优先）
                 elsif prev
                   :updated
                 else
                   :installed
                 end

        write_app_dir(manifest.id, entries) unless status == :skipped
        @lock.add(manifest, source: source, content_sha256: sha, resolved_commit: resolved_commit)
        { status: status, manifest: manifest, app_dir: "#{APPS_DIR}/#{manifest.id}" }
      end

      private

      # 平台 archive（GitHub/GitLab）把所有文件放进 <repo>-<ref|sha>/ 顶层目录；
      # 根部没有 manifest.json 且条目共享唯一顶层段时剥掉它。monorepo 的
      # subpath 剥离在 install_entries 里做（优先级更高）。
      def strip_archive_root(entries)
        return entries if entries.any? { |e| e.name == 'manifest.json' }

        segs = entries.map { |e| e.name.split('/', 2)[0] }.uniq
        return entries unless segs.size == 1

        prefix = "#{segs[0]}/"
        entries.select { |e| e.name.start_with?(prefix) }
               .map { |e| Zip::Entry.new(e.name.delete_prefix(prefix), e.directory, e.data) }
      end

      # monorepo subpath：只留 <subpath>/ 前缀下的条目并剥前缀
      def apply_subpath(entries, sub)
        prefix = "#{sub.sub(%r{/\z}, '')}/"
        picked = entries.select { |e| e.name.start_with?(prefix) }
                        .map { |e| Zip::Entry.new(e.name.delete_prefix(prefix), e.directory, e.data) }
        raise Json::Invalid, "path=#{sub} 下没有 manifest.json" if picked.none? { |e| e.name == 'manifest.json' }

        picked
      end

      def manifest_from(entries)
        node = entries.find { |e| e.name == 'manifest.json' }
        raise Json::Invalid, '包缺少 manifest.json' if node.nil?

        manifest = Manifest.parse(Bytes.to_utf8(node.data))
        raise Json::Invalid, "Emerald v1 仅支持安装 app 包（kind=#{manifest.kind}）" unless manifest.app?

        manifest
      end

      # 同名同序内容 => 同一指纹（name + 0x00 + 内容 字节流按名排序拼接）
      def content_sha256(entries)
        stream = entries.reject(&:directory)
                        .sort_by(&:name)
                        .flat_map { |e| e.name.b.bytes + [0x00] + e.data }
        Sha256.hexdigest(stream)
      end

      # GitHub/GitLab archive 的顶层目录是 repo-<sha> 形态 → 由此固化 commit；
      # 推不出（自制包/目录）→ nil，lock 以 content_sha256 固化
      def derive_commit(entries)
        segs = entries.map { |e| e.name.split('/', 2)[0] }.uniq
        return nil unless segs.size == 1

        m = /\A[A-Za-z0-9._-]+-([0-9a-f]{7,40})\z/.match(segs[0])
        m && m[1]
      end

      def write_app_dir(id, entries)
        dir = "#{APPS_DIR}/#{id}"
        @vfs.delete(dir) if @vfs.exist?(dir) # 更新 = 先清旧再写新
        @vfs.mkdir(dir)
        entries.reject(&:directory).each do |e|
          raise Json::Invalid, "包内路径越界: #{e.name}" if e.name.split('/').include?('..')

          @vfs.write("#{dir}/#{e.name}", Bytes.to_utf8(e.data))
        end
      end
    end
  end
end
