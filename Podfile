platform :ios, '16.0'

target 'VlcCustomIOS' do
  use_frameworks!
  pod 'MobileVLCKit'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      # Pods are built with the same "no local signing" settings as the app so an unsigned archive can succeed in CI.
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
    end
  end
end
