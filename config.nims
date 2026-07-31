# Put the package source root on the Nim path so that both import styles used
# across the test suite resolve when tests are run as plain `nim c -r tests/x.nim`
# (as `nimble test` does):
#   * bare package imports  — `import gui_assert/emotive`         (tdiscovery, temotive)
#   * sibling-relative imports — `import ../src/gui_assert/parser`  (all other suites)
# nimble injects srcDir for package builds, but the `task test` entries invoke
# the compiler directly, so the bare imports would otherwise fail to resolve.
switch("path", "src")
