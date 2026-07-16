Pod::Spec.new do |s|
  s.name         = "SwiftTerm"
  s.version      = "1.14.0"
  s.summary      = "Swift VT100/Xterm terminal emulator"
  s.homepage     = "https://github.com/migueldeicaza/SwiftTerm"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.authors      = { "Miguel de Icaza" => "miguel@tirania.org" }
  s.source       = { :git => "https://github.com/migueldeicaza/SwiftTerm.git", :tag => "v1.14.0" }

  s.ios.deployment_target = "14.0"
  s.swift_version = "5.9"
  s.source_files = [
    "Sources/SwiftTerm/*.swift",
    "Sources/SwiftTerm/Apple/**/*.swift",
    "Sources/SwiftTerm/iOS/**/*.swift",
    "Sources/SwiftTerm/Mac/MacAccessibilityService.swift"
  ]
  s.resources = "Sources/SwiftTerm/Apple/Metal/Shaders.metal"
  s.exclude_files = [
    "Sources/SwiftTerm/LocalProcess.swift",
    "Sources/SwiftTerm/Pty.swift"
  ]
  s.frameworks = ["CoreText", "Foundation", "UIKit", "QuartzCore", "Metal", "MetalKit"]
end
