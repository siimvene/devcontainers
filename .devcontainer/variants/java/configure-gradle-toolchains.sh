#!/usr/bin/env bash
# Point Gradle's toolchain resolution at the JDKs the devcontainer feature
# already installed via SDKMAN (version + additionalVersions), so a project's
# JavaLanguageVersion.of(N) toolchain request is satisfied locally. Without
# this, Gradle's built-in auto-detection looks for SDKMAN candidates under
# $HOME/.sdkman — the devcontainers/features java feature installs to
# /usr/local/sdkman instead, so it's invisible by default and Gradle falls
# back to the foojay-resolver-convention plugin, which needs api.foojay.io
# (and wherever it redirects to fetch the actual JDK) allowlisted — one more
# moving part than just telling Gradle where to look.
set -euo pipefail

paths=""
for d in "${SDKMAN_DIR:-/usr/local/sdkman}"/candidates/java/*/; do
  base=$(basename "$d")
  [ "$base" = "current" ] && continue
  paths="${paths:+$paths,}${d%/}"
done

if [ -z "$paths" ]; then
  echo "gradle-toolchains: no SDKMAN java candidates found, skipping"
  exit 0
fi

mkdir -p "$HOME/.gradle"
touch "$HOME/.gradle/gradle.properties"
grep -v '^org\.gradle\.java\.installations\.paths=' "$HOME/.gradle/gradle.properties" > "$HOME/.gradle/gradle.properties.tmp" || true
mv "$HOME/.gradle/gradle.properties.tmp" "$HOME/.gradle/gradle.properties"
echo "org.gradle.java.installations.paths=$paths" >> "$HOME/.gradle/gradle.properties"
echo "gradle-toolchains: search paths set to $paths"
