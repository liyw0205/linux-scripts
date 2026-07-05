#!/usr/bin/env bats

@test "webdav relay skips same-size remote file" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" skip
  [ "$status" -eq 0 ]
}

@test "webdav relay stop kills active copyto" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" stop
  [ "$status" -eq 0 ]
}
