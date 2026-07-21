require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "EllaTerminal"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/mrousavy/nitro"
  s.license      = package["license"]
  s.authors      = "Ella"

  s.platforms    = { :ios => "17.0" }
  s.source       = { :path => "." }
  s.source_files = [
    "ios/**/*.{swift}",
    "ios/**/*.{m,mm}",
    "cpp/**/*.{hpp,cpp}"
  ]

  load "nitrogen/generated/ios/EllaTerminal+autolinking.rb"
  add_nitrogen_files(s)

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  s.dependency "SwiftTerm"
  s.spm_dependency "swift-nio-ssh/NIOSSH"
  s.spm_dependency "swift-nio/NIOCore"
  s.spm_dependency "swift-nio/NIOPosix"
  install_modules_dependencies(s)
end
