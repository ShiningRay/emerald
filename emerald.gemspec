# frozen_string_literal: true

Gem::Specification.new do |spec|
  # RubyGems 上 emerald 之名必被他人占用（对齐 citrine-beryl 先例：beryl 之名
  # 2018 年已被一个 Web framework 占用，发布名改用 citrine-beryl），发布名用
  # citrine-emerald；require 名保持 'emerald'（lib/emerald.rb），消费者
  # gem 'citrine-emerald' + require 'emerald'
  spec.name = 'citrine-emerald'
  spec.version = '0.1.0'
  spec.authors = ['ShiningRay']
  spec.email = ['tsowly@hotmail.com']

  spec.summary = 'Ruby Web 桌面操作系统（Citrine + Beryl 之上）'
  spec.description = 'Emerald：Beryl 桌面外壳之上的 Web 桌面操作系统——应用框架、' \
                     '虚拟文件系统、设置/主题、通知、快捷键、启动器与一组内置应用；' \
                     '经 Emerald::Standalone 可脱离桌面外壳独立运行单个应用。'
  spec.homepage = 'https://github.com/ShiningRay/emerald'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.7'

  spec.files = Dir['lib/**/*.rb', 'docs/*.md', 'README.md', 'LICENSE']
  # citrine/beryl 双仓同步演进，本地经 path / Opal -I 引用（见 Gemfile）；
  # 发布后切换为正式依赖：
  # spec.add_runtime_dependency 'citrine', '>= 0.1'
  # spec.add_runtime_dependency 'citrine-beryl', '>= 0.1'

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'opal', '~> 1.8'
end
