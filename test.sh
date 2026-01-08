#/usr/bin/env bash

set -o pipefail
set -o errexit


GTD="../gtd.sh"
TEST_DIR="./test-run"
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

function debug {
    echo "$*" >&2
}

# print message to stderr and exit.
function error {
    line="$(caller 0 | cut -d ' ' -f 1)"
    file="$(basename $(caller 0 | cut -d ' ' -f 3))"
    debug "${file}:${line} $*"
    exit 1
}


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
	debug "${file}:${line} Assertion failed: $*"
	debug
	exit 1
    fi
}

function assert_false {
    if "$@"; then
	local line func file
	line="$(caller 0 | cut -d ' ' -f 1)"
	file="$(basename $(caller 0 | cut -d ' ' -f 3))"
	debug "${file}:${line} '$*' should be false"
	debug
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
	debug "${file}:${line} '$*' should be true"
	debug
	exit 1
    fi
}

function gtd   { "${GTD}" "$@" ; }

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
    local data=$'yes\nno\nyes\nyes\nno'
    local expected=$'yes\nyes\nyes'
    assert "$(echo "${data}" | gtd filter ../test.sh isYes)" = "${expected}"
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

function test_adjacent {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies
    make_test_edge "${t3}" "${t4}" dependencies

    # test outgoing edges for t1
    local -a actual
    readarray -t actual < <(
        echo "${t1}" \
            | gtd stdin adjacent dependencies outgoing \
            | gtd map task_gloss \
            | sort
    )
    assert_true test "${actual[*]}" = "t1 t2 t3"

    # test outgoing edges for t2
    readarray -t actual < <(
        echo "${t2}" \
            | gtd stdin adjacent dependencies outgoing \
            | gtd map task_gloss
    )
    assert_true test "${actual[*]}" = "t2 t4"

    # test outgoing edges for t3
    readarray -t actual < <(
        echo "${t3}" \
            | gtd stdin adjacent dependencies outgoing \
            | gtd map task_gloss
    )
    assert_true test "${actual[*]}" = "t3 t4"

    # test outgoing edges for t4
    readarray -t actual < <(
        echo "${t4}" \
            | gtd stdin adjacent dependencies outgoing \
            | gtd map task_gloss
    )
    assert_true test "${actual[*]}" = "t4"

    # test incoming edges for t4
    readarray -t actual < <(
        echo "${t4}" \
            | gtd stdin adjacent dependencies incoming \
            | gtd map task_gloss \
            | sort
    )
    assert_true test "${actual[*]}" = "t2 t3 t4"
}

function test_graph_edge {
    local u="fake-uuid-1"
    local v="fake-uuid-2"
    local edge="fake-uuid-1:fake-uuid-2"
    assert "$(gtd graph_edge   "${u}" "${v}")" = "fake-uuid-1:fake-uuid-2"
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

    assert "$(gtd graph_edge_path "${u}" "${v}" dependencies)"  = "${dep}"
    assert "$(gtd graph_edge_path "${u}" "${v}" contexts)"      = "${ctx}"
}

function test_graph_edge_create {
    local u="fake-uuid-1"
    local v="fake-uuid-2"
    local w="fake-uuid-3"

    mkdir -p "./gtdgraph/state/nodes/${u}"
    mkdir -p "./gtdgraph/state/nodes/${v}"
    mkdir -p "./gtdgraph/state/contexts"
    mkdir -p "./gtdgraph/state/dependencies"

    gtd graph_edge_create "${u}" "${v}" dependencies || error "should succeed"
    gtd graph_edge_create "${u}" "${w}" dep          &> /dev/null && error "should fail"
    gtd graph_edge_create "${u}" "${v}" contexts     || error "should succeed"
    gtd graph_edge_create "${w}" "${v}" contexts     &> /dev/null && error "should fail"
    gtd graph_edge_create "${u}" "${v}" derp         &> /dev/null && error "should fail"

    test -d "./gtdgraph/state/dependencies/fake-uuid-1:fake-uuid-2"
}

function test_graph_edge_delete {
    local u="fake-uuid-1"
    local v="fake-uuid-2"

    mkdir -p "./gtdgraph/state/nodes/${u}"
    mkdir -p "./gtdgraph/state/nodes/${v}"
    mkdir -p "./gtdgraph/state/dependencies/${u}:${v}"

    assert -d "./gtdgraph/state/dependencies/${u}:${v}"

    gtd graph_edge_delete "${u}" "${v}" dependencies || error "should succeed"

    assert ! -d "./gtdgraph/state/dependencies/${u}:${v}"
}

function test_graph_traverse {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies
    make_test_edge "${t3}" "${t4}" dependencies
    make_test_edge "${t5}" "${t4}" dependencies

    # XXX: output order is currently unstable, complicating testing
    # for now we will sort the output results, because we're really
    # interested in just the set of nodes, rather than the ordering.
    #
    # but this will likely change soon.
    local -a actual
    readarray -t actual < <(
      echo "${t1}" \
        | gtd graph reachable dependencies outgoing \
        | gtd map task_gloss \
        | sort
    )
    assert "${actual[*]}" = "t1 t2 t3 t4"

    readarray -t actual < <(
        echo "${t4}" \
          | gtd graph reachable dependencies incoming \
          | gtd map task_gloss \
          | sort
    )
    assert "${actual[*]}" = "t1 t2 t3 t4 t5"
}

function test_graph_traverse_with_cycle {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies
    make_test_edge "${t4}" "${t1}" dependencies

    # will fail
    gtd graph_traverse "${t1}" dependencies outgoing &> /dev/null
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

    echo "DONE" | gtd task_state write fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "DONE"
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

function test_is_root {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies

    # t1 should be the only root
    declare -a results
    readarray -t results < <(gtd is_root)
    assert_true test "${results[*]}" = "${t1}"
}

function test_is_leaf {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies

    # t3 and t4 are leaves in this graph
    declare -a results
    readarray -t results < <(
      gtd is_leaf \
        | gtd map task_gloss \
        | sort
    )
    assert_true test "${results[*]}" = "t3 t4"
}

function test_is_orphan {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies

    declare -a results
    readarray -t results < <(
      gtd is_orphan \
        | gtd map task_gloss \
        | sort
    )
    assert_true test "${results[*]}" = "t5"
}

function test_is_new {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    echo "NEW" | gtd task_state write fake-uuid
    assert_true test "$(gtd is_new)" = "fake-uuid"

    for state in TODO DONE WAITING SOMEDAY
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test -z "$(gtd is_new)"
    done
}

function test_is_active {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    for state in NEW TODO WAITING PERSIST CONTEXT SOMEDAY
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test "$(gtd is_active)" = fake-uuid
    done

    for state in DONE DROPPED
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test -z "$(gtd is_active)"
    done
}

function test_is_actionable {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    for state in NEW TODO
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test "$(gtd is_actionable)" = fake-uuid
    done

    for state in DONE WAITING DROPPED
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test -z "$(gtd is_actionable)"
    done
}

function test_is_next {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    # orphan nodes are also next actions
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t3}" "${t4}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies

    echo "TODO" | gtd task_state write "${t1}"
    echo "TODO" | gtd task_state write "${t2}"
    echo "TODO" | gtd task_state write "${t3}"
    echo "TODO" | gtd task_state write "${t4}"
    echo "TODO" | gtd task_state write "${t5}"

    declare -a results
    readarray -t results < <(
      gtd is_next \
        | gtd map task_gloss \
        | sort
    )
    assert_true test "${results[*]}" = "t4 t5"
}

function test_is_unassigned {
    gtd init

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    make_test_edge "${t1}" "${t2}" dependencies
    make_test_edge "${t1}" "${t3}" dependencies
    make_test_edge "${t3}" "${t4}" dependencies
    make_test_edge "${t2}" "${t4}" dependencies

    echo "TODO" | gtd task_state write "${t1}"
    echo "TODO" | gtd task_state write "${t2}"
    echo "TODO" | gtd task_state write "${t3}"
    echo "TODO" | gtd task_state write "${t4}"
    echo "TODO" | gtd task_state write "${t5}"

    local -a results
    readarray -t results < <(
        gtd is_unassigned \
            | gtd map task_gloss \
            | sort
    )
    assert_true test "${results[*]}" = "t1 t2 t3 t4 t5"

    make_test_edge "${t5}" "${t4}" contexts
    local -a results
    readarray -t results < <(
        gtd is_unassigned \
            | gtd map task_gloss \
            | sort
    )
    assert_true test "${results[*]}" = "t1 t2 t3 t5"

    make_test_edge "${t5}" "${t1}" contexts
    make_test_edge "${t5}" "${t4}" contexts
    local -a results
    readarray -t results < <(
        gtd is_unassigned \
            | gtd map task_gloss \
            | sort
    )
    assert_true test "${results[*]}"  = "t2 t3 t5"
}

function test_is_waiting {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null

    local -a results
    for state in NEW TODO DONE SOMEDAY
    do
        echo "${state}" | gtd task_state write fake-uuid
        assert_true test "$(gtd is_waiting)" = ""
    done

    echo "WAITING" | gtd task_state write fake-uuid
    assert_true test "$(gtd is_waiting)" = "fake-uuid"
}

function test_task_summary {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid

    echo "foo bar baz" | gtd task_contents write fake-uuid
    assert_true test "$(gtd task_summary fake-uuid)" = "fake-uuid     NEW foo bar baz"
}

function test_task_auto_triage {
    gtd init

    # should auto-transition from NEW to TODO
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid

    assert_true test "$(gtd task_state read fake-uuid)" = "NEW"
    gtd task_auto_triage fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "TODO"

    # should not change state
    echo "DONE" | gtd task_state write fake-uuid
    gtd task_auto_triage fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "DONE"
}

function test_task_activate {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "DROPPED" | gtd task_state write fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "DROPPED"
    gtd task_activate fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "TODO"
}

function test_task_drop {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "NEW"
    gtd task_drop fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "DROPPED"
}

function test_task_complete {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "NEW"
    gtd task_complete fake-uuid
    assert "$(gtd task_state read fake-uuid)" = "DONE"
}

function test_task_defer {
    gtd init
    gtd graph_node_create fake-uuid > /dev/null
    echo "NEW" | gtd task_state write fake-uuid
    assert_true test "$(gtd task_state read fake-uuid)" = "NEW"
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

    should_pass test_graph_edge
    should_pass test_graph_edge_path
    should_pass test_graph_edge_create
    should_pass test_graph_edge_delete

    should_pass test_graph_datum
    should_pass test_graph_traverse
    should_fail test_graph_traverse_with_cycle

    should_pass test_task_contents
    should_pass test_task_state
    should_pass test_task_gloss
    should_pass test_is_new
    should_pass test_is_next
    should_pass test_adjacent
    should_pass test_is_unassigned
    should_pass test_is_root
    should_pass test_is_leaf
    should_pass test_is_orphan
    should_pass test_is_active
    should_pass test_is_actionable
    should_pass test_task_auto_triage
    should_pass test_is_waiting
    should_pass test_task_summary
    should_pass test_task_drop
    should_pass test_task_activate
    should_pass test_task_complete
    should_pass test_task_defer

    components/test.py

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
