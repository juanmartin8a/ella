# Pika Kotlin 2.3.21 compiler artifact

This repository contains `io.github.lukmccall.pika:pika-compiler:0.3.2-2.3.21`.
It was built from the unmodified Pika `v0.3.2` tag because that exact Kotlin
compiler variant has not been published to Maven Central.

Build and verification:

```sh
./gradlew :pika-compiler:test -PkotlinVersion=2.3.21 --no-configuration-cache
./gradlew :pika-compiler:publishToMavenLocal \
  -PkotlinVersion=2.3.21 \
  -Dmaven.repo.local=/path/to/output \
  --no-configuration-cache
```

Upstream: https://github.com/lukmccall/pika/tree/v0.3.2
License: MIT
