#/usr/bin/env bash

set -o pipefail
set -o errexit


GTD="../gtd.sh"
TEST_DIR="./test"


# Helper Functions ************************************************************


function setup {
    rm -rf   "${TEST_DIR}"
    mkdir -p "${TEST_DIR}"
    pushd    "${TEST_DIR}" > /dev/null
}

function tear_down {
    popd > /dev/null
}

# print message to stderr and exit.
function error {
    echo "$*" >&2
    exit 1
}


# bash error handling is kindof broken. set -e appears not to have
# any effect within a shell function? I was expecting that if line
# in a shell function "fails" with set -e in place, that it would
# trigger early return from the function with the last exit
# code. But it doesn't.
#
# I want `assert_*` to reliably "fail fast" *within* a given test, but
# not stop other tests.
#
# The simplest way to get this behavior is to recursively re-invoke
# ourselves.
#
# This way, `error` can simply `exit 1`, and we can easily catch
# this in the parent shell.

# run a test and report its error status.
function should_pass {
    local test_name="$1"
    tests=$((tests + 1))

    setup

    # setup prepares the test directory and cds into it for us, so
    # that's why I'm using a relative path here, but there's probably
    # a less brittle way to arrange this.
    if ../test.sh "$@"; then
	echo "${test_name}... ok"
    else
	echo "${test_name}... failed"
	failures=$((failures + 1))
    fi

    tear_down
}

function should_fail {
    local test_name="$1"
    tests=$((tests + 1))

    setup
    
    # setup prepares the test directory and cds into it for us, so
    # that's why I'm using a relative path here, but there's probably
    # a less brittle way to arrange this.
    if ../test.sh "$@"; then
	echo "${test_name}... failed"
	failures=$((failures + 1))
    else
	echo "${test_name}... ok"
    fi

    tear_down
}


function print_summary {
    echo "Failed: ${failures}"
    echo "Total:  ${tests}"

    if test "${failures}" -gt 0; then
	exit 1
    fi
}

function assert {
    test "$@"|| error "Assertion failed: $*"
}

function assert_false {
    if "$@"; then
	error "'$*' should be false"
    fi
}

function assert_true {
    if "$@"; then
	return 0;
    else
	error "'$*' should be true"
    fi
}

function gtd {
    "${GTD}" "$@"
}

function make_test_node {
    local name="$1"
    local id="$(gtd graph_node_create)" || error "couldn't create ${name}"
    echo "${name}" | gtd graph_datum contents write "${id}"
    echo "${id}"
    # sleep just long enough that each node gets a distinct timestamp.
    # this causes ls -t to produce a stable sorting order
    sleep 0.01
}

function make_test_edge {
    local id="$(gtd graph_edge_create "$1" "$2" "$3")" || error "couldn't create $*}"
    sleep 0.01
}

# helper for testing filter_*
function isYes {
    case "$1" in
	yes) return 0;;
	*)   return 1;;
    esac
}

# helper for testing map_words
function yesToNo {
    case "$1" in
	yes) echo -n "no";;
	no)  echo -n "yes";;
    esac
}

# helper for testing map_lines
function yesToNoLines {
    case "$1" in
	yes) echo "no";;
	no)  echo "yes";;
    esac
}


# Test cases ******************************************************************


function test_error_handling {
    error "force failure" &> /dev/null
    echo "if you see this, something is broken"
}

function test_assert_true_false {
    assert_true false &> /dev/null
}

function test_assert_true_true {
    assert_true true
}

function test_assert_false_false {
    assert_false false
}

function test_assert_false_true {
    assert_false true &> /dev/null
}

function test_filter_words {
    local actual="$(echo yes no yes yes no no | gtd filter_words ../test.sh isYes)"
    local expected="yes yes yes"
    assert "${actual}" = "${expected}"
}

function test_filter_lines {
    local actual="$(printf 'yes\nno\nyes\n\yes\no' | gtd filter_lines ../test.sh isYes)"
    local expected="$(printf 'yes\nyes\nyes')"
    assert "${actual}" = "${expected}"
}

function test_map_words {
    local actual="$(echo yes no yes yes no no | gtd map_words ../test.sh yesToNo)"
    local expected="no yes no no yes yes"
    assert "${actual}" = "${expected}"
}

function test_map_lines {
    local actual="$(printf 'yes\nno\nyes\nyes\nno\n' | gtd map_lines ../test.sh yesToNoLines)"
    local expected="$(printf 'no\nyes\nno\nno\nyes')"
    assert "${actual}" = "${expected}"
}

function test_database_init {
    gtd database_init || error "Should have succeeded."
    assert -d "gtdgraph/state/nodes"
    assert -d "gtdgraph/state/dependencies"
    assert -d "gtdgraph/state/contexts"
}

function test_database_ensure_init {
    mkdir gtdgraph
    gtd database_ensure_init   || error "Should have exited zero"
    rm -rf gtdgraph
    ! gtd database_ensure_init &> /dev/null || error "Should have exited nonzero"
}

function test_database_clobber {
    gtd database_init

    if echo no | gtd database_clobber &> /dev/null; then
	error "Should have failed"
    else
	test -d "gtdgraph" || error "Data dir should still exist"
    fi

    if echo yes | gtd database_clobber &> /dev/null; then
	! test -d "gtdgraph" || error "Data dir should not exist"
    else
	error "Should have succeeded"
    fi
}

function test_graph_node_path {
    local id="fake-uuid"
    local dir="./gtdgraph/state/nodes/fake-uuid"
    assert "$(gtd graph_node_path ${id})" = "${dir}"
}

function test_graph_node_gen_id {
    gtd database_init
    local id1="$(gtd graph_node_gen_id)" || error "Should have generated an id"
    local id2="$(gtd graph_node_gen_id)" || error "Should have generated an id"
    test "${id1}" != "${id2}"            || error "Ids should be different"
}

function test_graph_node_list {
    # sleeps inserted here to make sure each node gets a distinct timestamp
    # default ordering is most recent first.
    mkdir -p "gtdgraph/state/nodes/fake-uuid-1"
    sleep 0.01
    mkdir -p "gtdgraph/state/nodes/fake-uuid-2"
    sleep 0.01
    mkdir -p "gtdgraph/state/nodes/fake-uuid-3"
    sleep 0.01

    local -a actual=($(gtd graph_node_list))
    local -a expected=(fake-uuid-3 fake-uuid-2 fake-uuid-1)

    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_node_create {
    gtd database_init

    # test creating with a user-supplied ID
    local id="fake-uuid"
    local dir="gtdgraph/state/nodes/${id}"
    assert_true gtd graph_node_create fake-uuid > /dev/null
    assert -e "$(gtd graph_node_path ${id})"

    # test node generation
    local id="$(gtd graph_node_create)" || error "Should have generated a node."
    assert -e "$(gtd graph_node_path "${id}")"
}

function test_graph_datum {
    gtd init
    local id="fake-uuid"
    assert "$(gtd graph_node_create "${id}")" = "${id}"

    # subcommand: path
    local path="./gtdgraph/state/nodes/fake-uuid/contents"
    assert "$(gtd graph_datum contents path "${id}")" = "${path}"

    # subcommand: write
    echo FOO | gtd graph_datum contents write "${id}"
    assert "$(cat "${path}")" = "FOO"
    
    echo "lulululu" > "gtdgraph/state/nodes/fake-uuid/contents"
    assert    "$(gtd graph_datum contents read fake-uuid)" = "lulululu"
    assert -z "$(gtd graph_datum contents read does-not-exist)"
    assert_false gtd graph_datum unpossible read uuid-1
}

function test_graph_node_adjacent {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t3}" "${t4}" dep

    # test outgoing edges for t1
    local -a actual=($(gtd graph_node_adjacent "${t1}" dep outgoing))
    local -a expected=("${t3}" "${t2}" )
    assert "${actual[*]}" = "${expected[*]}"

    # test outgoing edges for t2
    local -a actual=($(gtd graph_node_adjacent "${t2}" dep outgoing))
    local -a expected=("${t4}")
    assert "${actual[*]}" = "${expected[*]}"

    # test outgoing edges for t3
    local -a actual=($(gtd graph_node_adjacent "${t3}" dep outgoing))
    local -a expected=("${t4}")
    assert "${actual[*]}" = "${expected[*]}"

    # test outgoing edges for t4
    assert -z "$(gtd graph_node_adjacent "${t4}" dep outgoing)"

    # test incoming edges for t4
    local -a actual=($(gtd graph_node_adjacent "${t4}" dep incoming))
    local -a expected=("${t3}" "${t2}")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_edge {
    local u="fake-uuid-1"
    local v="fake-uuid-2"
    local edge="fake-uuid-1:fake-uuid-2"
    assert "$(gtd graph_edge   "${u}" "${v}")" = "fake-uuid-1:fake-uuid-2"
    assert "$(gtd graph_edge_u "${edge}")" = "fake-uuid-1"
    assert "$(gtd graph_edge_v "${edge}")" = "fake-uuid-2"
}

function test_graph_edge_path {
    local u="fake-uuid-1"
    local v="fake-uuid-2"
    local dep="./gtdgraph/state/dependencies/fake-uuid-1:fake-uuid-2"
    local ctx="./gtdgraph/state/contexts/fake-uuid-1:fake-uuid-2"

    mkdir -p "./gtdgraph/state/nodes/${u}"
    mkdir -p "./gtdgraph/state/nodes/${v}"
    mkdir -p "${dep}"
    mkdir -p "${ctx}"

    assert "$(gtd graph_edge_path "${u}" "${v}" dep)"     = "${dep}"
    assert "$(gtd graph_edge_path "${u}" "${v}" context)" = "${ctx}"
}

function test_graph_edge_create {
    local u="fake-uuid-1"
    local v="fake-uuid-2"
    local w="fake-uuid-3"

    mkdir -p "./gtdgraph/state/nodes/${u}"
    mkdir -p "./gtdgraph/state/nodes/${v}"

    gtd graph_edge_create "${u}" "${v}" dep                  || error "should succeed"
    gtd graph_edge_create "${u}" "${w}" dep     &> /dev/null && error "should fail"
    gtd graph_edge_create "${u}" "${v}" context              || error "should succeed"
    gtd graph_edge_create "${w}" "${v}" context &> /dev/null && error "should fail"
    gtd graph_edge_create "${u}" "${v}" derp    &> /dev/null && error "should fail"

    test -d "./gtdgraph/state/dependencies/fake-uuid-1:fake-uuid-2"
}

function test_graph_edge_delete {
    local u="fake-uuid-1"
    local v="fake-uuid-2"

    mkdir -p "./gtdgraph/state/nodes/${u}"
    mkdir -p "./gtdgraph/state/nodes/${v}"
    mkdir -p "./gtdgraph/state/dependencies/${u}:${v}"

    assert -d "./gtdgraph/state/dependencies/${u}:${v}"

    gtd graph_edge_delete "${u}" "${v}" dep || error "should succeed"
   
    assert ! -d "./gtdgraph/state/dependencies/${u}:${v}"
}

function test_graph_traverse {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t3}" "${t4}" dep
    make_test_edge "${t5}" "${t4}" dep

    local -a actual=($(gtd graph_traverse "${t1}" dep outgoing | gtd map_words task_gloss ))
    local -a expected=("t1" "t3" "t4" "t2")
    assert "${actual[*]}" = "${expected[*]}"

    actual=($(gtd graph_traverse "${t4}" dep incoming | gtd map_words task_gloss ))
    expected=("t4" "t5" "t3" "t1" "t2")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_traverse_with_cycle {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    # create a cycle 
    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t4}" "${t1}" dep

    if gtd graph_traverse "${t1}" dep outgoing &> /dev/null; then
	error "should fail"
    fi
}

function test_task_contents {
    mkdir -p "gtdgraph/state/nodes/fake-uuid-1"
    mkdir -p "gtdgraph/state/nodes/fake-uuid-2"
    echo "lulululu" > "gtdgraph/state/nodes/fake-uuid-1/contents"
    assert "$(gtd task_contents read fake-uuid-1)" = "lulululu"
}

function test_task_gloss {
    gtd init
    local path="./gtdgraph/state/nodes/fake-uuid"

    # create a node with multi-line contents file
    mkdir -p "${path}"
    echo "foo" >> "${path}/contents"
    echo "bar" >> "${path}/contents"

    # check that gloss is only the first line
    assert "$(gtd task_gloss fake-uuid)" = "foo"
}

function test_task_state {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    assert "$(gtd task_state path fake-uuid)" = "./gtdgraph/state/nodes/fake-uuid/state"

    echo "NEW" | gtd task_state write fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "NEW"

    echo "TODO" | gtd task_state write fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "TODO"

    echo "COMPLETE" | gtd task_state write fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "COMPLETE"
}

function test_task_is_active {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_active fake-uuid

    echo "TODO" | gtd task_state write fake-uuid
    assert_true gtd task_is_active fake-uuid

    echo "COMPLETE" | gtd task_state write fake-uuid
    assert_false gtd task_is_active fake-uuid

    echo "WAITING" | gtd task_state write fake-uuid
    assert_true gtd task_is_active fake-uuid
}

function test_task_is_actionable {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_actionable fake-uuid

    echo "TODO" | gtd task_state write fake-uuid
    assert_true gtd task_is_actionable fake-uuid

    echo "COMPLETE" | gtd task_state write fake-uuid
    assert_false gtd task_is_actionable fake-uuid

    echo "WAITING" | gtd task_state write fake-uuid
    assert_false gtd task_is_actionable fake-uuid
}

function test_task_summary {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid

    echo "foo bar baz" | gtd task_contents write fake-uuid
    assert "$(gtd task_summary fake-uuid)" = "fake-uuid NEW foo bar baz"
}


# Entry Point *****************************************************************


function run_all_tests {
    should_fail test_error_handling
    should_fail test_assert_true_false
    should_pass test_assert_true_true
    should_pass test_assert_false_false
    should_fail test_assert_false_true
    
    should_pass test_filter_words
    should_pass test_filter_lines
    should_pass test_map_words
    should_pass test_map_lines

    should_pass test_database_ensure_init
    should_pass test_database_init
    should_pass test_database_clobber

    should_pass test_graph_node_path
    should_pass test_graph_node_gen_id
    should_pass test_graph_node_list
    should_pass test_graph_node_create
    should_pass test_graph_node_adjacent

    should_pass test_graph_edge
    should_pass test_graph_edge_path
    should_pass test_graph_edge_create
    should_pass test_graph_edge_delete

    should_pass test_graph_datum
    should_pass test_graph_traverse
    should_pass test_graph_traverse_with_cycle

    should_pass test_task_contents
    should_pass test_task_gloss
    should_pass test_task_state
    should_pass test_task_is_active
    should_pass test_task_is_actionable
    should_pass test_task_summary

    print_summary
}

declare -i tests=0
declare -i failures=0

case "$*" in
    "")     run_all_tests;;
    *)      "$@"
esac
