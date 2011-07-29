# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require 'restfully/addons/version'

Gem::Specification.new do |s|
  s.name                      = "restfully-addons"
  s.version                   = Restfully::Addons::VERSION
  s.platform                  = Gem::Platform::RUBY
  s.required_ruby_version     = '>= 1.8'
  s.required_rubygems_version = ">= 1.3"
  s.authors                   = ["Cyril Rohr"]
  s.email                     = ["cyril.rohr@inria.fr"]
  s.homepage                  = "http://github.com/crohr/restfully-addons"
  s.summary                   = "Addons for Restfully"
  s.description               = "Addons for Restfully"

  s.add_dependency('restfully')
  s.add_dependency('net-ssh-gateway')
  s.add_dependency('net-scp')
  s.add_dependency('net-sftp')
  s.add_dependency('net-ssh-multi')
  s.add_dependency('libxml-ruby')

  s.add_development_dependency('rake', '~> 0.8')

  s.files = Dir.glob("{lib,examples}/**/*") + %w(Rakefile LICENSE README.md)

  # s.test_files = Dir.glob("spec/**/*")

  s.rdoc_options = ["--charset=UTF-8"]
  s.extra_rdoc_files = [
    "LICENSE",
    "README.md"
  ]

  s.require_path = 'lib'
end
