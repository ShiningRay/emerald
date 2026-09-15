# frozen_string_literal: true

source 'https://rubygems.org'

gemspec
# citrine/beryl 双仓同步演进：本地/CI 经 path 引用。CI 用 CITRINE_PATH/BERYL_PATH 指兄弟目录
gem 'citrine', path: ENV.fetch('CITRINE_PATH', '../citrine')
gem 'citrine-beryl', path: ENV.fetch('BERYL_PATH', '../beryl'), require: 'beryl'

# Opal 编译验收（rake compile / standalone）本地与 CI 都要能用
gem 'opal', '~> 1.8', require: false
