# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Pkg
    # opal-parser 懒加载适配（D12）：编译源码应用（安装 .emz / Editor 改包源码）
    # 才需要 Ruby→JS 编译器。parser 是独立 chunk（desktop-parser.js），不进
    # 核心 bundle、不占 300KB gzip 预算。
    #
    # 加载策略：shell 启动时异步 preload（HTTP 缓存接管后续）；真正编译时若
    # 尚未就绪，用同步 XHR 兜底拉取再 eval（同源请求，弃用警告可接受——
    # 安装器管线是同步契约，不做 Promise 化重构）。
    # 仅 Opal 可用；CRuby 引用即 NameError（编译器应注入伪实现，见 AppHost）。
    module OpalParser
      PARSER_SRC = 'desktop-parser.js'

      ParseUnavailable = Class.new(StandardError)

      class << self
        # shell 启动时调用：异步预取 parser chunk（不阻塞首渲染）。
        # IIFE：表达式位置的 x-string 须为合法 JS 表达式（E7 实施教训）。
        def preload
          return nil unless defined?(Opal)
          return nil if loaded?

          `(function() { var s = document.createElement('script'); s.src = #{PARSER_SRC}; s.async = true; document.head.appendChild(s); })()`
          nil
        end

        def loaded?
          `typeof Opal !== 'undefined' && typeof Opal.compile === 'function'`
        end

        # Ruby 源码 → JS 文本（AppHost compiler 的浏览器实体）
        def compile(src)
          ensure_loaded!
          `Opal.compile(src)`
        end

        # 同步执行 Opal.compile 产物（AppHost loader 的浏览器实体）。
        # 产物是 Opal.queue(fn) 包装；runtime 在 last_promise 存在时会把它
        # 排进 Promise 微任务链——evaluate! 需要类定义**同步可见**，故临时
        # 接管 queue 收集模块函数、恢复后立即逐个调用（单文件源码包的模块
        # 体是同步类定义，无动态 require，同步执行安全）。
        # js 必须经 String() 原生化：VFS 读出的字符串可能是 boxed String
        # 对象，eval 对它不执行、静默返回（E7 浏览器验收发现的坑）。
        def run_module(js)
          ran = `[]`
          %x{
            var orig = Opal.queue;
            Opal.queue = function(proc) { ran.push(proc); };
            try { (0, eval)(String(js)); } finally { Opal.queue = orig; }
            for (var i = 0; i < ran.length; i++) ran[i](Opal);
          }
          ran.length
        end

        private

        def ensure_loaded!
          return if loaded?

          # 多行 %x{} 在方法中部 = 语句位置，原样嵌入；常量经 #{} 插值编译
          %x{
            var x = new XMLHttpRequest();
            x.open('GET', #{PARSER_SRC}, false);
            x.send(null);
            if (x.status === 200 || (x.status === 0 && x.responseText)) {
              (0, eval)(x.responseText);
            } else {
              self.$raise(#{ParseUnavailable}, 'opal-parser 加载失败（HTTP ' + x.status + '）');
            }
          }
          return if loaded?

          raise ParseUnavailable, 'opal-parser 加载失败（chunk 无效）'
        end
      end
    end
  end
end
