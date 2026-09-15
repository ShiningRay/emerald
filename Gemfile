# frozen_string_literal: true

source 'https://rubygems.org'

# citrine 已发 gem 但双仓同步演进：本地/CI 走 path。CI 用 CITRINE_PATH/BERYL_PATH 指兄弟目录
gem 'citrine', path: ENV.fetch('CITRINE_PATH', '../citrine')
gem 'citrine-beryl', path: ENV.fetch('BERYL_PATH', '../beryl'), require: 'beryl'

# Opal 编译验收（rake compile）本地与 CI 都要用
gem 'opal', '~> 1.8', require: false

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
