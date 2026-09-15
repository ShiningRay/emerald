# frozen_string_literal: true

# opal-parser 独立 chunk 的编译入口（E7 · D12 懒加载，docs/PLAN.md §3.10）：
#   bundle exec rake parser_chunk   # 产出 examples/desktop-parser.js
# 核心桌面 bundle 不 require 本文件；安装 .emz / 编辑源码应用时按需加载。
require 'opal-parser'
