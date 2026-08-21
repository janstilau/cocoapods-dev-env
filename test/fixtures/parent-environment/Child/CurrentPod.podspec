Pod::Spec.new do |spec|
  spec.name = 'CurrentPod'
  spec.version = '1.0.0'
  spec.summary = 'Current child Pod fixture.'
  spec.homepage = 'https://example.invalid/CurrentPod'
  spec.license = { :type => 'MIT' }
  spec.author = { 'Tests' => 'tests@example.invalid' }
  spec.source = { :path => '.' }
  spec.ios.deployment_target = '13.0'
  spec.source_files = 'Sources/**/*.{h,m}'
  spec.dependency 'Transitive'
end
