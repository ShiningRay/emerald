# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Pkg
    # JSON 读取（docs/SPEC-package-format.md §3 manifest.json 的解析入口）。
    # parse 返回 Ruby Hash（字符串键），CRuby 与 Opal 行为一致：
    # - CRuby：::JSON（宿主按需加载；本文件不许出现字面量 require，否则
    #   opal -c 会把 'json' 当静态依赖、编译即失败）；
    # - Opal：JS JSON.parse → Storage.from_native 递归转 Ruby（裸 JS 对象无
    #   is_a?/[] 可言，见 storage.rb 的 E7 前置修复）；异常在 JS 层就地转
    #   Invalid，不让裸 JS 错误穿过 Ruby rescue 链。
    module Json
      # => Hash（顶层必须是 JSON 对象）；非法 JSON / 顶层非对象 → Invalid。
      # Opal 分支注意：%x{} 经 if/else 表达式赋值时返回值会被编译器丢弃
      #（E7 实施教训），必须「先声明 Ruby 局部变量、%x 语句内赋值」。
      def self.parse(str)
        raise Invalid, '内容不是字符串' unless str.is_a?(String)

        hash = defined?(Opal) ? opal_parse(str) : cruby_parse(str)
        raise Invalid, '顶层必须是 JSON 对象' unless hash.is_a?(Hash)

        hash
      end

      def self.opal_parse(str)
        hash = nil
        %x{
          try { hash = self.$from_native(JSON.parse(str)); }
          catch (e) { self.$raise(#{Invalid}, 'JSON 语法错误: ' + e.message); }
        }
        hash
      end

      # native JS 值 → Ruby（复用 storage 的转换器；CRuby 下原样返回）
      def self.from_native(obj)
        Emerald::Storage.from_native(obj)
      end

      # Invalid：包内容不合法的统一错误（manifest/source 共用）。
      Invalid = Class.new(ArgumentError)

      def self.cruby_parse(str)
        Kernel.send(:require, 'json') unless defined?(::JSON)
        ::JSON.parse(str)
      rescue ::JSON::ParserError => e
        raise Invalid, "JSON 语法错误: #{e.message}"
      end

      # Ruby 对象 → JSON 文本（lock 落 VFS 用）。只接受 Hash/Array/标量树
      #（from_native 产出的形态），CRuby ::JSON.generate / Opal JSON.stringify。
      def self.generate(obj)
        return ::JSON.generate(obj) unless defined?(Opal)

        `JSON.stringify(#{obj.to_n})`
      end
    end
  end
end
