#!/bin/bash
set -euo pipefail

# Each file name carries the build number, so a deploy never replaces a library a client pins.
dest="s3://vivi-devops-packages/openh264"
build="${BUILDKITE_BUILD_NUMBER}"

echo "--- :buildkite: Download"
buildkite-agent artifact download "out/*" .

echo "--- :s3: Check"
for arch in x86 arm64; do
  for file in "openh264-${build}-${arch}.lib" "openh264-${build}-${arch}.lib.txt"; do
    # `aws s3 ls` exits 1 when nothing matches, and also on other failures, so read its output.
    if aws s3 ls "${dest}/${file}" | grep -q " ${file}$"; then
      echo "${dest}/${file} already exists; refusing to overwrite it"
      exit 1
    fi
  done
done

echo "--- :s3: Upload"
for arch in x86 arm64; do
  aws s3 cp "out/${arch}/openh264.lib" "${dest}/openh264-${build}-${arch}.lib"
  aws s3 cp "out/${arch}/openh264.lib.txt" "${dest}/openh264-${build}-${arch}.lib.txt"
done
