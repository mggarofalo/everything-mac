#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "SwiftLint is required (brew install swiftlint)." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required (brew install xcodegen)." >&2
  exit 1
fi

echo "Auditing cyclomatic complexity (maximum 10)..."
swiftlint lint --strict --config .swiftlint.yml Sources App

echo "Running tests with coverage..."
swift test --enable-code-coverage

coverage_json="$(swift test --show-codecov-path)"
profile="${coverage_json%/*}/default.profdata"
binary="$(swift build --show-bin-path)/IndexCorePackageTests.xctest/Contents/MacOS/IndexCorePackageTests"
report="$(xcrun llvm-cov report "$binary" \
  -instr-profile="$profile" \
  -ignore-filename-regex='Tests/|\.build/' \
  Sources/IndexCore/*.swift)"
printf '%s\n' "$report"

minimum_line_coverage=95
minimum_file_line_coverage=85
line_coverage="$(awk '/^TOTAL/ { value=$10; sub(/%/, "", value); print value }' <<<"$report")"
if [[ -z "$line_coverage" ]]; then
  echo "Could not read total line coverage." >&2
  exit 1
fi
if ! awk -v actual="$line_coverage" -v minimum="$minimum_line_coverage" \
  'BEGIN { exit !(actual >= minimum) }'; then
  echo "Line coverage ${line_coverage}% is below ${minimum_line_coverage}%." >&2
  exit 1
fi
echo "Line coverage ${line_coverage}% meets the ${minimum_line_coverage}% floor."

if ! awk -v minimum="$minimum_file_line_coverage" '
  $1 ~ /\.swift$/ {
    value=$10
    sub(/%/, "", value)
    if ((value + 0) < (minimum + 0)) {
      printf "%s line coverage %.2f%% is below %.2f%%.\n", $1, value, minimum > "/dev/stderr"
      failed=1
    }
  }
  END { exit failed }
' <<<"$report"; then
  exit 1
fi
echo "Every core source file meets the ${minimum_file_line_coverage}% line-coverage floor."

echo "Running indexing-service boundary tests..."
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/EverythingMac.xcodeproj \
  -scheme EverythingMacServiceTests \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
