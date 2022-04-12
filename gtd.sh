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

# print the path to the contents file the given node id on stdout
function graph_node_contents_path {
    echo "$(graph_node_path $1)/contents"
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
    # Ona given system, the odds that this ever happens are
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

# print the contents of the given node id on stdout
function graph_node_contents {
    database_ensure_init
    local id="$1"
    local path="$(graph_node_contents_path "${id}")"
    if test -e "${path}"; then
	cat "${path}"
    else
	echo "[no contents]"
    fi
}

# get the first line of the node's contents
function graph_node_gloss {
    graph_node_contents "$1" | head -n 1
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

# traverse the graph depth first, starting from `root`
#
# this is a text-book algorithm, implemented in bash.
#
# we parameterize on the same arguments as graph_adjacent
function graph_traverse {
    database_ensure_init
    local root="$1"
    local edge_set="$2"
    local direction="$3"

    # our stack for DFS traversal
    local -a stack=("${root}")

    # the set of nodes we have already visited
    local -A seen

    # TBD: is there a more efficient way of testing for an empty array?
    while test -n "${stack}"; do
	local cur="${stack[-1]}"
	unset stack[-1]
	if ! test -v seen["${cur}"]; then
	    seen["${cur}"]="1"
	    stack+=( $(graph_node_adjacent "${cur}" "${edge_set}" "${direction}") )
	    echo "${cur}"
	fi
    done
}


# Tasks ***********************************************************************

function task_summary {
    echo "$1" "$(graph_node_gloss $1)"
}

# print the set of projects of which the given task is
function task_get_ancestors {
    graph_traverse "$1" dep incoming
}

# print the outgoing dependencies for the given node
function task_get_dependencies {
    graph_traverse "$1" dep outgoing
}

# print the contexts to which the given node is directly assigned
function task_get_contexts {
    graph_node_adjacent "$1" context outgoing
}

# returns true if a task is a next action
function task_is_next_action {
    # basically we check whether the task has any outgoing edges. if
    # not, then by definition it is a next action.
    test -z "$(graph_node_adjacent "$1" dep outgoing)"
}

# returns true if a task is the root of a project subgraph
function task_is_project_root {
    # basically check whether the task has any incoming edges.
    test -z "$(graph_adjacent "$1" dep incoming)"
}

# returns true if a task is not assigned ot any context
function task_is_unassigned {
    test -z "$(graph_adjacent "$1" context incoming)"
}

# returns true if a task is orphaned: i.e. has no incoming or outgoing
# dependencies
function task_is_orphan {
    task_is_next_action && task_is_root_project
}

# assign the given task to a given context
function task_add_to_context {
    local node="$1"
    local context="$2"
    graph_edge_create "${context}" "${task}" context
}

# take the given task out of the given context
function task_remove_from_context {
    local node="$1"
    local context="$2"
    graph_edge_delete "${context}" "${task}" context
}


# Contexts *******************************************************************


# print the set of tasks which are directly or indirectly assigned to
# the given context.
function context_get_assignees {
    graph_traverse "$1" context incoming
}

# print the set of tasks which are directly assigned to the given context.
function context_get_direct_assignees {
    graph_adjacent "$1" context incoming
}


# Commands ********************************************************************


# Initialize the databaes
function init {
    database_init
}


# Show only the next actions in the graph.
function next {
    graph_node_list | filter_lines task_is_next_action | map_lines task_summary
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
    local contents="$(graph_node_contents_path "${node}")"

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

# Find or create a task by its gloss
function find {
    if test -z "$2"; then
	local input
	echo "Searching for: $1"
	read -e input
    else
	local input="$2"
    fi

    if graph_node_exists "${input}"; then
	echo "${input}"
    else
	capture "${input}"
    fi
}

# Add a dependency to an existing task
#
# u and v must exist.
function depends {
    local u="$(find u $1)"
    local v="$(find v $2)"
    graph_task_add_dependency "${u}" "${v}"
}

# List all nodes with their gloss
function all {
    graph_node_list | map_lines task_summary
}


# Main entry point ************************************************************


"$@"
