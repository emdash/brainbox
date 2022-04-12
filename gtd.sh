set -eo pipefail

# TBD: Make this configurable
DATA_DIR="./gtdgraph"

# Database directories
NODE_DIR="${DATA_DIR}/state/nodes"
DEPS_DIR="${DATA_DIR}/state/dependencies"
CTXT_DIR="${DATA_DIR}/state/contexts"

# These directories represent distinct sets of edges, which express
# different relations between nodes. Hopefully the names are
# self-explanatory.
EDGE_DIRS=("${DEPS_DIR}" "${CTXT_DIR}")


# Helpers *********************************************************************


# Print error message and exit.
function error {
    echo "$1" >&2
    exit 1
}

# Subclass of error for umimplemented features.
function not_implemented {
    error "$1 is not implemented."
}

# Filter each word of stdin according to the exit status of "$@"
function filter_words {
    local first="t";
    while read input; do
	for word in $input; do
	    if "$@" "${word}"; then
		if test -z "${first}"; then
		    echo -n ' ';
		else
		    first=""
		fi
		echo -n "${word}"
	    fi
	done
    done
    echo
}

# Filter each line of stdin according to the exit status of "$@"
function filter_lines {
    while read input; do	
	if "$@" "${input}"; then
	    echo "${input}"
	fi
    done
}

# Apply "$@" to each word of stdin
function map_words {
    local first="t"
    while read input; do
	for word in $input; do
	    if test -z "${first}"; then
	       echo -n ' '
	    else
		first=''
	    fi
	    "$@" $word
	done
    done
    echo
}

# Apply "$@" to each line of stdin.
function map_lines {
    while read input; do
	"$@" "${input}"
    done
}


# Database Management *********************************************************


# Initialize a GTD database relative to the current working directory.
function database_init {
    if ! test -e "${DATA_DIR}"; then
	mkdir -p "${NODE_DIR}"
	for dir in "${EDGE_DIRS[@]}"; do
	    mkdir -p "${dir}"
	done
    else
	echo "Already initialized"
	return 1
    fi
}

# Check whether the data directory has been initialized.
function database_ensure_init {
    # check whether we are initialized.
    if ! test -e "${DATA_DIR}"; then
	error "Nodegraph is not initialized. Please run: $0 init"
    fi
}

# Clobber our GTD database; useful for tests.
function database_clobber {
    echo "This action cannot be undone. Really delete database (yes/no)?"
    read -e confirm
    case "${confirm}" in
	yes) rm -rf "${DATA_DIR}";;
	*)   echo "Not wiping database."; return 1;;
    esac
}


# Graph Database **************************************************************


# print the path to the contents directory of a given node id.
function graph_node_path {
    local id="$1"
    echo "${NODE_DIR}/$1"
}

# generate a fresh UUID for a new node
#
# XXX: this function is more or less untestable
function graph_node_gen_id {
    database_ensure_init

    # generate fresh uuid
    local id="$(uuid -m)"

    # If by some freak of coincidence we have a collision, keep trying
    # recursively.
    #
    # On a given system, the odds that this ever happens are
    # vanishingly small, and probably indicate some issue with the
    # random number generator. However, moving between systems, the
    # potential for collisions might increase?
    #
    # TBD: log if a collision occurs.
    # TBD: what is a reasonable collision threshold before we throw up
    #      our hands and ask the user to investigate?
    if test -e "$(graph_node_path "${id}")"; then
	graph_gen_id
    else
	echo "${id}"
    fi
}

# initialize a node or an edge id.
function graph_node_init {
    database_ensure_init
    mkdir -p "$(graph_node_path "$1")"
}

# print all graph nodes
function graph_node_list {
    database_ensure_init
    ls -t "${NODE_DIR}"
}

# initialize a new graph node, and print its id to stdout.
function graph_node_create {
    database_ensure_init
    local id="$(graph_node_gen_id)"
    mkdir -p "$(graph_node_path ${id})"
    echo "${id}"
}

# print the set of child nodes for the given node to stdout.
#
# if predicate is given, then edges will be filtered according to this
# command.
function graph_node_adjacent {
    database_ensure_init
    local node="$1"
    local edge_set="$2"
    local direction="$3"

    case "${edge_set}" in
	dep)     local edge_dir="${DEPS_DIR}";;
	context) local edge_dir="${CTXT_DIR}";;
	*)       error "${edge_set} is not one of dep | context"
    esac

    case "${direction}" in
	incoming) local self="graph_edge_v"; local linked="graph_edge_u";;
	outgoing) local self="graph_edge_u"; local linked="graph_edge_v";;
	*)        error "${direction} is not one of incoming | outgoing";;
    esac
    
    for edge in $(ls -t "${edge_dir}"); do
	if test "$("${self}" "${edge}")" = "${node}"; then
	    echo "$("${linked}" ${edge})"
	fi
    done
}

# Print the internal edge representation for nodes u and v to stdout.
function graph_edge {
    local u="$1"
    local v="$2"
    echo "${u}:${v}"
}

# For the given internal edge representation, print the source node
function graph_edge_u {
    echo "$1" | cut -d ':' -f 1
}

# For the given internal edge representatoin, print the target node
function graph_edge_v {
    echo "$1" | cut -d ':' -f 2
}

# Print the path to the edge connecting nodes u and v, if it exists.
function graph_edge_path {
    database_ensure_init
    local u="$1"
    local v="$2"
    local edge_set="$3"

    test -e "$(graph_node_path "${u}")" || error "invalid node id ${u}"
    test -e "$(graph_node_path "${v}")" || error "invalid node id ${v}"

    case "${edge_set}" in
	dep)     echo  "${DEPS_DIR}/$(graph_edge "${u}" "${v}")";;
	context) echo  "${CTXT_DIR}/$(graph_edge "${u}" "${v}")";;
	*)       error "$3 not one of dep | context";;
    esac
}

# Link two nodes in the graph.
function graph_edge_create {
    database_ensure_init
    mkdir -p "$(graph_edge_path "$1" "$2" "$3")"
}

# Break the link between two nodes.
#
# also remove any related edge properties.
function graph_edge_delete {
    database_ensure_init
    rm -rf "$(graph_edge_path "$1" "$2" "$3")"
}

# traverse the graph depth first, starting from `root`, with cycle checking.
#
# this is a text-book algorithm, implemented in bash. we parameterize
# on the same arguments as graph_adjacent.
#
# if a cycle is detected, the algorithm terminates early with nonzero
# status.
function graph_traverse {
    database_ensure_init

    local root="$1"
    local edge_set="$2"
    local direction="$3"
    local -A nodes_on_stack
    local -A seen

    # would be a closure if bash scope was lexical.
    __graph_traverse_rec "${root}"
}

function __graph_traverse_rec {
    local cur="$1"

    if test -v nodes_on_stack["${cur}"]; then
	error "Graph contains a cycle"
	return 1
    fi

    # add this node to the cycle checking set
    nodes_on_stack["${cur}"]=""

    if test ! -v seen["${cur}"]; then
	echo "${cur}"
	seen["${cur}"]="1"

	for a in $(graph_node_adjacent "${cur}" "${edge_set}" "${direction}"); do
	    __graph_traverse_rec "${a}" || return 1
	done
    fi

    # remove node from cycle checking set
    unset nodes_on_stack["${cur}"]
}


# Tasks ***********************************************************************


# The graph datastructure is generic. The logic in below here is
# increasingly GTD-specific.
 

# print the path to the the given datum of the given task.
function task_datum_path {
    echo "$(graph_node_path $1)/$2"
}

# get the datum for the given task.
#
# prints nothing, and returns nonzero if datum file does not exist.
function task_datum {
    database_ensure_init
    local id="$1"
    local datum="$2"
    local path="$(task_datum_path "${id}" "${datum}")"
    if test -e "${path}"; then
	cat "${path}"
    else
	return 1
    fi
}

# print the contents of the given node id on stdout
function task_contents {
    task_datum "$1" contents || echo "[no contents]"
}

# get the first line of the node's contents
function task_gloss {
    task_contents "$1" | head -n 1
}

# get the state of the given task
function task_state {
    task_datum "$1" state | cut -d ' ' -f 1
}

# returns true if the given task can be considered active
function task_is_active {
    case "$(task_state "$1")" in
	NEW)  return 0;;
	TODO) return 0;;
	WAIT) return 0;;
	*)    return 1;;
    esac
}

# returns true if the given task can be executed
function task_is_actionable {
    case "$(task_state "$1")" in
	WAIT) return 1;;
	*)    task_is_active "$1";;
    esac
}

# summarize the current task.
function task_summary {
    echo "$1" "$(task_state "$1")" "$(task_gloss "$1")"
}

# returns true if a task is a next action
function task_is_next_action {
    # basically we check whether the task has any outgoing edges. if
    # not, then by definition it is a next action.
    task_is_actionable "$1" && test -z "$(graph_node_adjacent "$1" dep outgoing)"
}

# returns true if a task is the root of a project subgraph
function task_is_project_root {
    # basically check whether the task has any incoming edges.
    test -z "$(graph_node_adjacent "$1" dep incoming)"
}

# returns true if a task is not assigned to any context
function task_is_unassigned {
    test -z "$(graph_adjacent "$1" context incoming)"
}

# returns true if a task is orphaned: i.e. has no incoming or outgoing
# dependencies
function task_is_orphan {
    task_is_next_action && task_is_root_project
}


# Output formatters ***********************************************************


# summarize each taskid written to stdin.
function summarize {
    map_lines task_summary
}


# Finding and selecting nodes *************************************************


# Prompt the user to select a node from the set passed on stdin.
#
# uses fzf for the match, all arguments are forwared to fzf.
function select_node {
    summarize | fzf "$@" | cut -d ' ' -f 1
}

# Prompt the user to select a node if no nodeid is given.
function select_if_null {
    if test -z "$1"; then
	select_node
    else
	echo "$1"
    fi
}


# Queries *********************************************************************


# List all projects
function all {
    graph_node_list
}

# List all subtasks for the given node
function subtasks {
    graph_traverse "$(all | select_if_null $1)" dep outgoing
}

# List all tasks assigned to a context
function assigned {
    graph_traverse "$(all | select_if_null $1)" context incoming
}


# Filters *********************************************************************


# Keep only active tasks.
function active {
    filter_lines task_is_active
}

# Keep only actionable tasks.
function actionable {
    filter_lines task_is_active
}

# Keep only next actions
function next {
    filter_lines task_is_next_action
}

# Operations ******************************************************************


# Initialize the databaes
function init {
    database_init
}

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
function capture {
    local node="$(graph_node_create)"
    local contents="$(task_datum_path "${node}" contents)"

    echo "NEW" > "$(task_datum_path "${node}" state)"

    if test -z "$*"; then
	if tty > /dev/null; then
	    # TBD: set temporary file contents
	    "${EDITOR}" "${contents}"
	else
	    cat > "${contents}"
	fi
    else
	echo "$*" > "${contents}"
    fi
}

# Add a dependency to an existing task
#
# $1: the parent task
# $2: the 
function depends {
    graph_edge_create "$(active | search "$1")" "$(require "$2")" dep
}

# Like above, but links a ta
function assign {
    local task="$1"
    local context="$2"
    graph_edge_create "$(active | search "${task}")" "$(require "${context}")" context
}


# Main entry point ************************************************************


"$@"
