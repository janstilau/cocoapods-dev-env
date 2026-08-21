# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'pathname'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'cocoapods_plugin'

class ResolverSearchBase
  attr_reader :received_dependency

  def search_for(dependency)
    @received_dependency = dependency
    []
  end
end

class ResolverSearchHarness < ResolverSearchBase
  prepend Pod::Resolver::ParentProjectEnvironmentResolver
end

class ParentProjectEnvironmentTest < Minitest::Test
  def setup
    @temporary_directory = Pathname.new(Dir.mktmpdir('cocoapods-dev-env-test-'))
    @parent_directory = @temporary_directory.join('Parent', 'Example')
    @consumer_directory = @temporary_directory.join('ChildPod', 'Example')
    @parent_directory.mkpath
    @consumer_directory.mkpath
    @parent_directory.join('developing_pods', 'LocalRoot').mkpath
    @lockfile_path = @parent_directory.join('Podfile.lock')
    @lockfile_path.write(parent_lock_contents)
    reset_plugin_state
  end

  def teardown
    reset_plugin_state
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory.exist?
  end

  def test_indexes_transitive_roots_versions_sources_subspecs_and_parent_paths
    environment = load_environment

    assert_equal %w[GitRoot LocalRoot Transitive], environment.dependencies.keys.sort
    assert_equal ['Core', 'Feature'], environment.subspecs_for('LocalRoot')

    transitive = environment.dependency_for('Transitive')
    assert_equal '= 2.3.0', transitive.requirement.to_s
    assert_equal 'private-specs', transitive.podspec_repo

    expected_path = @parent_directory
      .join('developing_pods', 'LocalRoot')
      .relative_path_from(@consumer_directory)
      .to_s
    assert_equal expected_path, environment.dependency_for('LocalRoot').external_source[:path]
    assert_equal 'abc123', environment.checkout_options_for('GitRoot')[:commit]
  end

  def test_constrains_transitive_dependency_to_parent_version_and_source
    environment = load_environment
    dependency = Pod::Dependency.new('Transitive', '~> 2.0')

    constrained = environment.constrain(dependency)

    assert constrained.requirement.satisfied_by?(Pod::Version.new('2.3.0'))
    refute constrained.requirement.satisfied_by?(Pod::Version.new('2.4.0'))
    assert_equal 'private-specs', constrained.podspec_repo
  end

  def test_explicit_child_version_overrides_parent_version_but_keeps_parent_source
    environment = load_environment
    Pod::DevEnv.register_parent_dependency_override(
      'Transitive',
      requirements: ['2.4.0'],
      podspec_repo: nil,
      external_source: {},
      full: false,
    )

    constrained = environment.constrain(Pod::Dependency.new('Transitive'))

    assert constrained.requirement.satisfied_by?(Pod::Version.new('2.4.0'))
    refute constrained.requirement.satisfied_by?(Pod::Version.new('2.3.0'))
    assert_equal 'private-specs', constrained.podspec_repo
  end

  def test_parent_declaration_can_explicitly_override_version
    podfile_path = @consumer_directory.join('Podfile')
    relative_parent = @parent_directory.relative_path_from(@consumer_directory)
    podfile_path.write(<<~RUBY)
      use_parent_project_environment! :path => #{relative_parent.to_s.inspect}

      target 'Child' do
        pod 'Transitive', '2.4.0', :dev_env => 'parent'
      end
    RUBY

    podfile = Pod::Podfile.from_file(podfile_path)
    dependency = podfile.dependencies.fetch(0)
    constrained = Pod::DevEnv.parent_project_environment.constrain(dependency)

    assert constrained.requirement.satisfied_by?(Pod::Version.new('2.4.0'))
    refute constrained.requirement.satisfied_by?(Pod::Version.new('2.3.0'))
    assert_equal 'private-specs', constrained.podspec_repo
  end

  def test_parent_declaration_inherits_complete_git_source_and_checkout
    podfile_path = @consumer_directory.join('Podfile')
    relative_parent = @parent_directory.relative_path_from(@consumer_directory)
    podfile_path.write(<<~RUBY)
      use_parent_project_environment! :path => #{relative_parent.to_s.inspect}

      target 'Child' do
        pod 'GitRoot', :dev_env => 'parent'
      end
    RUBY

    podfile = Pod::Podfile.from_file(podfile_path)
    dependency = podfile.dependencies.fetch(0)
    constrained = Pod::DevEnv.parent_project_environment.constrain(dependency)

    assert_equal 'https://example.com/GitRoot.git', constrained.external_source[:git]
    assert_equal 'main', constrained.external_source[:branch]
    assert_equal 'abc123', Pod::DevEnv.parent_project_environment.checkout_options_for('GitRoot')[:commit]
  end

  def test_explicit_child_path_is_not_replaced_by_parent_path
    environment = load_environment
    dependency = Pod::Dependency.new('LocalRoot', :path => '../')
    Pod::DevEnv.register_parent_dependency_override(
      'LocalRoot',
      requirements: [],
      podspec_repo: nil,
      external_source: { :path => '../' },
      full: false,
    )

    constrained = environment.constrain(dependency)

    assert_equal '../', constrained.external_source[:path]
  end

  def test_explicit_version_and_specs_source_can_replace_parent_path_source
    environment = load_environment
    Pod::DevEnv.register_parent_dependency_override(
      'LocalRoot',
      requirements: ['1.1.0'],
      podspec_repo: 'replacement-specs',
      external_source: {},
      full: false,
    )

    constrained = environment.constrain(Pod::Dependency.new('LocalRoot'))

    assert_nil constrained.external_source
    assert constrained.requirement.satisfied_by?(Pod::Version.new('1.1.0'))
    refute constrained.requirement.satisfied_by?(Pod::Version.new('1.0.0'))
    assert_equal 'replacement-specs', constrained.podspec_repo
  end

  def test_explicit_specs_source_keeps_parent_locked_version_when_replacing_parent_path
    environment = load_environment
    Pod::DevEnv.register_parent_dependency_override(
      'LocalRoot',
      requirements: [],
      podspec_repo: 'replacement-specs',
      external_source: {},
      full: false,
    )

    constrained = environment.constrain(Pod::Dependency.new('LocalRoot'))

    assert_nil constrained.external_source
    assert constrained.requirement.satisfied_by?(Pod::Version.new('1.0.0'))
    refute constrained.requirement.satisfied_by?(Pod::Version.new('1.0.1'))
    assert_equal 'replacement-specs', constrained.podspec_repo
  end

  def test_lockfile_does_not_restore_parent_external_source_after_specs_override
    environment = load_environment
    Pod::DevEnv.register_parent_dependency_override(
      'LocalRoot',
      requirements: ['1.1.0'],
      podspec_repo: 'replacement-specs',
      external_source: {},
      full: false,
    )
    harness = lockfile_generate_harness

    lockfile = harness.generate(nil, [Struct.new(:name).new('LocalRoot')], {})

    refute lockfile.internal_data.fetch('EXTERNAL SOURCES', {}).key?('LocalRoot')
  end

  def test_lockfile_persists_inherited_parent_external_source
    environment = load_environment
    harness = lockfile_generate_harness

    lockfile = harness.generate(nil, [Struct.new(:name).new('LocalRoot')], {})

    assert_equal(
      '../../Parent/Example/developing_pods/LocalRoot',
      lockfile.internal_data.fetch('EXTERNAL SOURCES').fetch('LocalRoot')[:path],
    )
  end

  def test_resolver_hook_applies_parent_constraint_before_cocoapods_search
    load_environment
    resolver = ResolverSearchHarness.new

    resolver.search_for(Pod::Dependency.new('Transitive', '~> 2.0'))

    dependency = resolver.received_dependency
    assert dependency.requirement.satisfied_by?(Pod::Version.new('2.3.0'))
    refute dependency.requirement.satisfied_by?(Pod::Version.new('2.4.0'))
    assert_equal 'private-specs', dependency.podspec_repo
  end

  def test_parent_root_declaration_expands_parent_selected_subspecs
    podfile_path = @consumer_directory.join('Podfile')
    relative_parent = @parent_directory.relative_path_from(@consumer_directory)
    podfile_path.write(<<~RUBY)
      use_parent_project_environment! :path => #{relative_parent.to_s.inspect}

      target 'Child' do
        pod 'LocalRoot', :dev_env => 'parent'
      end
    RUBY

    podfile = Pod::Podfile.from_file(podfile_path)
    dependencies = podfile.dependencies

    assert_equal ['LocalRoot/Core', 'LocalRoot/Feature'], dependencies.map(&:name).sort
    dependencies.each do |dependency|
      constrained = Pod::DevEnv.parent_project_environment.constrain(dependency)
      assert_equal '../../Parent/Example/developing_pods/LocalRoot', constrained.external_source[:path]
    end
  end

  def test_parent_subspec_declaration_does_not_expand_siblings
    podfile_path = @consumer_directory.join('Podfile')
    relative_parent = @parent_directory.relative_path_from(@consumer_directory)
    podfile_path.write(<<~RUBY)
      use_parent_project_environment! :path => #{relative_parent.to_s.inspect}

      target 'Child' do
        pod 'LocalRoot/Core', :dev_env => 'parent'
      end
    RUBY

    podfile = Pod::Podfile.from_file(podfile_path)

    assert_equal ['LocalRoot/Core'], podfile.dependencies.map(&:name)
  end

  def test_unconfigured_transitive_dependency_missing_from_parent_fails
    environment = load_environment

    error = assert_raises(Pod::Informative) do
      environment.constrain(Pod::Dependency.new('MissingPod'))
    end

    assert_includes error.message, 'Parent Podfile.lock does not contain MissingPod'
  end

  def test_legacy_parent_lock_mode_still_indexes_only_direct_dependencies
    relative_parent = @parent_directory.relative_path_from(@consumer_directory).to_s + '/'
    Dir.chdir(@consumer_directory) do
      $parrentPath = relative_parent
      Pod::Podfile.readParrentLockFile
    end

    assert_equal %w[GitRoot LocalRoot], $parentPodlockDependencyHash.keys.sort
    refute $parentPodlockDependencyHash.key?('Transitive')
    assert_equal(
      "#{relative_parent}developing_pods/LocalRoot",
      $parentPodlockDependencyHash.fetch('LocalRoot').external_source[:path],
    )
  end

  private

  def load_environment
    environment = Pod::DevEnv::ParentProjectEnvironment.load(
      @parent_directory,
      consumer_directory: @consumer_directory,
    )
    Pod::DevEnv.parent_project_environment = environment
    environment
  end

  def lockfile_generate_harness
    Class.new do
      def self.generate(_podfile, _specs, _checkout_options, _spec_repos = {})
        Pod::Lockfile.new({})
      end

      class << self
        prepend Pod::DevEnv::ParentEnvironmentLockfile
      end
    end
  end

  def reset_plugin_state
    Pod::DevEnv.parent_project_environment = nil
    Pod::DevEnv.reset_parent_dependency_overrides!
    $parentPodlockDependencyHash = {}
    $processedParentPods = {}
    $processedPodsOptions = {}
    $podFileContentPodNameHash = {}
  end

  def parent_lock_contents
    <<~YAML
      PODS:
        - LocalRoot (1.0.0):
          - LocalRoot/Core
          - LocalRoot/Feature
          - Transitive (~> 2.0)
        - LocalRoot/Core (1.0.0)
        - LocalRoot/Feature (1.0.0)
        - GitRoot (4.0.0)
        - Transitive (2.3.0)
      DEPENDENCIES:
        - GitRoot (from `https://example.com/GitRoot.git`, branch `main`)
        - LocalRoot (from `developing_pods/LocalRoot`)
      SPEC REPOS:
        private-specs:
          - Transitive
      EXTERNAL SOURCES:
        GitRoot:
          :branch: main
          :git: https://example.com/GitRoot.git
        LocalRoot:
          :path: developing_pods/LocalRoot
      CHECKOUT OPTIONS:
        GitRoot:
          :commit: abc123
          :git: https://example.com/GitRoot.git
      SPEC CHECKSUMS:
        LocalRoot: local-root-checksum
        Transitive: transitive-checksum
      PODFILE CHECKSUM: parent-checksum
      COCOAPODS: 1.16.2
    YAML
  end
end
