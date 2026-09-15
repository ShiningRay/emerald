# frozen_string_literal: true

require 'rake/testtask'

CITRINE = ENV.fetch('CITRINE_PATH', '../citrine')
BERYL   = ENV.fetch('BERYL_PATH', '../beryl')

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << File.join(CITRINE, 'lib') << File.join(BERYL, 'lib')
  t.test_files = FileList['test/**/*_test.rb']
end

desc 'Opal 编译验收：整机示例可编译（浏览器侧语法门）'
task :compile do
  sh "bundle exec opal -c -I. -I#{File.join(CITRINE, 'lib')} -I#{File.join(BERYL, 'lib')} -Ilib -o examples/desktop.js examples/desktop.rb"
end

task default: %i[test compile]
