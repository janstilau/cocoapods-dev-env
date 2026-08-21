Pod::Spec.new do |spec|
  spec.name = 'Transitive'
  spec.version = '1.0.0'
  spec.summary = 'Parent path transitive dependency fixture.'
  spec.homepage = 'https://example.invalid/Transitive'
  spec.license = { :type => 'MIT' }
  spec.author = { 'Tests' => 'tests@example.invalid' }
  spec.source = { :path => '.' }
  spec.ios.deployment_target = '13.0'
  spec.source_files = 'Sources/**/*.{h,m}'
end
