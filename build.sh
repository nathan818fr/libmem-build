#!/usr/bin/env bash
#
# Source: https://github.com/nathan818fr/libmem-build
# Author: Nathan Poirier <nathan@poirier.io>
#
set -Eeuo pipefail
shopt -s inherit_errexit

declare -gr PLATFORMS=(
  # Linux (glibc)
  linux-gnu-x86_64
  linux-gnu-aarch64 # Note: This is not supported by libmem currently, see the warn below.
  # Linux (musl)
  linux-musl-x86_64
  linux-musl-aarch64 # Note: This is not supported by libmem currently, see the warn below.
  # Windows (MSVC)
  windows-msvc-i686
  windows-msvc-x86_64
  windows-msvc-aarch64
)

REPO_DIR=$(dirname "$(realpath -m -- "$0")")
declare -gr REPO_DIR

function print_usage() {
  cat <<EOF
Usage: $(basename -- "$0") <platform> <source>

Environment variables:
  LIBMEM_BUILD_OUT_DIR: The output directory (default: "out/libmem-\${version}-\${platform}").
  LIBMEM_BUILD_CACHE_DIR: The cache directory (default: "cache").
  LIBMEM_BUILD_SKIP_ARCHIVE: Skip the final archive creation (default: false).

Supported platforms:
$(printf '  - %s\n' "${PLATFORMS[@]}")

Source formats:
  path: A local path to a source directory (e.g. "./libmem").
  version: A version number (e.g. "4.2.1").
EOF
}

function main() {
  if [[ $# -ne 2 ]]; then
    print_usage >&2
    return 1
  fi

  local platform=$1
  if ! array_contains "$platform" "${PLATFORMS[@]}"; then
    printf 'error: Unknown platform: %s\n' "$platform" >&2
    return 1
  fi
  if [[ "$platform" == linux-*-aarch64 ]]; then
    printf 'warn: Building for aarch64 is not supported by libmem currently, the build will fail.\n' >&2
    read -r -n1 -p 'Continue anyway? [y/N] ' >/dev/tty
    echo >/dev/tty
    if [[ ! "$REPLY" =~ ^[yY] ]]; then return 1; fi
  fi

  local source=$2 source_dir source_version
  case "$source" in
  /* | ./* | ../*)
    source_dir=$(realpath -m -- "$source")
    source_version=local
    ;;
  [0-9]*)
    source_dir=$(clone_source "https://github.com/rdbo/libmem.git" "$source" "libmem-${source}")
    source_version=${source//[\/\\]/--} # replace slashes/backslashes with dashes to avoid path traversal
    ;;
  *)
    printf 'error: Unknown source format: %s\n' "$source" >&2
    return 1
    ;;
  esac

  local out_dir
  if [[ -n "${LIBMEM_BUILD_OUT_DIR:-}" ]]; then
    out_dir=$(realpath -m -- "$LIBMEM_BUILD_OUT_DIR")
    if [[ -d "$out_dir" ]]; then
      printf 'error: Output directory already exists: %s\n' "$out_dir" >&2
      return 1
    fi
  else
    out_dir=$(realpath -m -- "out/libmem-${source_version}-${platform}")
    rm -rf -- "$out_dir"
  fi
  mkdir -p -- "$out_dir"

  printf 'Platform: %s\n' "$platform"
  printf 'Source directory: %s\n' "$source_dir"
  printf 'Output directory: %s\n' "$out_dir"
  printf '\n'

  case "$platform" in
  linux-*) _build_in_docker "$platform" "$source_dir" "$out_dir" ;;
  *) _build_locally "$platform" "$source_dir" "$out_dir" ;;
  esac

  if [[ "${LIBMEM_BUILD_SKIP_ARCHIVE:-}" != true ]]; then
    printf '[+] Create archive\n'
    tar -czf "${out_dir}.tar.gz" --owner=0 --group=0 --numeric-owner -C "$(dirname -- "$out_dir")" "$(basename -- "$out_dir")"
  fi

  printf '[+] Done\n'
}

function _build_in_docker() {
  local platform=$1 source_dir=$2 out_dir=$3

  local docker_os=unknown docker_platform=unknown
  case "$platform" in
  linux-gnu-*) docker_os=linux-gnu ;;
  linux-musl-*) docker_os=linux-musl ;;
  esac
  case "$platform" in
  *-x86_64) docker_platform=linux/amd64 ;;
  *-aarch64) docker_platform=linux/arm64 ;;
  esac

  local docker_image="libmem-build-${docker_os}-${docker_platform##*/}"
  docker build --platform "$docker_platform" -t "$docker_image" -f "${REPO_DIR}/docker-env/${docker_os}.Dockerfile" "${REPO_DIR}/docker-env"
  docker run --platform "$docker_platform" --rm \
    -e "PUID=$(id -u)" \
    -e "PGID=$(id -g)" \
    -e "_PLATFORM=${platform}" \
    -e "_SOURCE_DIR=/source" \
    -e "_BUILD_DIR=/build" \
    -e "_OUT_DIR=/out" \
    -v "${source_dir}:/source:ro" \
    -v "${out_dir}:/out:rw" \
    -i "$docker_image" \
    bash <<<"set -Eeuo pipefail; shopt -s inherit_errexit; $(declare -f do_build); do_build; exit 0"
}

function _build_locally() {
  local platform=$1 source_dir=$2 out_dir=$3

  local local_env="${platform%-*}"
  local local_env_arch="${platform##*-}"

  init_temp_dir
  _=_ \
    _PLATFORM="$platform" \
    _SOURCE_DIR="$source_dir" \
    _BUILD_DIR="${g_temp_dir}/build" \
    _OUT_DIR="$out_dir" \
    "${REPO_DIR}/local-env/${local_env}.sh" "$local_env_arch" \
    bash <<<"set -Eeuo pipefail; shopt -s inherit_errexit; $(declare -f do_build); do_build; exit 0"
}

# Perform the build and copy the results to the output directory.
# This function must self-contained and exportable.
# Inputs:
#   _PLATFORM: The target platform.
#   _SOURCE_DIR: The absolute path to the source directory.
#   _BUILD_DIR: The absolute path to the build directory.
#   _OUT_DIR: The absolute path to the output directory.
function do_build() {
  true "${_PLATFORM?required}" "${_SOURCE_DIR?required}" "${_BUILD_DIR?required}" "${_OUT_DIR?required}"

  # Prepare build configuration
  local cmake_conf_base=()
  case "$_PLATFORM" in
  windows-msvc-*)
    cmake_conf_base+=(-G 'NMake Makefiles')
    ;;
  *)
    local flags
    case "$_PLATFORM" in
    *-x86_64) flags='-march=westmere' ;;
    *-aarch64) flags='-march=armv8-a' ;;
    esac
    cmake_conf_base+=(-G 'Unix Makefiles' -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags")
    ;;
  esac
  cmake_conf_base+=(-DCMAKE_BUILD_TYPE=Release)
  cmake_conf_base+=(-DLIBMEM_BUILD_TESTS=OFF)

  # Build variants
  local variant
  for variant in shared static; do
    local variant_build_dir="${_BUILD_DIR}/${variant}"
    printf '[+] Build %s\n' "$variant"

    local cmake_conf_variant=("${cmake_conf_base[@]}")
    cmake_conf_variant+=(-DLIBMEM_BUILD_STATIC="$([[ "$variant" == static ]] && echo ON || echo OFF)")

    set -x
    cmake -S "$_SOURCE_DIR" -B "$variant_build_dir" "${cmake_conf_variant[@]}"
    cmake --build "$variant_build_dir" --config Release --parallel "$(nproc)"
    { set +x; } 2>/dev/null
  done

  # Copy libraries
  printf '[+] Copy libraries\n'
  mkdir -p -- "${_OUT_DIR}/lib"
  function copy_lib() {
    install -vD -m644 -- "${_BUILD_DIR}/${1}" "${_OUT_DIR}/lib/${2:-$(basename -- "$1")}"
  }
  case "$_PLATFORM" in
  windows-*)
    copy_lib 'shared/libmem.dll'
    copy_lib 'static/libmem.lib'
    copy_lib 'static/capstone-engine-prefix/src/capstone-engine-build/capstone.lib'
    copy_lib 'static/keystone-engine-prefix/src/keystone-engine-build/llvm/lib/keystone.lib'
    copy_lib 'static/lief-project-prefix/src/lief-project-build/LIEF.lib'
    copy_lib 'static/llvm.lib'
    ;;
  *)
    copy_lib 'shared/liblibmem.so'
    copy_lib 'static/liblibmem_partial.a' 'liblibmem.a'
    copy_lib 'static/capstone-engine-prefix/src/capstone-engine-build/libcapstone.a'
    copy_lib 'static/keystone-engine-prefix/src/keystone-engine-build/llvm/lib/libkeystone.a'
    copy_lib 'static/lief-project-prefix/src/lief-project-build/libLIEF.a'
    copy_lib 'static/libllvm.a'
    ;;
  esac

  # Copy headers
  printf '[+] Copy headers\n'
  mkdir -p -- "${_OUT_DIR}/include"
  cp -rT -- "${_SOURCE_DIR}/libmem/include" "${_OUT_DIR}/include"

  # Copy licenses
  printf '[+] Copy licenses\n'
  mkdir -p -- "${_OUT_DIR}/licenses"
  function copy_licenses() {
    local name=$1
    local dir="${_SOURCE_DIR}/${2:-$name}"
    find "$dir" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'exception*' \) | while read -r file; do
      local file_name
      file_name=$(basename -- "$file")
      file_name=${file_name%.*} # remove extension
      file_name=${file_name,,}  # lowercase
      install -vD -m644 -- "$file" "${_OUT_DIR}/licenses/${name}-${file_name}.txt"
    done
  }
  copy_licenses 'libmem' './'
  copy_licenses 'capstone'
  copy_licenses 'keystone'
  copy_licenses 'LIEF'
  copy_licenses 'llvm'

  # Add stdlib information (glibc version, musl version)
  printf '[+] Add stdlib information\n'
  case "$_PLATFORM" in
  linux-gnu-*)
    ldd --version | head -n1 | awk '{print $NF}' | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/GLIBC_VERSION.txt"
    ;;
  linux-musl-*)
    apk info musl 2>/dev/null | head -n1 | awk '{print $1}' | sed 's/^musl-//' | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/MUSL_VERSION.txt"
    ;;
  windows-*)
    printf '%s\n' "${VCTOOLSVERSION:-${VSCMD_ARG_VCVARS_VER:-}}" | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/MSVC_VERSION.txt"
    printf '%s\n' "${WINDOWSSDKVERSION:-}" | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/WINSDK_VERSION.txt"
    ;;
  esac
}

# Clone source repository, using a cached copy if available.
# Inputs:
#   $1: The git repository URL.
#   $2: The tag or commit to checkout.
#   $3: The name of the source directory (used as cache key).
# Outputs:
#   stdout: The absolute path to the source directory.
function clone_source() {
  local url=$1
  local tag=$2
  local name=${3//[\/\\]/--} # replace slashes/backslashes with dashes to avoid path traversal

  init_cache_dir
  local dst="${g_cache_dir}/${name}"
  if [[ -d "$dst" ]]; then
    printf 'Using cached source: %s (from %s:%s)\n' "$name" "$url" "$tag" >&2
  else
    printf 'Downloading source: %s (from %s:%s)\n' "$name" "$url" "$tag" >&2
    init_temp_dir
    local temp_dst="${g_temp_dir}/${name}.git"
    git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules -- "$url" "$temp_dst" >&2
    mv -- "$temp_dst" "$dst"
  fi
  printf '%s' "$dst"
}

# Ensure that the cache directory exists and is set to an absolute path.
# The default path is "cache" in the current directory, this can be overridden by the LIBMEM_BUILD_CACHE_DIR environment variable.
# This function is idempotent.
# Outputs:
#   g_cache_dir: The absolute path to the cache directory.
function init_cache_dir() {
  if [[ -v g_cache_dir ]]; then
    return
  fi

  g_cache_dir=$(realpath -m -- "${LIBMEM_BUILD_CACHE_DIR:-cache}")
  declare -gr g_cache_dir

  mkdir -p -- "$g_cache_dir"
}

# Ensure that the temporary directory exists and is set to an absolute path.
# This directory will be automatically deleted when the script exits.
# This function is idempotent.
# Outputs:
#   g_temp_dir: The absolute path to the temporary directory.
function init_temp_dir() {
  if [[ -v g_temp_dir ]]; then
    return
  fi

  g_temp_dir=$(mktemp -d)
  declare -gr g_temp_dir

  # shellcheck disable=SC2317
  function __temp_dir_cleanup() { rm -rf -- "$g_temp_dir"; }
  trap __temp_dir_cleanup INT TERM EXIT
}

# Hash a string using SHA-1.
# Inputs:
#   $1: The string to hash.
# Outputs:
#   stdout: The hex-encoded hash.
function sha1() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a1 <<<"$1" | awk '{print $1}'
  else
    sha1sum <<<"$1" | awk '{print $1}'
  fi
}

# Check if an array contains a value.
# Inputs:
#   $1: The value to check for.
#   $2+: The array to check.
# Returns:
#   0 if the array contains the value,
#   1 otherwise.
function array_contains() {
  local value=$1
  local element
  for element in "${@:2}"; do
    if [[ "$element" == "$value" ]]; then
      return 0
    fi
  done
  return 1
}

eval 'main "$@";exit "$?"'
