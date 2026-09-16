# frozen_string_literal: true
# backtick_javascript: true

module Emerald
  # 浏览器原生文件选择器（仅 Opal）：pick 触发系统文件对话框，选中后把文件
  # 读成字节 Array<Integer> 回给回调。Settings「应用管理」安装 .emz 的入口。
  # CRuby 下返回 nil（无对话框可弹；单测只验证渲染，不验证选择流）。
  module FilePick
    class << self
      # pick(accept: '.emz') { |filename, bytes| ... } → true（Opal）/ nil（CRuby）
      def pick(accept: '*', &callback)
        return nil unless defined?(Opal)

        %x{
          var input = document.createElement('input');
          input.type = 'file';
          input.accept = #{accept};
          input.onchange = function() {
            var f = input.files[0];
            if (!f) { return; }
            var reader = new FileReader();
            reader.onload = function() {
              var buf = new Uint8Array(reader.result);
              var bytes = new Array(buf.length);
              for (var i = 0; i < buf.length; i++) { bytes[i] = buf[i]; }
              #{callback.call(`f.name`, `bytes`)};
            };
            reader.readAsArrayBuffer(f);
          };
          input.click();
        }
        true
      end
    end
  end
end
