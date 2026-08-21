# frozen_string_literal: true

require 'cocoapods'
require 'pathname'
require 'set'

module Pod
  class DevEnv
    ParentDependencyOverride = Struct.new(
      :requirements,
      :podspec_repo,
      :external_source,
      :full,
      keyword_init: true,
    ) do
      def explicit?
        full || !requirements.empty? || !podspec_repo.nil? || !external_source.empty?
      end
    end

    class << self
      attr_accessor :parent_project_environment

      def reset_parent_dependency_overrides!
        @parent_dependency_overrides = {}
        @direct_parent_environment_roots = {}
        @parent_root_expansion_stack = []
      end

      def parent_dependency_override(root_name)
        (@parent_dependency_overrides || {})[root_name]
      end

      def register_parent_dependency_override(root_name, requirements:, podspec_repo:, external_source:, full:)
        @parent_dependency_overrides ||= {}
        current = @parent_dependency_overrides[root_name]
        merged_requirements = Array(current&.requirements) + Array(requirements)
        merged_external_source = (current&.external_source || {}).merge(external_source || {})
        @parent_dependency_overrides[root_name] = ParentDependencyOverride.new(
          requirements: merged_requirements.uniq,
          podspec_repo: podspec_repo || current&.podspec_repo,
          external_source: merged_external_source,
          full: full || current&.full || false,
        )
      end

      def register_direct_parent_environment_root(root_name)
        @direct_parent_environment_roots ||= {}
        @direct_parent_environment_roots[root_name] = true
      end

      def direct_parent_environment_root?(root_name)
        (@direct_parent_environment_roots || {}).key?(root_name)
      end

      def expanding_parent_root?(root_name)
        Array(@parent_root_expansion_stack).include?(root_name)
      end

      def with_parent_root_expansion(root_name)
        @parent_root_expansion_stack ||= []
        @parent_root_expansion_stack << root_name
        yield
      ensure
        @parent_root_expansion_stack.pop
      end
    end

    # A read-only projection of the parent Podfile.lock used while resolving a
    # child Example. It indexes every root in PODS, not only direct Podfile
    # dependencies, so transitive dependencies keep the parent's version and
    # source as well.
    class ParentProjectEnvironment
      attr_reader :consumer_directory, :dependencies, :lockfile, :lockfile_path

      def self.load(path, consumer_directory:)
        consumer_directory = Pathname.new(consumer_directory).expand_path.cleanpath
        candidate = Pathname.new(path.to_s).expand_path(consumer_directory).cleanpath
        candidate = candidate.join('Podfile.lock') if candidate.directory?
        unless candidate.file?
          raise Informative, "Parent Podfile.lock does not exist: #{candidate}"
        end

        lockfile = Lockfile.from_file(candidate)
        new(lockfile, candidate, consumer_directory)
      end

      def initialize(lockfile, lockfile_path, consumer_directory)
        @lockfile = lockfile
        @lockfile_path = Pathname.new(lockfile_path).expand_path.cleanpath
        @consumer_directory = Pathname.new(consumer_directory).expand_path.cleanpath
        @external_sources = normalized_hash(lockfile.internal_data['EXTERNAL SOURCES'])
        @checkout_options = normalized_hash(lockfile.internal_data['CHECKOUT OPTIONS'])
        @subspecs_by_root = build_subspecs_by_root
        @pod_dependencies_by_name = build_pod_dependencies_by_name
        @dependencies = build_dependencies.freeze
      end

      def dependency_for(name)
        dependencies[Specification.root_name(name)]
      end

      def subspecs_for(name)
        @subspecs_by_root.fetch(Specification.root_name(name), []).dup
      end

      def checkout_options_for(name)
        @checkout_options.fetch(Specification.root_name(name), {}).dup
      end

      def external_source_for(name)
        dependency = dependency_for(name)
        dependency&.external_source&.dup
      end

      # Starting from the child's textual target dependencies, walk the parent
      # lock graph and add only sibling subspecs that are selected in the
      # parent but would otherwise be absent. Normal transitive dependencies
      # remain transitive, and any root directly scoped by the child Podfile is
      # left untouched.
      def dependencies_with_parent_subspec_closure(child_dependencies)
        scheduled = child_dependencies.map(&:name).to_set
        queue = scheduled.to_a
        additions = Set.new
        expanded_roots = Set.new

        until queue.empty?
          name = queue.shift
          root_name = Specification.root_name(name)
          next unless dependencies.key?(root_name)

          unless expanded_roots.include?(root_name) || DevEnv.direct_parent_environment_root?(root_name)
            expanded_roots << root_name
            subspecs_for(root_name).each do |subspec|
              sibling_name = "#{root_name}/#{subspec}"
              next if scheduled.include?(sibling_name)

              scheduled << sibling_name
              additions << sibling_name
              queue << sibling_name
            end
          end

          @pod_dependencies_by_name.fetch(name, []).each do |dependency_name|
            next if scheduled.include?(dependency_name)

            scheduled << dependency_name
            queue << dependency_name
          end
        end

        child_dependencies + additions.sort.map { |name| Dependency.new(name) }
      end

      def relative_parent_directory
        relative_path(lockfile_path.dirname, consumer_directory).to_s
      end

      def constrain(dependency, override: nil)
        root_name = dependency.root_name
        override ||= DevEnv.parent_dependency_override(root_name)

        return dependency if override&.full

        parent_dependency = dependency_for(root_name)
        unless parent_dependency
          return dependency if override&.explicit? || dependency.external_source
          raise Informative, "Parent Podfile.lock does not contain #{root_name}"
        end

        return dependency if dependency.external_source && !override&.external_source&.any?

        constraint = constraint_for(dependency, parent_dependency, override)
        dependency.merge(constraint)
      rescue ArgumentError, Informative => error
        raise Informative, "Cannot inherit #{root_name} from parent Podfile.lock: #{error.message}"
      end

      private

      def build_dependencies
        roots.each_with_object({}) do |root_name, result|
          version = lockfile.version(root_name)
          unless version
            raise Informative, "Parent Podfile.lock has no version for #{root_name}"
          end

          external_source = @external_sources[root_name]
          if external_source
            result[root_name] = Dependency.new(root_name, normalize_external_source(external_source))
            next
          end

          spec_repo = lockfile.spec_repo(root_name)
          unless spec_repo
            raise Informative, "Parent Podfile.lock has no Specs source for #{root_name}"
          end
          result[root_name] = Dependency.new(root_name, version.to_s, :source => spec_repo)
        end
      end

      def build_subspecs_by_root
        result = Hash.new { |hash, key| hash[key] = [] }
        lockfile.pod_names.each do |name|
          root_name = Specification.root_name(name)
          next if name == root_name
          result[root_name] << name.delete_prefix("#{root_name}/")
        end
        result.transform_values { |values| values.uniq.sort.freeze }.freeze
      end

      def build_pod_dependencies_by_name
        Array(lockfile.internal_data['PODS']).each_with_object({}) do |entry, result|
          display_name, dependencies = if entry.is_a?(Hash)
                                         [entry.keys.first, entry.values.first]
                                       else
                                         [entry, []]
                                       end
          name = locked_spec_name(display_name)
          result[name] = Array(dependencies).map { |dependency| locked_spec_name(dependency) }.uniq.freeze
        end.freeze
      end

      def locked_spec_name(value)
        value.to_s.sub(/\s+\(.+\)\z/, '')
      end

      def roots
        lockfile.pod_names.map { |name| Specification.root_name(name) }.uniq.sort
      end

      def constraint_for(dependency, parent_dependency, override)
        explicit_external_source = override&.external_source || {}
        if explicit_external_source.any?
          return Dependency.new(dependency.name, explicit_external_source)
        end

        explicit_requirements = Array(override&.requirements)
        explicit_podspec_repo = override&.podspec_repo
        if explicit_requirements.any? || explicit_podspec_repo
          requirements = explicit_requirements
          requirements = [lockfile.version(dependency.root_name).to_s] if requirements.empty?
          podspec_repo = explicit_podspec_repo
          podspec_repo ||= parent_dependency.podspec_repo unless parent_dependency.external_source
          return Dependency.new(dependency.name, *requirements, :source => podspec_repo) if podspec_repo
          return Dependency.new(dependency.name, *requirements)
        end

        if parent_dependency.external_source
          return Dependency.new(dependency.name, parent_dependency.external_source.dup)
        end

        Dependency.new(
          dependency.name,
          parent_dependency.requirement,
          :source => parent_dependency.podspec_repo,
        )
      end

      def normalize_external_source(source)
        normalized = symbolize_keys(source)
        [:path, :podspec].each do |key|
          next unless normalized[key]
          next if key == :podspec && normalized[key].to_s.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          normalized[key] = normalize_parent_path(normalized[key])
        end
        normalized
      end

      def normalize_parent_path(value)
        path = Pathname.new(value.to_s)
        path = lockfile_path.dirname.join(path) unless path.absolute?
        path = path.cleanpath
        unless path.exist?
          raise Informative, "Parent external source path does not exist: #{path}"
        end
        relative_path(path, consumer_directory).to_s
      end

      def relative_path(path, base)
        path.relative_path_from(base)
      rescue ArgumentError
        path
      end

      def normalized_hash(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) do |(name, options), result|
          result[Specification.root_name(name.to_s)] = symbolize_keys(options || {})
        end
      end

      def symbolize_keys(value)
        value.each_with_object({}) do |(key, item), result|
          result[key.to_sym] = item
        end
      end
    end

    # Captures explicit child Podfile choices before cocoapods-dev-env mutates
    # the options. These choices form a deliberate overlay on the parent
    # environment instead of disabling parent inheritance for the whole graph.
    module ParentEnvironmentTargetDefinition
      EXTERNAL_SOURCE_KEYS = [:git, :path, :podspec, :http, :tag, :branch, :commit].freeze

      def store_pod(name, *requirements)
        options = requirements.last.is_a?(Hash) ? requirements.last.dup : {}
        dev_env = options[:dev_env]
        root_name = Specification.root_name(name)
        environment = DevEnv.parent_project_environment

        if environment && !DevEnv.expanding_parent_root?(root_name)
          DevEnv.register_direct_parent_environment_root(root_name)
        end

        capture_parent_environment_override(root_name, requirements, options, dev_env)

        if environment && dev_env == 'parent' && name == root_name && !options.key?(:subspecs)
          subspecs = environment.subspecs_for(root_name)
          unless subspecs.empty?
            requirements = requirements.dup
            options[:subspecs] = subspecs
            if requirements.last.is_a?(Hash)
              requirements[-1] = options
            else
              requirements << options
            end
            return DevEnv.with_parent_root_expansion(root_name) do
              super(name, *requirements)
            end
          end
        end

        super(name, *requirements)
      end

      def dependencies
        child_dependencies = super
        environment = DevEnv.parent_project_environment
        return child_dependencies unless environment

        environment.dependencies_with_parent_subspec_closure(child_dependencies)
      end

      private

      def capture_parent_environment_override(root_name, requirements, options, dev_env)
        version_requirements = requirements.reject { |item| item.is_a?(Hash) }
        external_source = options.select { |key, _| EXTERNAL_SOURCE_KEYS.include?(key) }
        podspec_repo = options[:source]
        full_override = !dev_env.nil? && dev_env != 'parent'
        return if version_requirements.empty? && external_source.empty? && podspec_repo.nil? && !full_override

        DevEnv.register_parent_dependency_override(
          root_name,
          requirements: version_requirements,
          podspec_repo: podspec_repo,
          external_source: external_source,
          full: full_override,
        )
      end

    end

    # CocoaPods only serializes EXTERNAL SOURCES for dependencies written
    # directly in the Podfile. Complete parent inheritance also supports a
    # transitive dependency whose source is path/git, so persist those resolved
    # sources without promoting them to textual Podfile dependencies.
    module ParentEnvironmentLockfile
      def generate(podfile, specs, checkout_options, spec_repos = {})
        lockfile = super
        environment = DevEnv.parent_project_environment
        return lockfile unless environment

        used_roots = specs.map { |spec| Specification.root_name(spec.name) }.uniq
        external_sources = lockfile.internal_data['EXTERNAL SOURCES'] ||= {}
        generated_checkout_options = lockfile.internal_data['CHECKOUT OPTIONS'] ||= {}

        used_roots.each do |root_name|
          parent_source = environment.external_source_for(root_name)
          next unless parent_source

          override = DevEnv.parent_dependency_override(root_name)
          next if override&.explicit?

          external_sources[root_name] ||= parent_source
          parent_checkout = environment.checkout_options_for(root_name)
          generated_checkout_options[root_name] ||= parent_checkout unless parent_checkout.empty?
        end
        lockfile
      end
    end
  end

  Podfile::TargetDefinition.prepend(DevEnv::ParentEnvironmentTargetDefinition)
  class << Lockfile
    prepend DevEnv::ParentEnvironmentLockfile
  end
end
