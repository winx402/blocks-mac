#!/bin/zsh

set -euo pipefail

binary="${1:-}"
if [[ -z "$binary" || ! -x "$binary" ]]; then
  print -u2 "usage: $0 /absolute/path/to/blocks"
  exit 2
fi
invalid_image="$(mktemp -t blocks-translation-source-image)"
scaffold_directory="$(mktemp -d -t blocks-translation-source-scaffold)"
scaffold_path="$scaffold_directory/Fixture.blocksplugin"
trap 'rm -f "$invalid_image"; rm -rf "$scaffold_directory"' EXIT
print -n "not-an-image" > "$invalid_image"

help_output="$("$binary" translation-source --help)"
[[ "$help_output" == *"blocks translation-source remove SOURCE_ID --confirm"* ]]
[[ "$help_output" == *"blocks translation-source export SOURCE_ID --redact-secrets"* ]]
[[ "$help_output" == *"blocks translation-source list [--json]"* ]]
[[ "$help_output" == *"test SOURCE_ID [--stdin] [--image PATH]"* ]]
[[ "$help_output" != *"remove-confirm"* ]]
[[ "$help_output" != *"export-redacted"* ]]

set +e
remove_output="$("$binary" translation-source remove plugin:fixture 2>&1)"
remove_status=$?
export_output="$("$binary" translation-source export plugin:fixture 2>&1)"
export_status=$?
install_output="$("$binary" translation-source install Missing.blocksplugin --confirm-hash not-a-hash 2>&1)"
install_status=$?
secret_output="$("$binary" translation-source secret set plugin:fixture token 2>&1)"
secret_status=$?
test_input_output="$(printf '\377' | "$binary" translation-source test plugin:fixture --stdin 2>&1)"
test_input_status=$?
test_image_output="$("$binary" translation-source test plugin:fixture --image "$invalid_image" 2>&1)"
test_image_status=$?
scaffold_output="$(
  "$binary" translation-source scaffold --output "$scaffold_path" 2>&1
)"
scaffold_status=$?
validate_scaffold_output="$(
  "$binary" translation-source validate "$scaffold_path" 2>&1
)"
validate_scaffold_status=$?
set -e

[[ $remove_status -eq 2 ]]
[[ "$remove_output" == *'"code" : "confirmation_required"'* ]]
[[ $export_status -eq 2 ]]
[[ "$export_output" == *'"code" : "invalid_arguments"'* ]]
[[ $install_status -eq 2 ]]
[[ "$install_output" == *'"code" : "confirmation_required"'* ]]
[[ $secret_status -eq 2 ]]
[[ "$secret_output" == *'"code" : "invalid_arguments"'* ]]
[[ $test_input_status -eq 2 ]]
[[ "$test_input_output" == *'"code" : "invalid_test_text"'* ]]
[[ "$test_input_output" != *"fixture secret"* ]]
[[ $test_image_status -eq 2 ]]
[[ "$test_image_output" == *'"code" : "invalid_test_image"'* ]]
[[ $scaffold_status -eq 0 ]]
[[ -f "$scaffold_path/manifest.json" ]]
[[ "$scaffold_output" == *'"status" : "completed"'* ]]
[[ $validate_scaffold_status -eq 0 ]]
[[ "$validate_scaffold_output" == *'"status" : "completed"'* ]]

print "translation-source CLI parsing and confirmation checks passed"
