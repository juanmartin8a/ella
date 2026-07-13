const {
  createRunOncePlugin,
  withPodfile,
  withProjectBuildGradle,
} = require('expo/config-plugins')

const pkg = require('./package.json')

function addJitPack(contents) {
  if (/https:\/\/(www\.)?jitpack\.io/.test(contents)) return contents

  const repositoriesBlock = /allprojects\s*\{[\s\S]*?repositories\s*\{/m
  if (repositoriesBlock.test(contents)) {
    return contents.replace(
      repositoriesBlock,
      (match) => `${match}\n        maven { url "https://jitpack.io" }`
    )
  }

  return `${contents}\n\nallprojects {\n    repositories {\n        maven { url "https://jitpack.io" }\n    }\n}\n`
}

function addSwiftTermPod(contents) {
  if (contents.includes("pod 'SwiftTerm'")) return contents

  const pod =
    "  pod 'SwiftTerm', :podspec => File.join(__dir__, '../modules/ella-terminal/SwiftTerm.podspec')"
  return contents.replace(/(^\s*use_expo_modules!.*$)/m, (line) => `${line}\n${pod}`)
}

const withEllaTerminal = (config) => {
  config = withProjectBuildGradle(config, (result) => {
    result.modResults.contents = addJitPack(result.modResults.contents)
    return result
  })

  config = withPodfile(config, (result) => {
    result.modResults.contents = addSwiftTermPod(result.modResults.contents)
    return result
  })

  return config
}

module.exports = createRunOncePlugin(withEllaTerminal, pkg.name, pkg.version)
