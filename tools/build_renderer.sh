#!/bin/zsh
# Builds the renderer library (libspirula_render.dylib) that Vintage Click
# draws with: Spirula Studio (GPL-3.0) at the upstream commit in
# renderer/UPSTREAM_BASE.txt, plus renderer/spirula-vintage-click.patch (the
# C interface, thin-lens defocus, Metal frame sharing).
#
#   tools/build_renderer.sh [where]     # default: ../spirula next to this repo
#
# Then: SPIRULA_BUILD=<where>/build ./build.sh
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$here/../spirula}"
if [[ ! -d "$dest/.git" ]]; then
    git clone https://github.com/harry7557558/spirula-studio "$dest"
fi
cd "$dest"
git checkout -q "$(cat "$here/renderer/UPSTREAM_BASE.txt")"
git apply --check "$here/renderer/spirula-vintage-click.patch" 2>/dev/null \
    && git apply "$here/renderer/spirula-vintage-click.patch" \
    || echo "patch already applied (or the checkout has other changes)"
# The Command Line Tools' libc++ headers, not a stray copy elsewhere.
export CXXFLAGS="-nostdinc++ -isystem $(xcrun --show-sdk-path)/usr/include/c++/v1"
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSS_BACKEND=vulkan -DSS_ENABLE_PATENTED=ON
SS_SKIP_COMMENT_CHECK=1 cmake --build build --target spirula_render
echo "Built $dest/build/libspirula_render.dylib"
