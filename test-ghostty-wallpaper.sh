#!/bin/bash

set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_PATH="${REPO_DIR}/ghostty-wallpaper.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${expected}" != "${actual}" ]]; then
    printf 'Assertion failed: %s\nexpected: %s\nactual: %s\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"

  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf 'Assertion failed: %s\nunexpected substring: %s\nactual: %s\n' "${message}" "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_ne() {
  local unexpected="$1"
  local actual="$2"
  local message="$3"

  if [[ "${unexpected}" == "${actual}" ]]; then
    printf 'Assertion failed: %s\nunexpected: %s\nactual: %s\n' "${message}" "${unexpected}" "${actual}" >&2
    exit 1
  fi
}

image_size() {
  local image_path="$1"

  sips -g pixelWidth -g pixelHeight "${image_path}" 2>/dev/null |
    awk -F': ' '
      /pixelWidth:/ { width = $2 }
      /pixelHeight:/ { height = $2 }
      END { printf "%sx%s", width, height }
    '
}

file_description() {
  local image_path="$1"

  file -b "${image_path}"
}

tmp_dir="$(mktemp -d -t ghostty-wallpaper-test)"
trap 'rm -rf "${tmp_dir}"' EXIT

wallpaper_dir="${tmp_dir}/wallpapers"
config_file="${tmp_dir}/ghostty.config"
overlay_file="${tmp_dir}/wallpaper.conf"
state_file="${tmp_dir}/state"
cache_dir="${tmp_dir}/cache"
mkdir -p "${wallpaper_dir}"

cat <<'SWIFT' > "${tmp_dir}/make-oriented-image.swift"
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments[1]
let width = 4
let height = 2

guard let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: width,
  pixelsHigh: height,
  bitsPerSample: 8,
  samplesPerPixel: 3,
  hasAlpha: false,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  fputs("failed to create bitmap\n", stderr)
  exit(1)
}

for y in 0..<height {
  for x in 0..<width {
    bitmap.setColor(
      NSColor(
        calibratedRed: CGFloat(x) / CGFloat(width),
        green: CGFloat(y) / CGFloat(height),
        blue: 0.25,
        alpha: 1.0
      ),
      atX: x,
      y: y
    )
  }
}

guard let cgImage = bitmap.cgImage else {
  fputs("failed to create image\n", stderr)
  exit(1)
}

let destinationURL = URL(fileURLWithPath: outputPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(
  destinationURL,
  UTType.jpeg.identifier as CFString,
  1,
  nil
) else {
  fputs("failed to create destination\n", stderr)
  exit(1)
}

let properties: CFDictionary = [
  kCGImagePropertyOrientation: 8
] as CFDictionary
CGImageDestinationAddImage(destination, cgImage, properties)

guard CGImageDestinationFinalize(destination) else {
  fputs("failed to finalize image\n", stderr)
  exit(1)
}
SWIFT

input_image="${wallpaper_dir}/portrait-exif-8.jpg"
swift "${tmp_dir}/make-oriented-image.swift" "${input_image}"

selected_wallpaper="$(
  bash "${SCRIPT_PATH}" \
    --wallpaper-dir "${wallpaper_dir}" \
    --config-file "${config_file}" \
    --overlay-file "${overlay_file}" \
    --state-file "${state_file}" \
    --cache-dir "${cache_dir}" \
    --reload-method none \
    --print-selection
)"

[[ "${selected_wallpaper}" == "${cache_dir}"/* ]] || {
  printf 'Expected cached normalized wallpaper, got: %s\n' "${selected_wallpaper}" >&2
  exit 1
}

selected_size="$(image_size "${selected_wallpaper}")"
assert_eq "2x2" "${selected_size}" "portrait EXIF image should be normalized and square-cropped"
assert_not_contains "orientation=" "$(file_description "${selected_wallpaper}")" "normalized cropped wallpaper should not retain EXIF orientation metadata"

selected_without_crop="$(
  bash "${SCRIPT_PATH}" \
    --wallpaper-dir "${wallpaper_dir}" \
    --config-file "${config_file}.no-crop" \
    --overlay-file "${overlay_file}.no-crop" \
    --state-file "${state_file}.no-crop" \
    --cache-dir "${cache_dir}" \
    --reload-method none \
    --no-square-crop \
    --print-selection
)"

[[ "${selected_without_crop}" == "${cache_dir}"/* ]] || {
  printf 'Expected cached normalized wallpaper without crop, got: %s\n' "${selected_without_crop}" >&2
  exit 1
}

assert_ne "${selected_wallpaper}" "${selected_without_crop}" "cropped and non-cropped normalized wallpapers should not reuse the same cache path"
assert_eq "2x4" "$(image_size "${selected_without_crop}")" "portrait EXIF image should be normalized without square crop"
assert_not_contains "orientation=" "$(file_description "${selected_without_crop}")" "normalized non-cropped wallpaper should not retain EXIF orientation metadata"
