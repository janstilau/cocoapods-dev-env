require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.pattern = "test/**/*_test.rb"
  task.warning = false
end

task :default => :test
