# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Pkg
    # 字节表示与转换：管线的二进制数据统一用 Array<Integer>（0..255）——
    # 纯 CRuby 可测，且 Opal 1.8 无 Array#pack/String#unpack 可依赖。
    # 字符串形态只出现在两个边界：
    # - latin1 串（每字符码 = 一字节）：.emz 在 VFS 文件节点 / 浏览器
    #   FileReader(atob) 里的形态 → from_latin1
    # - UTF-8 文本（manifest/源码）：字节数组 → to_utf8
    module Bytes
      # latin1 串 → 字节数组。CRuby 契约：入参必须是二进制串
      #（String#bytes 即原始字节）；UTF-8 多字节串进来会被按 UTF-8 编码
      # 拆字节，属于调用方错误。IIFE：表达式位置的 x-string 须为合法 JS 表达式。
      def self.from_latin1(str)
        return str.bytes unless defined?(Opal)

        `(function() { var out = []; for (var i = 0; i < str.length; i++) out.push(str.charCodeAt(i) & 0xff); return out; })()`
      end

      # 字节数组 → UTF-8 文本（包内源码/manifest 均为 UTF-8）
      def self.to_utf8(bytes)
        return pack(bytes) unless defined?(Opal)

        `new TextDecoder('utf-8').decode(new Uint8Array(bytes))`
      end

      # 字节数组 → latin1 串（VFS 文件节点存 .emz / 传给 JS 边界用）。
      # 单行 IIFE：多行 x-string 会被 Opal 语句化、返回值丢失（E7 教训）。
      def self.to_latin1(bytes)
        return pack(bytes) unless defined?(Opal)

        `(function() { var out = ''; for (var i = 0; i < bytes.length; i += 0x8000) { out += String.fromCharCode.apply(null, bytes.slice(i, i + 0x8000)); } return out; })()`
      end

      # 字节数组 → 文本（CRuby：pack('C*')；to_utf8/to_latin1 共用）
      def self.pack(bytes)
        bytes.pack('C*').force_encoding(Encoding::UTF_8)
      end
    end
  end
end
