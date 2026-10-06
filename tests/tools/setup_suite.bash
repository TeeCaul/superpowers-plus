# bats-core loads setup_suite.bash only from the directory of the suite it
# runs, so `bats tests/tools/<file>.bats` never sees tests/setup_suite.bash.
# Same guard, same reason: see test/setup_suite.bash. A GIT_DIR leaked into
# the invoking shell would redirect these fixtures' git init/commit calls
# onto whatever repo it names.
setup_suite() {
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
}
