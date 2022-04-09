set -eo pipefail


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

function run_test {
    local test_name="$1"

    setup
    
    if "$@"; then
	echo "${test_name}... ok"
    else
	echo "${test_name}... failed"
    fi

    tear_down
}

function error {
    echo "$*" >&2
    return 1
}

function assert {
    (test "$@") || error "Assertion failed: $*"
}

function gtd {
    "${GTD}" "$@"
}

function make_test_node {
    local name="$1"
    local id="$(gtd graph_node_create)" || error "couldn't create ${name}"
    echo "${name}" > "$(gtd graph_node_contents_path "${id}")"
    echo "${id}"
    sleep 0.01
}


# Test cases ******************************************************************


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

function test_graph_node_contents_path {
    local id="fake-uuid"
    local dir="./gtdgraph/state/nodes/fake-uuid/contents"
    assert "$(gtd graph_node_contents_path "${id}")" = "${dir}"
}

function test_graph_node_gen_id {
    gtd database_init
    local id1="$(gtd graph_node_gen_id)" || error "Should have generated an id"
    local id2="$(gtd graph_node_gen_id)" || error "Should have generated an id"
    test "${id1}" != "${id2}"            || error "Ids should be different"
}

function test_graph_node_init {
    local id="fake-uuid"
    local dir="gtdgraph/state/nodes/${id}"
    gtd database_init
    gtd graph_node_init fake-uuid || error "Node init failed."
    assert -e "$(gtd graph_node_path ${id})"
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

function test_graph_node_contents {
    mkdir -p "gtdgraph/state/nodes/fake-uuid-1"
    mkdir -p "gtdgraph/state/nodes/fake-uuid-2"
    echo "lulululu" > "gtdgraph/state/nodes/fake-uuid-1/contents"
    assert "$(gtd graph_node_contents fake-uuid-1)" = "lulululu"
    assert "$(gtd graph_node_contents fake-uuid-2)" = "[no contents]"
}

function test_graph_node_gloss {
    local path="./gtdgraph/state/nodes/fake-uuid"

    # create a node with multi-line contents file
    mkdir -p "${path}"
    echo "foo" >> "${path}/contents"
    echo "bar" >> "${path}/contents"

    # check that gloss is only the first line
    assert "$(gtd graph_node_gloss fake-uuid)" = "foo"
}

function test_graph_node_create {
    gtd database_init
    local id="$(gtd graph_node_create)"      || error "Should have created a node."
    test -e "$(gtd graph_node_path "${id}")" || error "Path to the node should exist."    
}

function test_graph_node_adjacent {
    gtd database_init || error "couldn't initialize test db"

    local t1="$(make_test_node t1)"
    local t2="$(make_test_node t2)"
    local t3="$(make_test_node t3)"
    local t4="$(make_test_node t4)"
    local t5="$(make_test_node t5)"

    gtd graph_edge_create "${t1}" "${t2}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t1}" "${t3}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t2}" "${t4}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t3}" "${t4}" dep || error "couldn't create edge"

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

    gtd graph_edge_create "${t1}" "${t2}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t1}" "${t3}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t2}" "${t4}" dep || error "couldn't create edge"
    gtd graph_edge_create "${t3}" "${t4}" dep || error "couldn't create edge"
}


# Entry Point *****************************************************************


function run_all_tests { 
    run_test test_database_ensure_init
    run_test test_database_init
    run_test test_database_clobber

    run_test test_graph_node_path
    run_test test_graph_node_contents_path
    run_test test_graph_node_gen_id
    run_test test_graph_node_init
    run_test test_graph_node_list
    run_test test_graph_node_contents
    run_test test_graph_node_gloss
    run_test test_graph_node_create
    run_test test_graph_node_adjacent

    run_test test_graph_edge
    run_test test_graph_edge_path
    run_test test_graph_edge_create
    run_test test_graph_edge_delete
}

case "$*" in
    test_*) run_test "$@";;
    *)      run_all_tests;;
esac
