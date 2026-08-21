# Cocoapods Plugin: cocoapods-dev-env

cocoapods-dev-env is a useful plugin for cocoapods to manage your self-developing pods.

When we have too many pod to developing, maybe you only care about one or two pods in local, this plugin may be can help you.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'cocoapods-dev-env'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install cocoapods-dev-env

## Usage

In your podfile
```ruby
plugin 'cocoapods-dev-env'

pod 'SomePod', :git => 'xxxxxx', :branch => 'master', :tag => '0.0.2.2', :dev_env => 'dev'
```
We see a addtional key "dev_env" in defineation. And you must put "git", "branch", "tag" for the plugin.

1. When you define "dev_env" to "dev", and run ```pod install``` .  
We will add a ```git submodule``` linked to your pod git repo to local.  
And check if the ```HEAD``` commit id of the branch is same to ```tag```commit id.

2. When you define "dev_env" to "beta", and run ```pod install``` .  
We will use the ```tag```: "tag_beta", e.g.: "0.0.2.2_beta"  
When the local git submodule is exist, whe aslo try to check and add tag "tag_beta" on it and push to the origin.  
Finally the state clean submodule will be removed automatically.

3. When you define "dev_env" to "release", and run ```pod install``` . 
We want to use the release version in cocoapods repo. And do many check for state, and help you to release the not released pod.  

2.2.x 的 `use_parent_lock_info!` 只投影父 Podfile 的顶层依赖，保留用于兼容已有工程。

2.2.5+ 提供完整父工程环境模式：

```ruby
plugin 'cocoapods-dev-env'
use_parent_project_environment! :path => '../../../'

target 'Example' do
  pod 'CurrentPod', :path => '../'
  pod 'YDCommon', :dev_env => 'parent'
end
```

`use_parent_project_environment!` 会读取父 `Podfile.lock` 的完整 `PODS`、`SPEC REPOS`、
`EXTERNAL SOURCES` 和 `CHECKOUT OPTIONS`。子工程实际解析到的依赖默认使用父工程的精确
版本与 source；父工程中通过 path 引用的 Pod 会按父 lock 所在目录解析，再换算为子 Podfile
可用的相对路径。

当 `:dev_env => 'parent'` 声明 root Pod 时，会复用父 lock 中实际启用的 subspec。显式声明
某个 subspec 时只使用该 subspec：

```ruby
pod 'YDCommon/Echo', :dev_env => 'parent'
```

2.2.6 起，如果一个 root 只通过 podspec 传递依赖变得可达，也会复用父 lock 为该 root
实际启用的 subspec；子 Podfile 已直接声明的 root 或 subspec 仍保持自身明确选择。这样不需要
把传递依赖提升成子 Podfile 的伪直接依赖。

子 Podfile 的显式 version、`:source`、`:git` 或 `:path` 是有意覆盖；未覆盖的依赖仍继承父
环境。未显式覆盖且父 lock 中不存在的依赖会直接报错，不会静默选择其他版本或 source。
        


## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/YoudaoMobile/cocoapods-dev-env. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

### prepare
install gem bundler:  
    
    gem install bundler

create Gemfile:
    
    bundler init

edit GemFile for local path, e.g.:

    gem 'cocoapods'
    gem 'cocoapods-dev-env', :path => '../cocoapods-dev-env'

### debug and package
1. How to develop: put gem in your project and exec `bundle exec pod install`
2. How to packagae: `rake build` 
3. How to release: `rake release` or `gem push ./pkg/cocoapods-dev-env-2.2.4.gem` 


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Cocoapods::Dev::Env project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/YoudaoMobile/cocoapods-dev-env/blob/master/CODE_OF_CONDUCT.md).


## warning

pod有bug，当某个库由于新引入的库依赖了更多子库的项，需要下载时，会通过根名称去寻找下载的source。比如 原本引用YDCommon/Core 通过 YDUser 又引入了 YDCommon/UI， 再次pod install时 系统判定 YDCommon的引用有变化，需要重新下载，这时不会通过podfile里定义的YDCommon/Core的源去下载，而是仅仅使用sandbox中YDCommon的版本去寻找，导致下载报错。 目前一个绕过的方法是在podfile中也定义一下YDCommon这个根的地址
