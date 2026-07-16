const {
  createRunOncePlugin,
  withAppBuildGradle,
  withGradleProperties,
  withPodfile,
  withProjectBuildGradle,
  withDangerousMod,
} = require('expo/config-plugins')
const fs = require('node:fs/promises')
const path = require('node:path')

const pkg = require('./package.json')

const PODFILE_PLUGIN = "plugin 'cocoapods-spm'"
const PODFILE_FILEUTILS = "require 'fileutils'"
const SWIFT_TERM_POD =
  "  pod 'SwiftTerm', :podspec => File.join(__dir__, '../modules/ella-terminal/SwiftTerm.podspec')"
const SPM_PACKAGES = [
  "  spm_pkg 'swift-nio-ssh', :url => 'https://github.com/apple/swift-nio-ssh.git', :version => '0.14.1', :products => ['NIOSSH']",
  "  spm_pkg 'swift-nio', :url => 'https://github.com/apple/swift-nio.git', :version => '2.101.3', :products => ['NIOCore', 'NIOPosix']",
]
const SPM_FILE_LISTS_MARKER = '# cocoapods-spm file-list compatibility'
const APP_DESUGARING = `
android {
    compileOptions {
        coreLibraryDesugaringEnabled true
    }
}
`
const PIKA_MAVEN_REPOSITORY =
  '    maven { url uri("$rootDir/../modules/ella-terminal/android/maven") }'

function addSpmDependencies(contents) {
  let result = contents

  if (!result.includes(PODFILE_PLUGIN)) {
    result = `${PODFILE_PLUGIN}\n${result}`
  }
  if (!result.includes(PODFILE_FILEUTILS)) {
    result = `${PODFILE_PLUGIN}\n${PODFILE_FILEUTILS}\n${result.replace(`${PODFILE_PLUGIN}\n`, '')}`
  }

  const declarations = [SWIFT_TERM_POD, ...SPM_PACKAGES].filter(
    (declaration) => !result.includes(declaration.trim()),
  )
  if (declarations.length > 0) {
    result = result.replace(
      /(^\s*use_expo_modules!.*$)/m,
      (line) => `${line}\n${declarations.join('\n')}`,
    )
  }

  if (!result.includes(SPM_FILE_LISTS_MARKER)) {
    result = result.replace(
      /^\s*react_native_post_install\(/m,
      `    ${SPM_FILE_LISTS_MARKER}
    support_dir = File.join(installer.sandbox.root, 'Target Support Files', 'Pods-ella')
    FileUtils.mkdir_p(support_dir)
    ['Debug', 'Release'].product(['input', 'output']).each do |config, kind|
      FileUtils.touch(File.join(support_dir, "Pods-ella-resources-#{config}-#{kind}-files.xcfilelist"))
    end

    react_native_post_install(`,
    )
  }

  return result
}

const withEllaTerminal = (config) => {
  config = withDangerousMod(config, [
    'android',
    async (result) => {
      const wrapperPath = path.join(
        result.modRequest.platformProjectRoot,
        'gradle/wrapper/gradle-wrapper.properties',
      )
      const contents = await fs.readFile(wrapperPath, 'utf8')
      await fs.writeFile(
        wrapperPath,
        contents.replace(/gradle-[\d.]+-bin\.zip/, 'gradle-9.3.1-bin.zip'),
      )
      return result
    },
  ])

  config = withGradleProperties(config, (result) => {
    const properties = {
      'org.gradle.jvmargs': '-Xmx4096m -XX:MaxMetaspaceSize=1024m',
    }
    for (const [key, value] of Object.entries(properties)) {
      const existing = result.modResults.find((item) => item.key === key)
      if (existing) {
        existing.value = value
      } else {
        result.modResults.push({ type: 'property', key, value })
      }
    }
    return result
  })

  config = withProjectBuildGradle(config, (result) => {
    let contents = result.modResults.contents
      .replace(
        "classpath('com.android.tools.build:gradle')",
        "classpath('com.android.tools.build:gradle:8.13.2')",
      )
      .replace(
        "classpath('org.jetbrains.kotlin:kotlin-gradle-plugin')",
        "classpath('org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.21')",
      )
      .replace(
      /^\s*maven \{ url ['"]https:\/\/(www\.)?jitpack\.io['"] \}\s*$/gm,
      '',
    )
    if (!contents.includes(PIKA_MAVEN_REPOSITORY.trim())) {
      contents = contents.replace(
        /(allprojects\s*\{\s*repositories\s*\{)/,
        `$1\n${PIKA_MAVEN_REPOSITORY}`,
      )
    }
    result.modResults.contents = contents
    return result
  })

  config = withAppBuildGradle(config, (result) => {
    let contents = result.modResults.contents
    if (!contents.includes('coreLibraryDesugaringEnabled true')) {
      contents = contents.replace(
        '// Apply static values from `gradle.properties`',
        `${APP_DESUGARING}\n// Apply static values from \`gradle.properties\``,
      )
    }
    if (!contents.includes('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")')) {
      contents = contents.replace(
        /dependencies\s*\{/,
        'dependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")',
      )
    }
    result.modResults.contents = contents
    return result
  })

  return withPodfile(config, (result) => {
    result.modResults.contents = addSpmDependencies(result.modResults.contents)
    return result
  })
}

module.exports = createRunOncePlugin(withEllaTerminal, pkg.name, pkg.version)
