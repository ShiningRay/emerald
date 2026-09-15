# frozen_string_literal: true

module Emerald
  module Pkg
    # 安装来源（docs/SPEC-package-format.md §5）：统一语法的解析模型。
    #
    #   ./hello.emz                                  → file（本地包文件）
    #   ./hello-dir                                  → dir（裸目录，开发期）
    #   git:https://github.com/u/repo#v1.2.0         → git
    #   git:https://github.com/u/repo#main?path=pkgs/hello → git（monorepo 子目录）
    #
    # 纯语法解析，不做任何 IO；网络/克隆由调用方按 type 分派
    #（浏览器 → archive_url 走平台 HTTP；CLI → 真实 clone）。
    class Source
      # 浏览器端无法拉取的平台 archive（v1 只覆盖 GitHub/GitLab）
      Unsupported = Class.new(ArgumentError)

      attr_reader :type, :path, :url, :ref, :subpath

      def self.parse(str)
        raise Invalid, "安装来源不能为空" if str.nil? || str.to_s.strip.empty?

        s = str.to_s.strip
        return parse_git(s) if s.start_with?('git:')

        type = s.end_with?('.emz') ? :file : :dir
        new(type: type, path: s)
      end

      def self.parse_git(s)
        rest = s.delete_prefix('git:')
        url = rest.split('#', 2)[0].split('?', 2)[0]
        raise Invalid, "git 来源必须是 https URL: #{s.inspect}" unless url.start_with?('https://')

        ref = nil
        subpath = nil
        after_url = rest.delete_prefix(url)
        unless after_url.empty?
          ref_part, query = after_url.delete_prefix('#').split('?', 2)
          ref = ref_part.empty? ? nil : ref_part
          subpath = query_param(query, 'path') if query
        end
        new(type: :git, url: url, ref: ref, subpath: subpath)
      end

      # 解析归一后的来源：'git:https://github.com/u/repo#main?path=pkg/hello'
      def self.query_param(query, key)
        query.split('&').each do |pair|
          k, v = pair.split('=', 2)
          return v if k == key && v && !v.empty?
        end
        nil
      end

      def initialize(type:, path: nil, url: nil, ref: nil, subpath: nil)
        @type = type
        @path = path
        @url = url
        @ref = ref
        @subpath = subpath
      end

      def git?
        type == :git
      end

      def file?
        type == :file
      end

      def dir?
        type == :dir
      end

      # 浏览器端平台 archive HTTP URL（SPEC §5）。仅支持 GitHub/GitLab；
      # ref 缺省 = 默认分支（对 GitHub archive 即 'HEAD'）。
      def archive_url
        raise Unsupported, "非 git 来源没有 archive URL" unless git?

        if (gh = github_repo)
          owner, repo = gh
          return "https://codeload.github.com/#{owner}/#{repo}/zip/#{ref || 'HEAD'}"
        end
        if (gl = gitlab_repo)
          group, repo = gl
          r = ref || 'main'
          return "https://gitlab.com/#{group}/#{repo}/-/archive/#{r}/#{repo}-#{r}.zip"
        end

        raise Unsupported,
              "浏览器端暂不支持 #{host} 的 archive 拉取（v1 仅 GitHub/GitLab）——请改用 CLI 安装"
      end

      # 展示用（通知/报错）
      def to_s
        case type
        when :git
          "git:#{url}#{ref ? "##{ref}" : ''}#{subpath ? "?path=#{subpath}" : ''}"
        else
          path
        end
      end

      private

      # 'https://github.com/owner/repo(.git)?' → ['owner', 'repo'] | nil
      def github_repo
        m = %r{\Ahttps://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?\z}.match(url)
        m && [m[1], m[2]]
      end

      def gitlab_repo
        m = %r{\Ahttps://gitlab\.com/([A-Za-z0-9._/-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?\z}.match(url)
        m && [m[1], m[2]]
      end

      def host
        url.split('/')[2]
      end
    end
  end
end
