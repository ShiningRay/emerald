# frozen_string_literal: true

module Emerald
  module Pkg
    # 安装记录 lock（docs/SPEC-package-format.md §5：installed.json）。
    # 存 VFS /System/installed.json，每包一条：id/kind/version + source
    #（含 resolved_commit 与 content_sha256 固化）+ 时间戳。
    # 可复现语义：分支/标签会漂移，安装结果只认 resolved_commit 与内容指纹。
    class Lock
      PATH = '/System/installed.json'

      def initialize(vfs)
        @vfs = vfs
        @entries = {} # id(String) => entry Hash，插入序 = 安装序
        load!
      end

      # 快照数组（新构造，防外部改穿）
      def entries
        @entries.values.map(&:dup)
      end

      def get(id)
        entry = @entries[id.to_s]
        entry && entry.dup
      end

      def ids
        @entries.keys
      end

      def installed?(id)
        @entries.key?(id.to_s)
      end

      # 新增/更新一条。同 id：installed_at 保留首次安装时间，updated_at 刷新。
      # bundled: 预装应用（类已随系统 bundle 定义，AppHost 扫描时跳过求值）。
      def add(manifest, source:, content_sha256:, resolved_commit: nil, bundled: false)
        now = timestamp
        src = { 'type' => source.type.to_s, 'content_sha256' => content_sha256 }
        src['path'] = source.path if source.file? || source.dir?
        if source.git?
          src['url'] = source.url
          src['ref'] = source.ref
          src['subpath'] = source.subpath if source.subpath
          src['resolved_commit'] = resolved_commit if resolved_commit
        end

        prev = @entries[manifest.id]
        @entries[manifest.id] = {
          'id' => manifest.id,
          'kind' => manifest.kind,
          'version' => manifest.version,
          'source' => src,
          'installed_at' => prev ? prev['installed_at'] : now,
          'updated_at' => now,
        }
        @entries[manifest.id]['bundled'] = true if bundled
        persist
        @entries[manifest.id]
      end

      # => true 删除了记录；false 本就没有
      def remove(id)
        return false unless @entries.delete(id.to_s)

        persist
        true
      end

      # 标记预装应用（类已随系统 bundle 定义；AppHost 扫描跳过求值）
      def mark_bundled(id)
        entry = @entries[id.to_s]
        return false unless entry

        entry['bundled'] = true
        persist
        true
      end

      private

      def load!
        return unless @vfs.exist?(PATH)

        data = Json.parse(@vfs.read(PATH))
        return unless data.is_a?(Hash)

        data.each_value do |entry|
          @entries[entry['id']] = entry if entry.is_a?(Hash) && entry['id'].is_a?(String)
        end
      rescue Json::Invalid
        # lock 损坏 → 视作空记录（应用文件还在，重装即修复）
        @entries = {}
      end

      def persist
        # /System 目录自动建（VFS write 递归补齐父目录）
        @vfs.write(PATH, Json.generate(@entries))
        self
      end

      def timestamp
        Time.now.strftime('%Y-%m-%dT%H:%M:%S')
      end
    end
  end
end
