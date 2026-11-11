#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then
    echo 'The background runtime requires macOS 14 or later.' >&2
    exit 1
fi
swift build --package-path "$repo_dir/background" -c release --product ApplicationUseBackground
binary_dir=$(swift build --package-path "$repo_dir/background" -c release --show-bin-path)
output_dir=$repo_dir/build/background
mkdir -p "$output_dir/runtime" "$output_dir/scripts" "$output_dir/licenses"
cp "$binary_dir/ApplicationUseBackground" "$output_dir/runtime/ApplicationUseBackground"
cp "$repo_dir/scripts/application-use/application_use.py" "$output_dir/scripts/application_use.py"
cp "$repo_dir/scripts/application-use/application-use" "$output_dir/scripts/application-use"
cp "$repo_dir/background/LICENSE" "$repo_dir/background/THIRD_PARTY_NOTICES.md" "$output_dir/licenses/"
chmod 755 "$output_dir/scripts/application-use" "$output_dir/runtime/ApplicationUseBackground"
echo "Built background CLI: $output_dir/scripts/application-use"
