# frozen_string_literal: true

module Emerald
  module Pkg
    # 可分发源码应用管线（docs/PLAN.md §3.10 / 决策 D11–D12；
    # 格式标准见 docs/SPEC-package-format.md）：
    #
    #   Source.parse → Manifest.parse → Installer（zip/目录/git）→
    #   VFS /Applications/<id>/ + Lock(installed.json) → AppHost 扫描注册
    #
    # 字节底座（Bytes/Sha256/Inflate/Zip）为纯 Ruby 实现：opal 1.8.3 无
    # Zlib/Digest/pack('C*')，且管线必须 CRuby/Opal 同构可测（beryl F5 纪律）。
    # 二进制数据统一表示为 Array<Integer>（0..255）。
  end
end

require_relative 'pkg/json'
require_relative 'pkg/manifest'
require_relative 'pkg/source'
require_relative 'pkg/bytes'
require_relative 'pkg/sha256'
require_relative 'pkg/inflate'
require_relative 'pkg/zip'
require_relative 'pkg/lock'
require_relative 'pkg/installer'
require_relative 'pkg/apphost'
require_relative 'pkg/opal_parser'

module Emerald
  module Pkg
    # 统一错误别名：管线各层 raise 的 Invalid 都是 Json::Invalid（测试断言方便）
    Invalid = Json::Invalid
  end
end
