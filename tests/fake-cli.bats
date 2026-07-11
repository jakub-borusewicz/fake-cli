bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "intercepts and logs argv as json, including args with spaces" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic export "with a space" </dev/null
  [ "$(jq -r '.argv | length' "$TEST_DIR/001.json")" = "2" ]
  [ "$(jq -r '.argv[0]' "$TEST_DIR/001.json")" = "export" ]
  [ "$(jq -r '.argv[1]' "$TEST_DIR/001.json")" = "with a space" ]
}

@test "numbers sequential calls" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic one </dev/null
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic two </dev/null
  [ -f "$TEST_DIR/001.json" ]
  [ -f "$TEST_DIR/002.json" ]
}

@test "captures piped stdin" {
  echo -n "hello stdin" | FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic anything
  [ "$(jq -r '.stdin' "$TEST_DIR/001.json")" = "hello stdin" ]
}

@test "no stdin captured when none piped" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic anything </dev/null
  [ "$(jq -r '.stdin' "$TEST_DIR/001.json")" = "" ]
}

@test "global mock stdout/stderr/exit code apply to all calls" {
  run env FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" FAKE_TEST_BASIC_MOCK_STDOUT="out" \
    FAKE_TEST_BASIC_MOCK_STDERR="err" FAKE_TEST_BASIC_MOCK_EXIT_CODE="3" \
    fake-test-basic call </dev/null
  [ "$status" -eq 3 ]
  # stdout and stderr are both plain printf with no trailing newline, and
  # `run` merges them in write order, so they land concatenated.
  [ "$output" = "outerr" ]
}

@test "per-call override applies only to that call number" {
  export FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR"
  export FAKE_TEST_BASIC_MOCK_STDOUT="global"
  export FAKE_TEST_BASIC_MOCK_STDOUT_2="second-call-only"

  run fake-test-basic a </dev/null
  [ "$output" = "global" ]
  run fake-test-basic b </dev/null
  [ "$output" = "second-call-only" ]
  run fake-test-basic c </dev/null
  [ "$output" = "global" ]
}

@test "passthroughWhen true execs the real binary" {
  run hello pass
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra operand"* ]]
}

@test "passthroughWhen false intercepts" {
  HELLO_CALLS_DIR="$TEST_DIR" hello nope </dev/null
  [ -f "$TEST_DIR/001.json" ]
}

@test "refuses to run without a realPackage configured" {
  run -127 fake-test-norealpkg status
  [[ "$output" == *"refusing to run for real"* ]]
}

@test "honors custom env var names" {
  run env CUSTOM_CALLS_DIR="$TEST_DIR" CUSTOM_STDOUT="custom" CUSTOM_EXIT="5" \
    fake-test-customenv x </dev/null
  [ "$status" -eq 5 ]
  [ "$output" = "custom" ]
  [ "$(jq -r '.argv[0]' "$TEST_DIR/001.json")" = "x" ]
}
