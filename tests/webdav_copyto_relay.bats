#!/usr/bin/env bats

@test "webdav relay skips same-size remote file" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" skip
  [ "$status" -eq 0 ]
}

@test "webdav relay stop kills active copyto" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" stop
  [ "$status" -eq 0 ]
}

@test "webdav relay start remote failure is read-only" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" remote-fail
  [ "$status" -eq 0 ]
}

@test "webdav relay reconfig probe failure preserves config" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" reconfig-fail
  [ "$status" -eq 0 ]
}

@test "webdav relay reconfig path failure preserves real remote" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" reconfig-path-fail
  [ "$status" -eq 0 ]
}

@test "webdav relay reconfig success updates config after probe" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" reconfig-success
  [ "$status" -eq 0 ]
}

@test "webdav relay reconfig update failure restores config" {
  run bash "$BATS_TEST_DIRNAME/webdav_copyto_relay_regression.sh" reconfig-update-fail
  [ "$status" -eq 0 ]
}
