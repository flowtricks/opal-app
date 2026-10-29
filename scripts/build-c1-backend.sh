#!/bin/bash
# Build only. This script never opens a camera or activates a system extension.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_COMMIT=e0f6b52d048ef7ceac2ecd44deb2e161dbb97699
SDK="$ROOT/vendor/depthai-core"
PREFIX="$ROOT/vendor/depthai-install"
if [ ! -x "$ROOT/.build-tools/bin/cmake" ]; then
  python3 -m venv "$ROOT/.build-tools"
  "$ROOT/.build-tools/bin/python" -m pip install 'cmake==3.31.10' 'ninja==1.13.0'
fi
export PATH="$ROOT/.build-tools/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
# Keep Hunter's dependency cache inside this project.
export HUNTER_ROOT="$ROOT/.build-tools/hunter"
if [ ! -d "$SDK/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --branch v2.30.0 --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/luxonis/depthai-core.git "$SDK"
fi
test "$(git -C "$SDK" rev-parse HEAD)" = "$SDK_COMMIT" || {
  echo 'DepthAI revision mismatch; expected pinned v2.30.0 commit.' >&2; exit 1;
}
python3 "$ROOT/scripts/prepare-c1-sdk.py" "$SDK"
cmake -S "$SDK" -B "$ROOT/build/depthai" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=ON -DDEPTHAI_BUILD_EXAMPLES=OFF -DDEPTHAI_BUILD_TESTS=OFF \
  -DDEPTHAI_BUILD_DOCS=OFF -DDEPTHAI_OPENCV_SUPPORT=OFF \
  -DDEPTHAI_ENABLE_CURL=OFF -DDEPTHAI_ENABLE_BACKWARD=OFF
cmake --build "$ROOT/build/depthai" --parallel 6
cmake --install "$ROOT/build/depthai"
XLINK_PATH=$(sed -n 's/^XLink_DIR:PATH=//p' "$ROOT/build/depthai/CMakeCache.txt")
USB_LIB="${XLINK_PATH%/lib/cmake/XLink}/lib/libusb-1.0.dylib"
test -f "$USB_LIB" || { echo "Missing built libusb at $USB_LIB" >&2; exit 1; }
cp "$USB_LIB" "$PREFIX/lib/libusb-1.0.dylib"
cmake -S "$ROOT/Sources/C1Bridge" -B "$ROOT/build/c1" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build/c1" --parallel 6
ctest --test-dir "$ROOT/build/c1" --output-on-failure
cp "$PREFIX/lib/libdepthai-core.dylib" "$ROOT/build/c1/"
cp "$PREFIX/lib/libusb-1.0.dylib" "$ROOT/build/c1/"
mkdir -p "$ROOT/build/c1/licenses"
cp "$SDK/LICENSE" "$ROOT/build/c1/licenses/DepthAI-LICENSE.txt"
cp -R "$PREFIX/lib/cmake/depthai/dependencies/licenses/." "$ROOT/build/c1/licenses/"
if [ -f "$PREFIX/lib/cmake/depthai/dependencies/include/spdlog/fmt/bundled/LICENSE.rst" ]; then
  cp "$PREFIX/lib/cmake/depthai/dependencies/include/spdlog/fmt/bundled/LICENSE.rst" "$ROOT/build/c1/licenses/fmt-LICENSE.rst"
fi
git -C "$SDK" submodule status --recursive > "$ROOT/build/c1/dependency-commits.txt"
printf '%s\n' "$SDK_COMMIT" > "$ROOT/build/c1/depthai-commit.txt"
echo "Built $ROOT/build/c1/libC1Bridge.dylib (no hardware accessed)."
