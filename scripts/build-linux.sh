#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
TARGETS=("$@")

if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=("x86_64-linux-musl" "aarch64-linux-musl")
fi

cd "${ROOT_DIR}"
mkdir -p "${DIST_DIR}"

if command -v mise >/dev/null 2>&1; then
  ZIG=(mise exec -- zig)
else
  ZIG=(zig)
fi

"${ZIG[@]}" build test

for target in "${TARGETS[@]}"; do
  out_dir="${DIST_DIR}/${target}"
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"

  "${ZIG[@]}" build \
    -Dtarget="${target}" \
    -Doptimize="${OPTIMIZE}" \
    --prefix "${out_dir}"

  binary="${out_dir}/bin/hostlift"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${binary}" > "${binary}.sha256"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${binary}" > "${binary}.sha256"
  fi

  echo "built ${binary}"
done
