#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-menu-refresh.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

swiftc \
  -swift-version 6 \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -module-name ClaudeSwitcherCore \
  -emit-module-path "$build_dir/ClaudeSwitcherCore.swiftmodule" \
  "$repo_dir"/Sources/ClaudeSwitcherCore/*.swift \
  -o "$build_dir/libClaudeSwitcherCore.dylib"

ui_sources=(
  "$repo_dir/Sources/ClaudeSwitcher/UsageBarView.swift"
  "$repo_dir/Sources/ClaudeSwitcher/MenuBuilder.swift"
)
if [[ -f "$repo_dir/Sources/ClaudeSwitcher/MenuDetailView.swift" ]]; then
  ui_sources+=("$repo_dir/Sources/ClaudeSwitcher/MenuDetailView.swift")
fi

swiftc \
  -swift-version 6 \
  -parse-as-library \
  -I "$build_dir" \
  -L "$build_dir" \
  -lClaudeSwitcherCore \
  -Xlinker -rpath \
  -Xlinker "$build_dir" \
  "${ui_sources[@]}" \
  "$repo_dir/Tests/MenuRefresh/main.swift" \
  -o "$build_dir/menu-refresh"

"$build_dir/menu-refresh"
