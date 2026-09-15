# frozen_string_literal: true

module Emerald
  # 文件类型路由：扩展名（含点，小写归一）→ app_id。
  # Files 双击/打开文件时经 services[:open_file] 解析到应用；未命中返回 nil
  #（由调用方决定提示）。纯 CRuby 服务，可注入可单测。
  class FileTypeRouter
    def initialize
      @table = {}
    end

    # ext 可 String/Symbol（'.txt' / :txt / '.TXT' 均可），app_id 归一为 Symbol
    def register(ext, app_id)
      key = ext.to_s.downcase
      key = ".#{key}" unless key.start_with?('.')
      @table[key] = app_id.to_sym
      self
    end

    def app_for(path)
      @table[File.extname(path.to_s).downcase]
    end

    # 注册表快照：{ '.txt' => :editor, ... }（拷贝，防外部改穿）
    def mappings
      @table.dup
    end
  end
end
