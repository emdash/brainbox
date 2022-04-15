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


# print the path to the data directory of a given node id.
#
# graph nodes are just directories, and may contain arbitrary user
# data.
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

# inspect or modify graph node data
#
# graph nodes are just directories
#
# valid operations are:
# - path:   prints the path to the dataum file
# - read:   print the datum file contents to stdout
# - write:  overwrite the datum file path with stdin
# - value:  print the last line of the datum file
# - append: append remaining arguments to datum file.
# - mkdir:  create datum as a directory
# - cd:     move into datum directory (uses pushd).
# - cp:     copy remaining arguments to datum directory
# - mv:     move remaining arguments to datum directory.
function graph_datum {
    database_ensure_init

    local datum="$1"
    local command="$2"
    local id="$3"
    shift 3

    local path="$(graph_node_path ${id})/${datum}"

    case "${command}" in
	exists) test -e        "${path}";;
	path)   echo           "${path}";;
	read)   __datum_read            ;;
	write)  cat >          "${path}";;
	append) cat >>         "${path}";;
	edit)   "${EDITOR}"    "${path}";;
	mkdir)  mkdir -p       "${path}";;
	cp)     cp "$@"        "${path}";;
	mv)     mv "$@"        "${path}";;

	*) error "invalid subcommand: ${command}";;
    esac
}

function __datum_read {
    test -f "${path}" && cat "${path}"
}


# print all graph nodes
function graph_node_list {
    database_ensure_init
    ls -t "${NODE_DIR}"
}

# initialize a new graph node, and print its id to stdout.
#
# if id is given, this ID is used. otherwise a fresh ID is generated.
function graph_node_create {
    database_ensure_init

    if test -z "$1"; then
	local id="$(graph_node_gen_id)"
    else
	local id="$1"
    fi

    local path="$(graph_node_path "${id}")"

    if test -e "${path}"; then
	error "A node with ${id} already exists."
    else
    	mkdir -p "$(graph_node_path ${id})"
	echo "${id}"
    fi
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

# Print all graph edges to stdout
function graph_edge_list {
    case "$1" in
	dep)     local -a dirs=("${DEPS_DIR}");;
	context) local -a dirs=("${CTXT_DIR}");;
	all)     local -a dirs=("${DEPS_DIR}" "${CTXT_DIR}");;

	*) error "$1 not one of dep | context | all"
    esac
    ls -t "${dirs[@]}"
}

# Return true if the given edge touches the given set of nodes
function graph_edge_touches {
    declare -A nodes
    for node in "$@"; do
	nodes["${node}"]=""
    done

    while read edge; do
	if test -v nodes["$(graph_edge_u "$1")"] || test -v nodes["$(graph_edge_v "$1")"]
	then
	    echo "${edge}"
	fi
    done
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

# similar to above, but performing a "tree expansion"
#
# the difference is that shared nodes will be duplicated in the output.
#
# if --depth is given, then the second field will be an integer
# representing the tree depth of the given node.
#
# this is a text-book algorithm, implemented in bash. we parameterize
# on the same arguments as graph_adjacent.
#
# if a cycle is detected, the algorithm terminates early with nonzero
# status.
function graph_expand {
    database_ensure_init

    case "$1" in
	-d|--depth) shift; local print_depth="";;
    esac

    local root="$1"
    local edge_set="$2"
    local direction="$3"
    local -A nodes_on_stack

    # would be a closure if bash scope was lexical.
    __graph_expand_rec "${root}" 0
}

function __graph_expand_rec {
    local cur="$1"
    local depth="$2"

    if test -v nodes_on_stack["${cur}"]; then
	error "Graph contains a cycle"
	return 1
    fi

    # add this node to the cycle checking set
    nodes_on_stack["${cur}"]=""

    if test -v print_depth; then
	echo "${cur}" "${depth}"
    else
	echo "${cur}"
    fi

    for a in $(graph_node_adjacent "${cur}" "${edge_set}" "${direction}"); do
	__graph_expand_rec "${a}" "$((depth + 1))" || return 1
    done

    # remove node from cycle checking set
    unset nodes_on_stack["${cur}"]
}


# Tasks ***********************************************************************


# In GTD, A task is anything that needs to be done.
#
# Some aspects of task state are tracked explicitly, while others are
# inferred from graph edges.
#
# this section defines functions for working at the task level.
#
# a task is implemented as a node using the generic graph logic
# defined in the previous section.

## task state helper functions ************************************************

# return true if the given task state is a valid one.
function task_state_is_valid {
    case "$1" in
	NEW)      return 0;;
	TODO)     return 0;;
	COMPLETE) return 0;;
	DROPPED)  return 0;;
	WAITING)  return 0;;
	SOMEDAY)  return 0;;
	*)        return 1;;
    esac
}

# returns true if the given task state can be considered active
function task_state_is_active {
    case "$1" in
	NEW)     return 0;;
	TODO)    return 0;;
	WAITING) return 0;;
	*)       return 1;;
    esac
}

# returns true if the given task state can be acted on
function task_state_is_actionable {
    case "$1" in
	WAITING) return 1;;
	*)    task_state_is_active "$1";;
    esac
}

## define task data ***********************************************************

function task_contents { graph_datum contents "$@"; }
function task_state    { graph_datum state "$@"; }

## read-only task properties **************************************************

# get the first line of the node's contents
function task_gloss {
    # tbd: truncate length to "$2"
    task_contents read "$1" | head -n 1 || echo "[no contents]"
}

# returns true if a task is the root of a project subgraph
function task_is_root {
    test -z "$(graph_node_adjacent "$1" dep incoming)"
}

# returns true if a task is a leaf node
function task_is_leaf {
    test -z "$(graph_node_adjacent "$1" dep outgoing)"
}

# returns true if a task is orphaned: is a root with no dependencies
function task_is_orphan {
    task_is_root "$1" && task_is_root "$1"
}

# returns true if task has state NEW
function task_is_new {
    test "$(task_state read "$1")" = "NEW"
}

# return true if the given task is active
function task_is_active {
    task_state_is_active "$(task_state read $1)"
}

# return true if the given task is actionable
function task_is_actionable {
    task_state_is_actionable "$(task_state read $1)"
}

# returns true if the given task is a "next action"
function task_is_next_action {
    # basically we check whether the task has any outgoing edges. if
    # not, then by definition it is a next action.
    task_is_actionable "$1" && task_is_leaf "$1"
}

# returns true if a task is not assigned to any context
function task_is_unassigned {
    test -z "$(graph_adjacent "$1" context incoming)"
}

# returns true if a task is marked as waiting
function task_is_waiting {
    test "$(task_state read "$1")" = "WAITING"
}

# summarize the current task: id, status, and gloss
function task_summary {
    echo "$1" "$(task_state read "$1")" "$(task_gloss "$1")"
}

# Add a dependency to an existing task
#
# $1: the existing task
# $2: the dependency
function task_add_subtask {
    graph_edge_create "$1" "$2" dep
}

# Add a dependency to an existing task
#
# $1: the existing task
# $2: the parent task to add
function task_add_supertask {
    graph_edge_create "$2" "$1" dep
}

# Assign task to the given context
#
# $1: the existing task
# $2: the context
function task_assign {
    graph_edge_create "$2" "$1" context
}

# mark the given task as TODO
function task_activate {
    echo "TODO" | task_state write "$1"
}

# mark the given task as dropped
function task_drop {
    echo "DROPPED" | task_state write "$1"
}

# mark the given task as completed
function task_complete {
    echo "COMPLETED" | task_state write "$1"
}

# mark the given task as someday
function task_defer {
    echo "SOMEDAY" | task_state write "$1"
}


# An Embedded DSL for Queries *************************************************


# returns true if "$@" is recognized as a valid filter keyword
function graph_filter_is_valid {
    case "$1" in
	new)               return 0;;
	active)            return 0;;
	actionable)        return 0;;
	next)              return 0;;
	waiting)           return 0;;
	roots)             return 0;;
	orphans)           return 0;;
	select_one)        return 0;;
	select_multiple)   return 0;;
	summarize)         return 0;;
	activate)          return 0;;
	drop)              return 0;;
	complete)          return 0;;
	defer)             return 0;;
	make_subtask_of)   return 0;;
	make_supertask_of) return 0;;
	dot)               return 0;;
	*)                 return 1;;
    esac
}

# returns true if "$@" is recognized as a valid filter keyword
function tree_filter_is_valid {
    case "$1" in
	indent) return 0;;
	*)      return 1;;
    esac
}

# allow further chaining of graph query filters.
#
# if args are given, and a valid filter, then fold the given command
# into the pipeline.
#
# if no args are given, forward stdin to stdout
function graph_filter_chain {
    if test -n "$*"; then
	if graph_filter_is_valid "$1"; then
	    "$@"
	else
	    error "$1 is not a valid graph query filter"
	fi
    else
	cat
    fi
}

# allow further chaining of tree query filters.
#
# if args are given, and a valid filter, then fold the given command
# into the pipeline.
#
# if no args are given, forward stdin to stdout
function tree_filter_chain {
    if test -n "$*"; then
	if tree_filter_is_valid "$1"; then
	    "$@"
	else
	    error "$1 is not a valid tree query filter"
	fi
    else
	cat
    fi
}

# forbid further chaining of filters
function end_filter_chain {
    if test -n "$*"; then
	error "${name} does not allow further filtering"
    fi
}

# disables destructive operations in preview mode
function destructive_operation {
    if test -v GTD_NONDESTRUCTIVE_MODE; then
	error "Disabled in nondestructive mode"
    fi
}

## Query Producers ************************************************************

# These appear at the start of a filter chain, but are not themselves filters.

# all tasks
function all {
    graph_node_list | graph_filter_chain "$@"
}

# all subtasks of the given node
function subtasks {
    local id="$1"; shift
    graph_traverse "${id}" dep outgoing | graph_filter_chain "$@"
}

# all tasks assigned to a context
function assigned {
    local id="$1"; shift
    graph_traverse "${id}" context incoming | graph_filter_chain "$@"
}

# tree expansion of project rooted at the given node
function project_tree {
    local root="$1"
    shift
    graph_expand --depth "${root}" dep outgoing | tree_filter_chain "$@"
}

# like project_tree, but going upwards
function owner_tree {
    local root="$1"
    shift
    graph_expand --depth "${root}" dep incoming  | tree_filter_chain "$@"
}

## Query Filters **************************************************************

# keep only new tasks
function new {
    filter_lines task_is_new | graph_filter_chain "$@"
}

# Keep only active tasks.
function active {
    filter_lines task_is_active | graph_filter_chain "$@"
}

# Keep only actionable tasks.
function actionable {
    filter_lines task_is_actionable | graph_filter_chain "$@"
}

# Keep only next actions
function next {
    filter_lines task_is_next_action | graph_filter_chain "$@"
}

# Keep only waiting tasks
function waiting {
    filter_lines task_is_waiting | graph_filter_chain "$@"
}

# Keep only tasks which are the root of a subgraph
function roots {
    filter_lines task_is_root | graph_filter_chain "$@"
}

# Keep only tasks which are not connected to any other tasks
function orphans {
    filter_lines task_is_orphan | graph_filter_chain "$@"
}

# keep only the node selected by the user
function select_one {
    summarize | fzf | cut -d ' ' -f 1 | graph_filter_chain "$@"
}

# keep only the nodes selected by the user
function select_multiple {
    summarize | fzf -m | cut -d ' ' -f 1 | graph_filter_chain "$@"
}

## Query Consumers ************************************************************

# Print a one-line summary for each task id
function summarize {
    end_filter_chain "$@"
    map_lines task_summary
}

# Reactivate each task id
function activate {
    end_filter_chain "$@"
    map_lines task_activate
}

# Drop each task id
function drop {
    destructive_operation
    end_filter_chain "$@"
    map_lines task_drop
}

# Complete each task id
function complete {
    destructive_operation
    end_filter_chain "$@"
    map_lines task_complete
}

# Defer each task id
function defer {
    destructive_operation
    end_filter_chain "$@"
    map_lines task_defer
}

# Make each task id a supertask of the given subtask.
#
# The *subtask* to add is given by $1.
# All *parent* tasks are read
function make_supertask_of {
    destructive_operation
    local subtask="$1"; shift
    end_filter_chain "$@"
    map_lines task_add_supertask "${subtask}"
}

# Make each task id a subtask of the given id supertask.
function make_subtask_of {
    destructive_operation
    local supertask="$1"; shift
    end_filter_chain "$@"
    map_lines task_add_subtask "${supertask}"
}

# dotfile export for graphviz
function dot {
    case "$1" in
	dep|context) local edge_set="$1"; shift;;
	*) error "$1 not one of dep | context";;
    esac

    end_filter_chain "$@"

    declare -A nodes
    declare -A edges

    echo "digraph {"

    # output an entry for each node
    while read id; do
	printf "\"${id}\" [label=\"%q\"];\n" "$(task_gloss "${id}")"
	nodes["$id"]=""
    done

    graph_edge_list "${edge_set}" | graph_edge_touches "${!nodes[@]}" | while read edge; do
	echo "\"$(graph_edge_u "${edge}")\" -> \"$(graph_edge_v "${edge}")\";"
    done

    echo "}"
}

# indent tree expansion
#
# you can customize the characters used for indentation.
function indent {
    if test -n "$2"; then
	local marker="$2"
	shift
    else
	local marker=' '
    fi

    end_filter_chain "$@"

    while read id depth; do
	# indent the line.
	for i in $(seq $(("${depth}" + 1))); do
	    echo -n "${marker}"
	done
	
	test ! "${marker}" = ' ' && echo -n ' '
	
	printf "%-8s %s\n" "$(task_state read "${id}")" "$(task_gloss "${id}")"
    done
}


# GTD Commands DSL ************************************************************


# Initialize the database
function init { database_init; }

# Clobber the database
function clobber { database_clobber; }

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
function capture {
    local node="$(graph_node_create)"

    echo "NEW" | graph_datum state write "${node}"

    if test -z "$*"; then
	graph_datum contents edit "${node}"
    else
	echo "$*" | graph_datum contents write "${node}"
    fi
}


# Main entry point ************************************************************

# parse options
if test "$1" = "--non-destructive"; then
   shift
   declare GTD_NONDESTRUCTIVE_MODE=""
fi

# We special-case some verbs when they're the only argument given.

case "$1" in
    # interactively build a query with fzf
    interactive)
	# inspired by https://github.com/paweluda/fzf-live-repl
	: | fzf --print-query --preview "$0 --non-destructive \$(echo {q})"
	;;
    # print list of functions, and exit
    # just a shorthand for "all new", but this is the gtd lingo
    inbox)
	shift;
	all new | "$@";;
    *)
	# XXX: experimental
	# if the first query keyword is a filter, imply all rather than hang.
	if graph_filter_is_valid "$1"; then
	    all | "$@"
	else
	    "$@"
	fi
	;;
esac
