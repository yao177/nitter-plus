import std/[os, unittest]

import ../src/config

suite "configuration validation":
  let path = getTempDir() / "nitter-plus-test-config.conf"

  teardown:
    if fileExists(path):
      removeFile(path)

  test "accepts zero reserved requests":
    writeFile(path, "[Config]\ntokenCount = 0\n")
    let (config, _) = getConfig(path)
    check config.minTokens == 0

  test "rejects a negative reserved request count":
    writeFile(path, "[Config]\ntokenCount = -1\n")
    expect ValueError:
      discard getConfig(path)
