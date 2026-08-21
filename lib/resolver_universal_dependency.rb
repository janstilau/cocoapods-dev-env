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

      # A root reached only through podspec dependencies has no textual
      # Podfile declaration whose :subspecs can be expanded. Recreate the
      # parent's selected subspec closure when that root becomes reachable,
      # while leaving every direct child Podfile root/subspec choice intact.
      def dependencies_for(specification)
        dependencies = super
        environment = DevEnv.parent_project_environment
        return dependencies unless environment

        root_name = Specification.root_name(specification.name)
        return dependencies unless specification.name == root_name
        return dependencies if DevEnv.direct_parent_environment_root?(root_name)

        override = DevEnv.parent_dependency_override(root_name)
        return dependencies if override&.explicit?

        inherited = environment.subspecs_for(root_name).map do |subspec|
          Dependency.new("#{root_name}/#{subspec}").tap do |dependency|
            dependency.specific_version = specification.version
          end
        end
        (dependencies + inherited).uniq
      end

      # CocoaPods resolves the synthetic parent-subspecced edges above, but its
      # target filter later replays only dependencies declared by the original
      # podspec. Reattach the already-resolved sibling vertices, plus their
      # valid dependency edges, to each target that reaches that transitive
      # root. This changes target membership only; it never adds an unrelated
      # parent root to the resolution graph.
      def resolver_specs_by_target
        specs_by_target = super
        environment = DevEnv.parent_project_environment
        return specs_by_target unless environment && @activated

        specs_by_target.each do |target, resolved_specs|
          selected = resolved_specs.each_with_object({}) do |resolver_spec, result|
            result[resolver_spec.name] = resolver_spec
          end
          queue = resolved_specs.each_with_object([]) do |resolver_spec, result|
            vertex = @activated.vertex_named(resolver_spec.name)
            result << [vertex, resolver_spec.used_by_non_library_targets_only?] if vertex
          end

          add_vertex = lambda do |vertex, used_by_non_library_targets_only|
            next if vertex.nil? || selected.key?(vertex.name)

            validate_platform(vertex.payload, target)
            payload = vertex.payload
            source = payload.respond_to?(:spec_source) && payload.spec_source
            resolver_spec = ResolverSpecification.new(
              payload,
              used_by_non_library_targets_only,
              source,
            )
            selected[vertex.name] = resolver_spec
            queue << [vertex, used_by_non_library_targets_only]
          end

          until queue.empty?
            vertex, used_by_non_library_targets_only = queue.shift
            root_name = Specification.root_name(vertex.name)
            unless DevEnv.direct_parent_environment_root?(root_name)
              environment.subspecs_for(root_name).each do |subspec|
                add_vertex.call(
                  @activated.vertex_named("#{root_name}/#{subspec}"),
                  used_by_non_library_targets_only,
                )
              end
            end

            vertex.outgoing_edges.each do |edge|
              next unless edge_is_valid_for_target_platform?(edge, target.platform)
              add_vertex.call(edge.destination, used_by_non_library_targets_only)
            end
          end

          specs_by_target[target] = selected.values.sort_by(&:name)
        end
        specs_by_target
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
