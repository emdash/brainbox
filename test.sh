#/usr/bin/env bash

set -o pipefail
set -o errexit


GTD="../gtd.sh"
TEST_DIR="./test"
FUNC_DIR="$(pwd)/tattle"


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
    line="$(caller 0 | cut -d ' ' -f 1)"
    file="$(basename $(caller 0 | cut -d ' ' -f 3))"
    echo "${file}:${line} $*" >&2
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

    test -d "${FUNC_DIR}" && rm "${FUNC_DIR}/${test_name}"

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

    test -d "${FUNC_DIR}" && rm "${FUNC_DIR}/${test_name}"

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
    if test "$@"; then
	:
    else
	local line func file
	line="$(caller 0 | cut -d ' ' -f 1)"
	file="$(basename $(caller 0 | cut -d ' ' -f 3))"	
	echo "${file}:${line} Assertion failed: $*" >&2
	exit 1
    fi
}

function assert_false {
    if "$@"; then
	local line func file
	line="$(caller 0 | cut -d ' ' -f 1)"
	file="$(basename $(caller 0 | cut -d ' ' -f 3))"	
	echo "${file}:${line} '$*' should be false" >&2
	exit 1
    fi
}

function assert_true {
    if "$@"; then
	return 0;
    else
	local line func file
	line="$(caller 0 | cut -d ' ' -f 1)"
	file="$(basename $(caller 0 | cut -d ' ' -f 3))"
	echo "${file}:${line} '$*' should be true" >&2
	exit 1
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

# helper for testing map
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


# There should be a test function here for each function in gtd.sh, in
# the same order, so it's easy to spot functions which do not have
# tests.
#
# exception: functions which start with __, which are an
# implementation detail of some other function, usually a recursion
# helper. these do not need to be tested separately.

function test_filter {
    local actual="$(printf 'yes\nno\nyes\n\yes\no' | gtd filter ../test.sh isYes)"
    local expected="$(printf 'yes\nyes\nyes')"
    assert "${actual}" = "${expected}"
}

function test_map {
    local actual="$(printf 'yes\nno\nyes\nyes\nno\n' | gtd map ../test.sh yesToNoLines)"
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

    # subcommand: read
    echo "lulululu" > "gtdgraph/state/nodes/fake-uuid/contents"
    assert    "$(gtd graph_datum contents read fake-uuid)" = "lulululu"
    assert -z "$(gtd graph_datum contents read does-not-exist)"
    assert_false gtd graph_datum unpossible read uuid-1

    # subcommand: write
    echo "foo" | gtd graph_datum contents write fake-uuid
    assert "$(gtd graph_datum contents read fake-uuid)" = "foo"

    # subcommand: append
    echo "bar" | gtd graph_datum contents append fake-uuid
    assert "$(gtd graph_datum contents read fake-uuid)" = "$(echo -e 'foo\nbar')"

    # subcommand: mkdir / exists
    gtd graph_datum some_user_dir mkdir fake-uuid
    assert -e "$(gtd graph_datum some_user_dir path fake-uuid)"
    assert_true gtd graph_datum some_user_dir exists fake-uuid

    # subcommand: cp
    touch {foo,bar,baz}.txt
    assert -e foo.txt
    assert -e bar.txt
    assert -e baz.txt
    gtd graph_datum some_user_dir cp fake-uuid {foo,bar,baz}.txt
    assert -e "$(gtd graph_datum some_user_dir path fake-uuid)/foo.txt"
    assert -e "$(gtd graph_datum some_user_dir path fake-uuid)/bar.txt"
    assert -e "$(gtd graph_datum some_user_dir path fake-uuid)/baz.txt"

    # subcommand: mv
    touch {foo,bar,baz}.txt
    assert -e foo.txt
    assert -e bar.txt
    assert -e baz.txt
    gtd graph_datum other_user_dir mkdir fake-uuid
    gtd graph_datum other_user_dir mv fake-uuid {foo,bar,baz}.txt
    assert -e "$(gtd graph_datum other_user_dir path fake-uuid)/foo.txt"
    assert -e "$(gtd graph_datum other_user_dir path fake-uuid)/bar.txt"
    assert -e "$(gtd graph_datum other_user_dir path fake-uuid)/baz.txt"
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
    local -a expected=("${t2}" "${t3}" )
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
    local -a expected=("${t2}" "${t3}")
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

    local -a actual=($(gtd graph_traverse "${t1}" dep outgoing | gtd map task_gloss ))
    local -a expected=("t1" "t2" "t4" "t3")
    assert "${actual[*]}" = "${expected[*]}"

    actual=($(gtd graph_traverse "${t4}" dep incoming | gtd map task_gloss ))
    expected=("t4" "t2" "t1" "t3" "t5")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_traverse_with_cycle {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t4}" "${t1}" dep

    # will fail
    gtd graph_traverse "${t1}" dep outgoing &> /dev/null
}

function test_graph_expand {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t3}" "${t4}" dep

    local -a actual=($(gtd graph_expand "${t1}" dep outgoing | gtd map task_gloss ))
    local -a expected=("t1" "t2" "t4" "t3" "t4")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_expand_with_depth {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t3}" "${t4}" dep

    local -a actual=($(gtd graph_expand --depth "${t1}" dep outgoing | cut -d ' ' -f 2 ))
    local -a expected=("0" "1" "2" "1" "2")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_graph_expand_with_cycle {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep
    make_test_edge "${t4}" "${t1}" dep

    # will fail
    gtd graph_expand "${t1}" dep outgoing &> /dev/null
}

function test_task_state_is_valid {
    assert_true  gtd task_state_is_valid NEW
    assert_true  gtd task_state_is_valid TODO
    assert_true  gtd task_state_is_valid DONE
    assert_true  gtd task_state_is_valid DROPPED
    assert_true  gtd task_state_is_valid WAITING
    assert_true  gtd task_state_is_valid SOMEDAY
    assert_true  gtd task_state_is_valid PERSIST
    assert_false gtd task_state_is_valid COMPLETE
    assert_false gtd task_state_is_valid COMPLETED
    assert_false gtd task_state_is_valid WAIT
    assert_false gtd task_state_is_valid DEFERRED
    assert_false gtd task_state_is_valid FOOBAR
}

function test_task_state_is_active {
    assert_true  gtd task_state_is_active NEW
    assert_true  gtd task_state_is_active TODO
    assert_false gtd task_state_is_active DONE
    assert_false gtd task_state_is_active DROPPED
    assert_true  gtd task_state_is_active WAITING
    assert_false gtd task_state_is_active SOMEDAY
    assert_true  gtd task_state_is_active PERSIST
}

function test_task_state_is_actionable {
    assert_true  gtd task_state_is_actionable NEW
    assert_true  gtd task_state_is_actionable TODO
    assert_false gtd task_state_is_actionable COMPLETE
    assert_false gtd task_state_is_actionable DROPPED
    assert_false gtd task_state_is_actionable WAITING
    assert_false gtd task_state_is_actionable SOMEDAY
    assert_false gtd task_state_is_actionable PERSIST
}

function test_task_contents {
    mkdir -p "gtdgraph/state/nodes/fake-uuid-1"
    mkdir -p "gtdgraph/state/nodes/fake-uuid-2"
    echo "lulululu" > "gtdgraph/state/nodes/fake-uuid-1/contents"
    assert "$(gtd task_contents read fake-uuid-1)" = "lulululu"
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

function test_task_is_root {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep

    assert_true  gtd task_is_root "${t1}"
    assert_false gtd task_is_root "${t2}"
    assert_false gtd task_is_root "${t3}"
    assert_false gtd task_is_root "${t4}"
}

function test_task_is_leaf {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep

    assert_false gtd task_is_leaf "${t1}"
    assert_false gtd task_is_leaf "${t2}"
    assert_true  gtd task_is_leaf "${t3}"
    assert_true  gtd task_is_leaf "${t4}"
}

function test_task_is_orphan {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t2}" "${t4}" dep

    assert_false gtd task_is_orphan "${t1}"
    assert_false gtd task_is_orphan "${t2}"
    assert_false gtd task_is_orphan "${t3}"
    assert_false gtd task_is_orphan "${t4}"
    assert_true  gtd task_is_orphan "${t5}"
}

function test_task_is_new {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_new fake-uuid

    echo "TODO" | gtd task_state write fake-uuid
    assert_false gtd task_is_new fake-uuid

    echo "COMPLETE" | gtd task_state write fake-uuid
    assert_false gtd task_is_new fake-uuid

    echo "WAITING" | gtd task_state write fake-uuid
    assert_false gtd task_is_new fake-uuid

    echo "SOMEDAY" | gtd task_state write fake-uuid
    assert_false gtd task_is_new fake-uuid
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

    echo "SOMEDAY" | gtd task_state write fake-uuid
    assert_false gtd task_is_active fake-uuid

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

    echo "SOMEDAY" | gtd task_state write fake-uuid
    assert_false gtd task_is_active fake-uuid
}

function test_task_is_next_action {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t3}" "${t4}" dep
    make_test_edge "${t2}" "${t4}" dep

    gtd activate

    assert_false gtd task_is_next_action "${t1}"
    assert_false gtd task_is_next_action "${t2}"
    assert_false gtd task_is_next_action "${t3}"
    assert_true  gtd task_is_next_action "${t4}"
    assert_true  gtd task_is_next_action "${t5}"
}

function test_task_is_next_action {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dep
    make_test_edge "${t1}" "${t3}" dep
    make_test_edge "${t3}" "${t4}" dep
    make_test_edge "${t2}" "${t4}" dep

    assert_true gtd task_is_unassigned "${t1}"
    assert_true gtd task_is_unassigned "${t2}"
    assert_true gtd task_is_unassigned "${t3}"
    assert_true gtd task_is_unassigned "${t4}"
    assert_true gtd task_is_unassigned "${t5}"

    make_test_edge "${t5}" "${t4}" context
    assert_true  gtd task_is_unassigned "${t1}"
    assert_true  gtd task_is_unassigned "${t2}"
    assert_true  gtd task_is_unassigned "${t3}"
    assert_false gtd task_is_unassigned "${t4}"
    assert_true  gtd task_is_unassigned "${t5}"

    make_test_edge "${t5}" "${t1}" context
    assert_false gtd task_is_unassigned "${t1}"
    assert_true  gtd task_is_unassigned "${t2}"
    assert_true  gtd task_is_unassigned "${t3}"
    assert_false gtd task_is_unassigned "${t4}"
    assert_true  gtd task_is_unassigned "${t5}"
}

function test_task_is_waiting {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    echo "NEW" | gtd task_state write fake-uuid
    assert_false gtd task_is_waiting fake-uuid

    echo "TODO" | gtd task_state write fake-uuid
    assert_false gtd task_is_waiting fake-uuid

    echo "COMPLETE" | gtd task_state write fake-uuid
    assert_false gtd task_is_waiting fake-uuid

    echo "WAITING" | gtd task_state write fake-uuid
    assert_true gtd task_is_waiting fake-uuid

    echo "SOMEDAY" | gtd task_state write fake-uuid
    assert_false gtd task_is_waiting fake-uuid
}

function test_task_summary {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid

    echo "foo bar baz" | gtd task_contents write fake-uuid
    assert "$(gtd task_summary fake-uuid)" = "fake-uuid     NEW foo bar baz"
}

function test_task_auto_triage {
    gtd init

    # should automaticall transition from NEW to TODO
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_new fake-uuid
    gtd task_auto_triage fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "TODO"

    # should not change state
    echo "COMPLETE" | gtd task_state write fake-uuid
    gtd task_auto_triage fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "COMPLETE"
}

function test_task_add_subtask {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    echo NEW | gtd task_state write "${t1}"
    echo NEW | gtd task_state write "${t2}"
    echo NEW | gtd task_state write "${t3}"
    echo NEW | gtd task_state write "${t4}"
    echo NEW | gtd task_state write "${t5}"

    assert_true gtd task_is_new "${t1}"
    assert_true gtd task_is_new "${t2}"
    assert_true gtd task_is_new "${t3}"
    assert_true gtd task_is_new "${t4}"
    assert_true gtd task_is_new "${t5}"

    gtd task_add_subtask "${t1}" "${t2}"
    gtd task_add_subtask "${t1}" "${t3}"
    gtd task_add_subtask "${t2}" "${t4}"
    gtd task_add_subtask "${t3}" "${t4}"
    gtd task_add_subtask "${t4}" "${t5}"

    assert_true  gtd task_is_new "${t1}"
    assert_false gtd task_is_new "${t2}"
    assert_false gtd task_is_new "${t3}"
    assert_false gtd task_is_new "${t4}"
    assert_false gtd task_is_new "${t5}"

    local -a actual=($(gtd graph_traverse "${t1}" dep outgoing | gtd map task_gloss))
    local -a expected=("t1 t2 t4 t5 t3")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_task_assign {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    echo NEW | gtd task_state write "${t1}"
    echo NEW | gtd task_state write "${t2}"
    echo NEW | gtd task_state write "${t3}"
    echo NEW | gtd task_state write "${t4}"
    echo NEW | gtd task_state write "${t5}"

    assert_true gtd task_is_new "${t1}"
    assert_true gtd task_is_new "${t2}"
    assert_true gtd task_is_new "${t3}"
    assert_true gtd task_is_new "${t4}"
    assert_true gtd task_is_new "${t5}"

    gtd task_assign "${t1}" "${t5}"
    gtd task_assign "${t3}" "${t5}"
    gtd task_assign "${t4}" "${t5}"

    assert_false gtd task_is_new "${t1}"
    assert_true  gtd task_is_new "${t2}"
    assert_false gtd task_is_new "${t3}"
    assert_false gtd task_is_new "${t4}"
    assert_true  gtd task_is_new "${t5}"

    local -a actual=($(gtd graph_traverse "${t5}" context outgoing | gtd map task_gloss))
    local -a expected=("t5 t1 t3 t4")
    assert "${actual[*]}" = "${expected[*]}"
}

function test_task_activate {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "DROPPED" | gtd task_state write fake-uuid
    assert_false gtd task_is_active fake-uuid
    gtd task_activate fake-uuid
    assert_true gtd task_is_active fake-uuid
}

function test_task_drop {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_new fake-uuid
    gtd task_drop fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "DROPPED"
}

function test_task_complete {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_new fake-uuid
    gtd task_complete fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "DONE"
}

function test_task_defer {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true gtd task_is_new fake-uuid
    gtd task_defer fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "SOMEDAY"
}


# Entry Point *****************************************************************


function run_all_tests {
    should_fail test_error_handling
    should_fail test_assert_true_false
    should_pass test_assert_true_true
    should_pass test_assert_false_false
    should_fail test_assert_false_true
    
    should_pass test_filter
    should_pass test_map

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
    should_fail test_graph_traverse_with_cycle
    should_pass test_graph_expand
    should_pass test_graph_expand_with_depth
    should_fail test_graph_expand_with_cycle

    should_pass test_task_contents
    should_pass test_task_gloss
    should_pass test_task_is_root
    should_pass test_task_is_leaf
    should_pass test_task_state
    should_pass test_task_state_is_valid
    should_pass test_task_state_is_active
    should_pass test_task_state_is_actionable
    should_pass test_task_auto_triage
    should_pass test_task_is_active
    should_pass test_task_is_actionable
    should_pass test_task_is_new
    should_pass test_task_is_next_action
    should_pass test_task_is_orphan
    should_pass test_task_is_waiting
    should_pass test_task_add_subtask
    should_pass test_task_assign
    should_pass test_task_summary
    should_pass test_task_drop
    should_pass test_task_activate
    should_pass test_task_complete
    should_pass test_task_defer

    print_summary
}

# warn about missing tests
function tattle {
    # make a directory with a file for every test case
    mkdir -p "${FUNC_DIR}"    
    declare -F | cut -d ' ' -f 3 | grep '^test_' | while read func; do
	touch "${FUNC_DIR}/${func}"
    done

    # should_pass and should_fail remove the file, if it exists
    run_all_tests

    # warn the user if the directory is non-empty
    if test -s "${FUNC_DIR}"; then
	echo "The following tests were not run: " >&2
	ls -t "${FUNC_DIR}"
    fi
}

declare -i tests=0
declare -i failures=0
rm -rf "${FUNC_DIR}"

case "$*" in
    "")     tattle;;
    *)      "$@"
esac
