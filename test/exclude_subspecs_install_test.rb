# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'pathname'
require 'tmpdir'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'cocoapods_plugin'

# Exercise CocoaPods resolution, target membership and generated lockfiles with
# local source Pods. No remote Specs, SDK downloads or app build are needed.
class ExcludeSubspecsInstallTest < Minitest::Test
  def setup
    @directory = Pathname.new(Dir.mktmpdir('dev-env-exclude-install-'))
    @parent = @directory.join('Parent')
    @child = @directory.join('Child')
    @parent.mkpath
    @child.mkpath
    write_spec('Current', "s.dependency 'Shared/Core'")
    write_spec('Shared', <<~RUBY)
      s.default_subspecs = 'Core'
      s.subspec('Core') { |sp| sp.source_files = 'Sources/*' }
      s.subspec('Feature') do |sp|
        sp.source_files = 'Sources/*'
        sp.dependency 'FeatureSDK/Core'
      end
    RUBY
    write_spec('FeatureSDK', <<~RUBY)
      s.subspec('Core') { |sp| sp.source_files = 'Sources/*' }
      s.subspec('Extra') { |sp| sp.source_files = 'Sources/*' }
    RUBY
    @parent.join('Podfile.lock').write(<<~YAML)
      PODS:
        - Current (1.0.0):
          - Shared/Core
        - Shared/Core (1.0.0)
        - Shared/Feature (1.0.0):
          - FeatureSDK/Core
        - FeatureSDK/Core (1.0.0)
        - FeatureSDK/Extra (1.0.0)
      DEPENDENCIES:
        - Current (from `Current`)
        - Shared (from `Shared`)
        - FeatureSDK (from `FeatureSDK`)
      EXTERNAL SOURCES:
        Current:
          :path: Current
        Shared:
          :path: Shared
        FeatureSDK:
          :path: FeatureSDK
      COCOAPODS: 1.16.2
    YAML
  end

  def teardown
    Pod::Podfile.cleanParrentLockFile
    FileUtils.remove_entry(@directory)
  end

  def test_transitive_exclusion_removes_feature_and_sdk_from_installation
    installer = install(exclusions: ['Shared/Feature'])
    assert_equal ['Current', 'Shared/Core'], installer.lockfile.pod_names.sort
    assert_equal %w[Current Shared], installer.pod_targets.map(&:pod_name).sort
    assert_equal ['Shared/Core'], installer.pod_targets.find { |target| target.pod_name == 'Shared' }.specs.map(&:name)
    assert_equal '../Parent/Shared', installer.lockfile.internal_data.fetch('EXTERNAL SOURCES').fetch('Shared')[:path]
    assert_equal '1.0.0', installer.lockfile.version('Shared').to_s
    assert_equal @child.join('Podfile.lock').read, @child.join('Pods/Manifest.lock').read
  end

  def test_direct_parent_root_exclusion_removes_feature_and_sdk
    installer = install(exclusions: ['Shared/Feature'], declaration: "pod 'Shared', :dev_env => 'parent'")
    assert_equal ['Current', 'Shared/Core'], installer.lockfile.pod_names.sort
  end

  def test_without_exclusion_keeps_parent_subspecs_and_transitive_sdk
    installer = install(exclusions: [])
    assert_equal ['Current', 'FeatureSDK/Core', 'FeatureSDK/Extra', 'Shared/Core', 'Shared/Feature'], installer.lockfile.pod_names.sort
  end

  def test_real_podspec_requirement_fails_instead_of_removing_dependency
    write_spec('Current', "s.dependency 'Shared/Feature'")
    error = assert_raises(Pod::Informative) { install(exclusions: ['Shared/Feature']) }
    assert_includes error.message, 'Current requires Shared/Feature'
    refute @child.join('Podfile.lock').exist?
  end

  def test_existing_installation_can_remove_inherited_feature_without_pod_update
    install(exclusions: [])
    installer = install(exclusions: ['Shared/Feature'])
    assert_equal ['Current', 'Shared/Core'], installer.lockfile.pod_names.sort
    assert_equal %w[Current Shared], installer.pod_targets.map(&:pod_name).sort
  end

  def test_sdk_remains_when_another_pod_requires_it
    write_spec('Current', "s.dependency 'Shared/Core'\ns.dependency 'FeatureSDK/Core'")
    installer = install(exclusions: ['Shared/Feature'])
    assert_equal ['Current', 'FeatureSDK/Core', 'Shared/Core'], installer.lockfile.pod_names.sort
  end

  def test_excluded_default_subspec_is_reported_as_a_conflict
    write_spec('Current', "s.dependency 'Shared'")
    spec_path = @parent.join('Shared/Shared.podspec')
    spec_path.write(spec_path.read.sub("s.default_subspecs = 'Core'", "s.default_subspecs = 'Feature'"))
    error = assert_raises(Pod::Informative) { install(exclusions: ['Shared/Feature']) }
    assert_includes error.message, 'Shared/Feature'
    assert_includes error.message, 'exclude_subspecs'
  end

  def test_removing_exclusion_restores_parent_selection_with_existing_lockfile
    install(exclusions: ['Shared/Feature'])
    installer = install(exclusions: [])
    assert_equal ['Current', 'FeatureSDK/Core', 'FeatureSDK/Extra', 'Shared/Core', 'Shared/Feature'], installer.lockfile.pod_names.sort
  end

  def test_exclusion_applies_to_multiple_targets
    installer = install(exclusions: ['Shared/Feature'], additional_targets: <<~RUBY)
      target 'Other' do
        pod 'Shared', :dev_env => 'parent'
      end
    RUBY
    assert_equal ['Current', 'Shared/Core'], installer.lockfile.pod_names.sort
    assert_equal 2, installer.aggregate_targets.size
    installer.aggregate_targets.each do |target|
      assert_includes target.pod_targets.flat_map { |pod| pod.specs.map(&:name) }, 'Shared/Core'
      refute_includes target.pod_targets.flat_map { |pod| pod.specs.map(&:name) }, 'Shared/Feature'
    end
  end

  def test_second_target_cannot_override_global_exclusion
    error = assert_raises(Pod::Informative) do
      install(exclusions: ['Shared/Feature'], additional_targets: <<~RUBY)
        target 'Other' do
          pod 'Shared/Feature', :dev_env => 'parent'
        end
      RUBY
    end
    assert_includes error.message, 'Child Podfile requires Shared/Feature'
  end

  private

  def write_spec(name, body)
    directory = @parent.join(name)
    directory.join('Sources').mkpath
    directory.join('Sources', "#{name}.m").write("void #{name}Placeholder(void) {}\n")
    directory.join("#{name}.podspec").write(<<~RUBY)
      Pod::Spec.new do |s|
        s.name = #{name.inspect}
        s.version = '1.0.0'
        s.summary = 'Local test fixture'
        s.homepage = 'https://example.invalid'
        s.author = 'Test'
        s.license = { :type => 'MIT', :text => 'Fixture' }
        s.source = { :git => 'https://example.invalid/#{name}.git' }
        s.ios.deployment_target = '13.0'
        s.source_files = 'Sources/*'
        #{body}
      end
    RUBY
  end

  def install(exclusions:, declaration: '', additional_targets: '')
    podfile_path = @child.join('Podfile')
    podfile_path.write(<<~RUBY)
      use_parent_project_environment! :path => '../Parent', :exclude_subspecs => #{exclusions.inspect}
      install! 'cocoapods', :integrate_targets => false, :warn_for_unused_master_specs_repo => false
      platform :ios, '13.0'
      target 'Child' do
        pod 'Current', :path => '../Parent/Current'
        #{declaration}
      end
      #{additional_targets}
    RUBY
    Pod::Config.instance.with_changes(
      :installation_root => @child,
      :podfile_path => podfile_path,
      :lockfile_path => @child.join('Podfile.lock'),
      :silent => true,
    ) do
      podfile = Pod::Podfile.from_file(podfile_path)
      lock_path = @child.join('Podfile.lock')
      lockfile = Pod::Lockfile.from_file(lock_path) if lock_path.exist?
      installer = Pod::Installer.new(Pod::Sandbox.new(@child.join('Pods')), podfile, lockfile)
      installer.repo_update = false
      installer.install!
      installer
    end
  end
end
