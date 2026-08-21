# frozen_string_literal: true

require 'cocoapods'
require 'dev_env_entry'
require 'parent_project_environment'

$parentPodlockDependencyHash = Hash.new
$processedParentPods = Hash.new

module Pod
  class Dependency
    # Kept for compatibility with the legacy parent-lock implementation.
    def setRequirement(requirement)
      @requirement = requirement
    end
  end

  class Resolver
    module ParentProjectEnvironmentResolver
      def search_for(dependency)
        environment = DevEnv.parent_project_environment
        if environment
          dependency = environment.constrain(dependency)
          fetch_parent_external_source(dependency)
        else
          dependency = apply_legacy_parent_lock(dependency)
        end
        super(dependency)
      end

      private

      def apply_legacy_parent_lock(dependency)
        return dependency if $podFileContentPodNameHash.key?(dependency.root_name)

        parent_dependency = $parentPodlockDependencyHash[dependency.root_name]
        return dependency unless parent_dependency

        dependency.external_source = parent_dependency.external_source
        dependency.setRequirement(parent_dependency.requirement)
        dependency.podspec_repo = parent_dependency.podspec_repo
        fetch_parent_external_source(dependency)
        dependency
      end

      def fetch_parent_external_source(dependency)
        return unless dependency.external_source
        return if $processedParentPods.key?(dependency.root_name)

        $processedParentPods[dependency.root_name] = true
        environment = DevEnv.parent_project_environment
        override = DevEnv.parent_dependency_override(dependency.root_name)
        checkout_options = environment&.checkout_options_for(dependency.root_name) || {}
        use_parent_checkout = checkout_options.any? && !override&.external_source&.any?
        source = if use_parent_checkout
                   ExternalSources.from_params(
                     checkout_options,
                     dependency,
                     podfile.defined_in_file,
                     true,
                   )
                 else
                   ExternalSources.from_dependency(dependency, podfile.defined_in_file, true)
                 end
        source.fetch(sandbox)
      end
    end

    prepend ParentProjectEnvironmentResolver
  end

  class Podfile
    module DSL
      # Enables complete parent-project inheritance. Unlike
      # use_parent_lock_info!, this indexes the entire PODS closure and applies
      # the parent version/source to transitive dependencies as well.
      def use_parent_project_environment!(option)
        unless option.is_a?(Hash) && option.key?(:path)
          raise ArgumentError, "Got `#{option.inspect}`, expected :path => 'parent/Podfile.lock directory'"
        end

        consumer_directory = if defined_in_file
                               Pathname.new(defined_in_file).dirname
                             else
                               Pathname.pwd
                             end
        environment = DevEnv::ParentProjectEnvironment.load(
          option.fetch(:path),
          consumer_directory: consumer_directory,
        )
        DevEnv.parent_project_environment = environment
        DevEnv.reset_parent_dependency_overrides!
        $parentPodlockDependencyHash = environment.dependencies
        $processedParentPods = Hash.new
        $processedPodsOptions = Hash.new
        $podFileContentPodNameHash = Hash.new
        $parrentPath = environment.relative_parent_directory
        $parrentPath += '/' unless $parrentPath.end_with?('/')
        UI.puts "cocoapods-dev-env: parent project environment loaded (#{environment.dependencies.length} roots)"
      end

      # Legacy 2.2.x behavior. New integrations should use
      # use_parent_project_environment! instead.
      def use_parent_lock_info!(option = true)
        case option
        when true, false
          unless option
            $parrentPath = ''
            Podfile.cleanParrentLockFile
          end
        when Hash
          $parrentPath = option.fetch(:path)
          Podfile.readParrentLockFile
        else
          raise ArgumentError, "Got `#{option.inspect}`, should be a boolean or hash."
        end
      end
    end

    def self.cleanParrentLockFile
      $parentPodlockDependencyHash = Hash.new
      $processedParentPods = Hash.new
      DevEnv.parent_project_environment = nil
      DevEnv.reset_parent_dependency_overrides!
    end

    # Legacy direct-dependency projection retained for compatibility.
    def self.readParrentLockFile
      local_path = Pathname.new(Dir.pwd + '/' + $parrentPath)
      lock_path = local_path + 'Podfile.lock'
      lockfile = Lockfile.from_file(lock_path)
      unless lockfile
        UI.message "dev_env, 读取父库的lockfile找不到对应路径的lock文件:#{lock_path.inspect}"
        return
      end

      local_pods_map = {}
      lockfile.dependencies.each do |original_dependency|
        dependency = original_dependency.dup
        next if local_pods_map.key?(dependency.root_name)
        next if dependency.external_source.nil? && dependency.requirement.nil?

        if dependency.external_source.nil? && dependency.requirement.to_s == '>= 0'
          version = lockfile.version(dependency.root_name)
          dependency.setRequirement(Requirement.new(version))
          dependency.podspec_repo = lockfile.spec_repo(dependency.root_name)
        end
        if dependency.local?
          dependency.external_source = dependency.external_source.dup
          dependency.external_source[:path] = $parrentPath + dependency.external_source[:path]
        end
        local_pods_map[dependency.root_name] = dependency
      end
      $parentPodlockDependencyHash = local_pods_map
    end

    Podfile.readParrentLockFile
  end
end
