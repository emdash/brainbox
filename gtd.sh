#! /usr/bin/env bash

set -eo pipefail
shopt -s failglob

# name-prefixed variable here, but ...
if test -v GTD_DATA_DIR; then
    # ... prefer to keep the short name in the rest of the code for
    # now.
    export DATA_DIR="${GTD_DATA_DIR}"
else
    export DATA_DIR="./gtdgraph"
fi

# Important directories
# XXX: how to make lib dir point to directory containing this script?
export STATE_DIR="${DATA_DIR}/state"
export NODE_DIR="${STATE_DIR}/nodes"
export DEPS_DIR="${STATE_DIR}/dependencies"
export CTXT_DIR="${STATE_DIR}/contexts"
export HIST_DIR="${DATA_DIR}/hist/"
export BUCKET_DIR="${DATA_DIR}/buckets"


# These directories represent distinct sets of edges, which express
# different relations between nodes. Hopefully the names are
# self-explanatory.
EDGE_DIRS=("${DEPS_DIR}" "${CTXT_DIR}")


# Helpers *********************************************************************

# print to stderr
function debug {
    if test "$1" = "-n"; then
	shift;
	echo -n "$*" >&2
    else
	echo "$*" >&2
    fi
}

# Print error message and exit.
function error {
    echo "$1" >&2
    exit 1
}

# Subclass of error for umimplemented features.
function not_implemented {
    error "$1 is not implemented."
}

# Filter each line of stdin according to the exit status of "$@"
function filter {
    while read input; do	
	if "$@" "${input}"; then
	    echo "${input}"
	fi
    done
}

# Apply "$@" to each line of stdin.
function map {
    while read input; do
	"$@" "${input}"
    done
}

# fake cat to avoid spawning subprocess
#
# XXX: I'm not sure this is actually a performance win. Some
# benchmarking is in order. My original assumption is that process
# creation a bottleneck, but my current suspicion is that it's
# actually that `while read ...` in bash is ridiculously slow, and
# that `cat` may be faster in some cases.
#
# also, I think that this still ends up running in a subprocess.
#
# the real goal here was to avoid having to have `cat` as a dummy
# command for query helpers like `graph_filter_chain`. One would have
# suspected the null command would be useful for this, allowing a
# shell command to simply "forward" stdin to stdout, but I cannot seem
# to make it work.
function pcat {
    if test -z "$1"; then
	while read -r line; do
	    echo "${line}"
	done
    else
	while read -r line; do
	    echo "${line}"
	done < "$1"
    fi
}

# write this short python script into the data directory.
#
# XXX: this is awkward, but keeps this project self-contained. if you
# have a better idea -- particularly if you can make the bash code it
# replaces fast -- patches are welcome. probably the answer involves
# xargs. See graph_node_adjacent.
function graph_dot_py {
    cat > "${DATA_DIR}/graph.py" <<EOF
#! /usr/bin/env python3

import os
import sys

# helpers to speed up code I haven't yet figured out how to optimize
# in bash

def graph_node_adjacent(node, edge_set, direction):
    if edge_set == "dep":
        edges = os.getenv("DEPS_DIR")
    elif edge_set == "context":
        edges = os.getenv("CTXT_DIR")
    else:
        print("invald")
        exit(1)

    if direction == "outgoing":
        for edge in os.listdir(edges):
            (u, v) = edge.split(':')
            if u == node: print(v)
    elif direction == "incoming":
        for edge in os.listdir(edges):
            (u, v) = edge.split(':')
            if v == node: print(u)
    else:
        print("invalid")

if sys.argv[1] == "graph_node_adjacent":
    graph_node_adjacent(*sys.argv[2:])
EOF
    chmod +x "${DATA_DIR}/graph.py"
}


# Database Management *********************************************************


# Initialize a GTD database relative to the current working directory.
function database_init {
    if ! test -e "${DATA_DIR}"; then
	mkdir -p "${NODE_DIR}"
	for dir in "${EDGE_DIRS[@]}"; do
	    mkdir -p "${dir}"
	done
	mkdir -p "${HIST_DIR}"
	git init -q --bare "${HIST_DIR}"
	graph_dot_py
    else
	echo "Already initialized"
	return 1
    fi
}

# Check whether the data directory has been initialized.
function database_ensure_init {
    # check whether we are initialized.
    if ! test -d "${DATA_DIR}"; then
	error "$0 is not initialized. Please run: $0 init"
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

# wraps git for use as db history management.
function database_git {
    git --git-dir="${HIST_DIR}" --work-tree="${STATE_DIR}" "$@"
}

# make sure git tracks empty directories.
function database_keep_empty {
    # Git only tracks "regular" files, so it's not possible to add an
    # empty directory to a git repo.
    #
    # The simplest work-around I could think of was to add .keep files
    # to any empty subdirectores, so that git will track them.
    find "${STATE_DIR}" -type d -empty -printf '%p/.keep\0' | xargs -0 -rn 1 touch
}

# commit any changes we find to git, using the specified commit message
function database_commit {
    local path

    if test -f "${DATA_DIR}/undo_stack"; then
	rm -rf "${DATA_DIR}/undo_stack"
    fi

    database_keep_empty
    # add every plain file we find to the index
    #
    # XXX: xargs hack required to make this acceptably fast on "large"
    # databases.
    #
    # XXX: I am not sure of the best way to get xarg to putput paths
    # relative to a particular directory, or else strip prefixes. The
    # simplest solution was pushd / popd.
    pushd "${STATE_DIR}" > /dev/null
    find "." -type f -print0 |         \
	xargs                          \
	    -0                         \
	    git                        \
	    --git-dir="../hist"        \
	    --work-tree="."            \
	    add
    popd > /dev/null

    # commit the changes. arguments interpreted as message.
    database_git commit -am "$*"

    # trigger update of any live queries.
    notify_follow
}

# list all the changes to the db from the beginning of time
function database_history { database_git log --oneline ; }

# returns true if we have undone tasks
function database_have_undone {
    test -e "${DATA_DIR}/undo_stack"
}

# print the current commit hash
function database_current_commit {
    database_git show -s --pretty=oneline HEAD | cut -d ' ' -f 1
}

# print the current undo tag if it exists
function database_last_undone {
    if database_have_undone; then
	tail -n -1 < "${DATA_DIR}/undo_stack"
    else
	error "Not in undo state"
    fi
}

# function
function database_redo {
    if database_have_undone; then
	database_git reset --hard "$(database_last_undone)"
	local ncommits="$(wc -l < "${DATA_DIR}/undo_stack")"
	if test "${ncommits}" -lt 2; then
	    rm -rf "${DATA_DIR}/undo_stack"
	else
	    cp "${DATA_DIR}/undo_stack" "${DATA_DIR}/tmp"
	    head -n -1 < "${DATA_DIR}/tmp" > "${DATA_DIR}/undo_stack"
	    rm "${DATA_DIR}/tmp"
	fi
	# if all the above succeeded, trigger update of any live queries.
	notify_follow
    else
	echo "nothing to redo"
    fi
}

# restore the previous command state
function database_undo {
    local ncommits

    ncommits="$(database_history | wc -l)"

    if test "${ncommits}" -lt 2; then
	error "Nothing to undo."
    fi

    database_current_commit >> "${DATA_DIR}/undo_stack"
    database_git reset --hard HEAD^
    notify_follow
}

# revert any uncommitted changes
function database_revert {
    database_git reset --hard HEAD
    notify_follow
}

# generate random UUIDs.
function gen_uuid {
    # XXX: there are any number of ways one could do this, but I
    # already depend on python3, so this is the way I'm doing it.
    #
    # If there's enough interest, I could make the case for allowing
    # the user to tune this.
    #
    # The rationale for using UUID is that, in theory, it makes
    # collisions 'impossible'. This could be useful for synchronizing
    # state between different devices in the not-to-distant future.
    python3 -c 'import uuid; print(uuid.uuid4())'
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
    local id
    id="$(gen_uuid)"

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
# - append: append remaining arguments to datum file.
# - mkdir:  create datum as a directory
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
	# XXX: remove these two uuocs once you figure out how.
	# it seems like a `:` should work here, but it breaks the tests.
	write)   cat >          "${path}";;
	append)  cat >>         "${path}";;
	edit)   "${EDITOR}"    "${path}";;
	mkdir)  mkdir -p       "${path}";;
	cp)     cp "$@"        "${path}";;
	mv)     mv "$@"        "${path}";;

	*) error "invalid subcommand: ${command}";;
    esac
}

function __datum_read {
    test -f "${path}" &&  cat < "${path}"
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
    	mkdir -p "$(graph_node_path "${id}")"
	echo "${id}"
    fi
}

# print the set of child nodes for the given node to stdout.
#
# if predicate is given, then edges will be filtered according to this
# command.
function graph_node_adjacent {
    database_ensure_init

    # XXX: See `graph_dot_py` in the helpers section. I tried to write
    # this all in bash, but bash can be *shockingly* slow, and it's
    # not always clear why. The python script that replaces it is
    # *orders of magnitude* faster, despite doing essentially the same
    # thing, and even accounting for python interpreter overhead. We
    # are shelling out after all. This realy starts to matter when
    # your DB grows to several hundred nodes.
    "${DATA_DIR}/graph.py" graph_node_adjacent "$@"
    return "$?"

    # XXX: The code below is the bash implementation at the point I
    # gave. I leave it here so that it's clear what it is I was trying
    # to do originally. Normally I don't like leaving unreachable code
    # in place. But ultimately I want to remove the python hack, and I
    # consider this a priority.
    local node="$1"
    local edge_set="$2"
    local direction="$3"

    case "${edge_set}" in
	dep)     pushd "${DEPS_DIR}" > /dev/null;;
	context) pushd "${CTXT_DIR}" > /dev/null;;
	*)       error "${edge_set} is not one of dep | context"
    esac

    case "${direction}" in
	incoming)
	    local -a edges=( *:"${node}" )
	    local linked="graph_edge_u";;
	outgoing)
	    local -a edges=( "${node}":* )
	    local linked="graph_edge_v";;
	*) error "${direction} is not one of incoming | outgoing";;
    esac

    popd > /dev/null
    
    for edge in ${edges}; do
	"${linked}" "${edge}"
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

# Return true if the given edge touches the input set.
#
# XXX: also, this function consumes edges from stdin, and nodes from
# "$@".
#
# XXX: this should probably be renamed to reflect the fact that both
# ends of the edge must like in the input set.
function graph_edge_touches {
    local edge nodes
    local -A nodes

    for node in "$@"; do
	nodes["${node}"]="1"
    done

    while read -r edge; do
	local u v
	u="$(graph_edge_u "${edge}")"
	v="$(graph_edge_v "${edge}")"
	if test -v "nodes[${u}]" -a -v "nodes[${v}]"; then
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

    if test -v "nodes_on_stack[${cur}]"; then
	error "Graph contains a cycle"
	return 1
    fi

    # add this node to the cycle checking set
    nodes_on_stack["${cur}"]=""

    if test ! -v "seen[${cur}]"; then
	echo "${cur}"
	seen["${cur}"]="1"

	for a in $(graph_node_adjacent "${cur}" "${edge_set}" "${direction}"); do
	    __graph_traverse_rec "${a}" || return 1
	done
    fi

    # remove node from cycle checking set
    unset "nodes_on_stack[${cur}]"
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

    if test -v "nodes_on_stack[${cur}]"; then
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
    unset "nodes_on_stack[${cur}]"
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
	DONE)     return 0;;
	DROPPED)  return 0;;
	WAITING)  return 0;;
	SOMEDAY)  return 0;;
	PERSIST)  return 0;;
	*)        return 1;;
    esac
}

# returns true if the given task state can be considered active
function task_state_is_active {
    case "$1" in
	NEW)     return 0;;
	TODO)    return 0;;
	WAITING) return 0;;
	PERSIST) return 0;;
	*)       return 1;;
    esac
}

# returns true if the given task state can be acted on
function task_state_is_actionable {
    case "$1" in
	WAITING) return 1;;
	PERSIST) return 1;;
	*)    task_state_is_active "$1";;
    esac
}

# returns true if the given task is in the DONE state
function task_is_complete {
    test "$(task_state read "$1")" = "DONE"
}

# returns true if a task has at least one outgoing context edge
function task_is_context {
    test -n "$(graph_node_adjacent "$1" context outgoing)"
}


## define task data ***********************************************************

function task_contents { graph_datum contents "$@"; }
function task_state    { graph_datum state    "$@"; }

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
    task_is_root "$1" && task_is_leaf "$1"
}

# returns true if a task is a project
function task_is_project {
    ! { task_is_root "$1" || task_is_leaf "$1" ; }
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
    task_is_actionable "$1" && task_is_leaf "$1"
}

# returns true if a task is not assigned to any context
function task_is_unassigned {
    test -z "$(graph_node_adjacent "$1" context incoming)"
}

# returns true if a task is marked as waiting
function task_is_waiting {
    test "$(task_state read "$1")" = "WAITING"
}

# summarize the current task: id, status, and gloss
function task_summary {
    printf "%s %7s %s\n" "$1" "$(task_state read "$1")" "$(task_gloss "$1")"
}

## Task Management

# Automatically transition a NEW task to TODO
#
# helper function used by certain operations to streamline GTD workflow.
function task_auto_triage {
    case "$(task_state read "$1")" in
	NEW) task_activate "$1";;
    esac
}

# explicitly activate the given task by setting state TODO.
function task_activate {
    echo "TODO" | task_state write "$1"
}

# Add a dependency to an existing task
#
# $1: the existing task
# $2: the dependency
function task_add_subtask {
    task_auto_triage "$2"
    graph_edge_create "$1" "$2" dep
}

# Assign task to the given context.
#
# Note that this creates an edge in the opposite direction to
# add_subtask: from the context to the node.
#
# $1: the existing task
# $2: the context
function task_assign {
    task_auto_triage "$1"
    graph_edge_create "$2" "$1" context
}

# Remove the dependency between task and subtask
#
# $1: the existing task
# $2: the dependency
function task_remove_subtask {
    graph_edge_delete "$1" "$2" dep
}

# Remove the dependency between task and context
function task_unassign {
    graph_edge_delete "$2" "$1" context
}

# mark the given task as dropped
function task_drop {
    echo "DROPPED" | task_state write "$1"
}

# mark the given task as completed
function task_complete {
    echo "DONE" | task_state write "$1"
}

# mark the given task as someday
function task_defer {
    echo "SOMEDAY" | task_state write "$1"
}

# mark the given task as persistent
function task_persist {
    echo "PERSIST" | task_state write "$1"
}


# An Embedded DSL for Queries *************************************************


## Helpers ********************************************************************

# returns true if "$@" is recognized as a valid filter keyword
function graph_filter_is_valid {
    # XXX: this table has to be maintained manually. It is the union
    # of filters and consumers. Keep it in sync with these sections.
    case "$1" in
	# filters
	adjacent)          return 0;;
	assigned)          return 0;;
	choose)            return 0;;
	# datum exists
	datum)             return 0;;
	is_actionable)     return 0;;
	is_active)         return 0;;
	is_complete)       return 0;;
	is_context)        return 0;;
	is_new)            return 0;;
	is_next)           return 0;;
	is_orphan)         return 0;;
	is_project)        return 0;;
	is_root)           return 0;;
	is_unassigned)     return 0;;
	is_waiting)        return 0;;
	persist)           return 0;;
	project)           return 0;;
	projects)          return 0;;
	subtasks)          return 0;;
	search)            return 0;;
	someday)           return 0;;
	# nondestructive consumers
	# datum read
	# datum path
	dot)               return 0;;
	into)              return 0;;
	summarize)         return 0;;
	tree)              return 0;;
	triage)            return 0;;
	# destructive consumers
	activate)          return 0;;
	complete)          return 0;;
	# datum write
	# datum append
	# datum mkdir
	# datum cp
	defer)             return 0;;
	drop)              return 0;;
	edit)              return 0;;
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
function forbid_preview {
    if test -v GTD_PREVIEW_MODE; then
	error "Disabled in preview mode."
    fi
}

## Query Commands *************************************************************

# XXX: everything below here must be manually kept in sync with
# `manual.md`.
# Keep things in alphabetical order.

### Query Producers ***********************************************************

# These appear at the start of a filter chain, but are not themselves filters.

# all tasks
function all { graph_node_list | graph_filter_chain "$@" ; }

# output tasks from named bucket
function from {
    local bucket="${BUCKET_DIR}/$1"; shift;

    test -e "${bucket}" || error "No bucket named ${bucket}";

    ls "${bucket}" | graph_filter_chain "$@"
}

# output all new tasks
function inbox { all | is_new | graph_filter_chain "$@" ;}

# output the last captured node
function last_captured {
    if test -e "${DATA_DIR}/last_captured"; then
	cat "${DATA_DIR}/last_captured"
    fi | graph_filter_chain "$@"
}

# select every actionable project root
#
# in a well-maintained database, these will correspond to one's core
# values, or the "view from 30k ft" in GTD terminology.
function values {
    all | is_actionable is_root "$@"
}

# select every actionable project root whose parent is a value
#
# in a well-maintained database, these will correspond to long-term
# on which one places the highest priority.
function life_goals {
    values adjacent dep outgoing | graph_filter_chain "$@"
}


### Query Filters *************************************************************

# output the nodes adjacent to each input node
function adjacent {
    while read id; do
	graph_node_adjacent "${id}" "$@"
    done
}

# insert tasks assigned to each incoming context id
function assigned {
    while read id; do
	graph_traverse "${id}" context outgoing | graph_filter_chain "$@"
    done
}

# keep only the node selected by the user
function choose {
    # can't preview because this also uses FZF.
    forbid_preview

    case "$1" in
       -m|--multi)  local opt="-m"; shift;;
       -s|--single) local opt=""  ; shift;;
       *)           local opt="-m"       ;;
    esac
				  
    summarize | fzf "${opt}" | cut -d ' ' -f 1 | graph_filter_chain "$@"
}

# Keep only actionable tasks.
function is_actionable {
    filter task_is_actionable | graph_filter_chain "$@"
}

# Keep only active tasks.
function is_active {
    filter task_is_active | graph_filter_chain "$@"
}

# Keep only completed tasks
function is_complete {
    filter task_is_complete | graph_filter_chain "$@"
}

# Keep only context nodes
function is_context {
    filter task_is_context | graph_filter_chain "$@"
}

# keep only new tasks
function is_new {
    filter task_is_new | graph_filter_chain "$@"
}

# Keep only next actions
function is_next {
    filter task_is_next_action | graph_filter_chain "$@"
}

# Keep only tasks not associated with any other tasks
function is_orphan {
    filter task_is_orphan | graph_filter_chain "$@"
}

# Keep only tasks which are considered projects
function is_project {
    filter task_is_project | graph_filter_chain "$@"
}

# Keep only tasks which are the root of a subgraph
function is_root {
    filter task_is_root | graph_filter_chain "$@"
}

# Keep only tasks not assigned to any context
function is_unassigned {
    filter task_is_unassigned | graph_filter_chain "$@"
}

# Keep only waiting tasks
function is_waiting {
    filter task_is_waiting | graph_filter_chain "$@"
}

# insert parents of each incoming task id
function projects {
    while read id; do
	graph_traverse "${id}" dep incoming
    done | graph_filter_chain "$@"
}

# insert subtasks of each incoming parent task id
function subtasks {
    while read id; do
	graph_traverse "${id}" dep outgoing
    done | graph_filter_chain "$@"
}

# keep only nodes whose contents matches the given *pattern*.
#
# tbd: make this more configurable
function search {
    local pattern="$1"; shift
    while read id; do
	if graph_datum contents read "${id}" | grep -q "${pattern}" -; then
	    echo "${id}"
	fi
    done | graph_filter_chain "$@"
}

## Non-destructive Query Consumers ********************************************

# runs graph_datum $1 $2 ${id} for each id
function datum {
    test -z "$1" && error "a datum is required"
    case "$2" in
	exists)    __datum_exists    "$@";;
	path|read) __datum_path_read "$@";;
	mkdir|cp)  __datum_mkdir_cp  "$@";;
	*)         error "invalid subcommand: ${command}";;
    esac
}

function __datum_exists {
    local datum="$1";
    # dropping second argument
    shift 2
    filter graph_datum "${datum}" exists | graph_filter_chain "$@"
}

function __datum_path_read {
    local datum="$1"; shift
    local command="$1"; shift
    end_filter_chain "$@"
    map graph_datum "${datum}" "${command}"
}

function __datum_mkdir_cp {
    forbid_preview
    local datum="$1"; shift
    local command="$1"; shift
    end_filter_chain "$@"
    map graph_datum "${datum}" "${command}"
}

# dotfile export for graphviz
function dot {
    case "$1" in
	dep|context|all) local edge_set="$1"; shift;;
	*) error "$1 not one of dep | context";;
    esac

    end_filter_chain "$@"

    echo "digraph {"

    echo "rankdir=LR;"

    declare -A nodes

    # output an entry for each node
    while read id; do
	printf "\"${id}\" [label=\"%q\", shape=\"box\",width=1];\n" "$(task_gloss "${id}")"
	nodes["$id"]=""
    done

    graph_edge_list "${edge_set}" | graph_edge_touches "${!nodes[@]}" | while read edge; do
	echo "\"$(graph_edge_u "${edge}")\" -> \"$(graph_edge_v "${edge}")\";"
    done

    echo "}"
}

# Add node ids to the named bucket
#
# By default, the new contents replace the old contents. Give `--union`
# is this is undesired.
function into {
    case "$1" in
	--union)
	    local bucket="${BUCKET_DIR}/$2";;
	*)
	    local bucket="${BUCKET_DIR}/$1";
	    rm -rf "${bucket}";;
    esac
    
    mkdir -p "${bucket}"

    while read id; do
	touch "${bucket}/${id}"
    done

    # into doesn't create a commit, so we need to explicitly notify.
    notify_follow
}

# Print a one-line summary for each task id
function summarize {
    end_filter_chain "$@"
    map task_summary
}

# tree expansion of project rooted at the given node for given edge set and direction.
#
# tree filters can be chained onto this, but not graph filters
function tree {
    case "$1" in
	dep|context) local edge_set="$1";;
	*)           error "$1 not one of: dep | context";;
    esac

    case "$2" in
	incoming|outgoing) local direction="$2";;
	*)                 error "$2 is not one of: incoming | outgoing";;
    esac

    shift 2

    while read root; do
	graph_expand \
	    --depth \
	    "${root}" \
	    "${edge_set}" \
	    "${direction}"
    done | tree_filter_chain "$@"
}

# indent tree expansion
#
# TBD: merge this functionality into summarize?
function indent {
    if test "$1" = "--gloss-only"; then
	local no_meta=""; shift;
    fi
    
    if test -n "$1"; then
	local marker="$(echo "$1")"; shift
    else
	local marker='  '
    fi

    end_filter_chain "$@"

    while read id depth; do
	if test ! -v no_meta; then
	   printf "%7s" "$(task_state read "${id}")"
	fi

	# indent the line.
	for i in $(seq $(("${depth}"))); do
	    echo -n "${marker}"
	done

	printf " $(task_gloss "${id}")\n"
    done
}

# Shorthand for formatting a project as a tree
function project {
    tree dep outgoing indent "$@"
}

## Destructive Query Commands *************************************************

# Reactivate each task id
function activate {
    forbid_preview
    end_filter_chain "$@"
    map task_activate
    database_commit "${SAVED_ARGV}"
}

# Complete each task id
function complete {
    forbid_preview
    end_filter_chain "$@"
    map task_complete
    database_commit "${SAVED_ARGV}"
}

# Drop each task id
function drop {
    forbid_preview
    end_filter_chain "$@"
    map task_drop
    database_commit "${SAVED_ARGV}"
}

# Defer each task id
function defer {
    forbid_preview
    end_filter_chain "$@"
    map task_defer
    database_commit "${SAVED_ARGV}"
}

# edit the contents of node in the input set in turn.
function edit {
    forbid_preview

    if test "$1" = "--sequential"; then
	local sequential=1; shift;
    fi

    end_filter_chain "$@"

    if test -v sequential; then
	datum contents path | while read -r line; do
	    # xargs -o: reopens stdin / stdout as tty in the child process.
	    echo "${line}" | xargs -o "${EDITOR}"
	done
    elif test -z "$1"; then
	# xargs -o: reopens stdin / stdout as tty in the child process.
	datum contents path | xargs -o "${EDITOR}"
    else
	error "invalid argument: $1"
    fi
    database_commit "${SAVED_ARGV}"
}

# persist each task
function persist {
    forbid_preview
    end_filter_chain "$@"
    map task_persist
    database_commit "${SAVED_ARGV}"
}


# Non-query commands **********************************************************

# List all known buckets
function buckets {
    ls "${BUCKET_DIR}"
}

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
function capture {
    forbid_preview
    local node="$(graph_node_create)"

    echo "NEW" | graph_datum state write "${node}"

    if test -z "$*"; then
	if tty > /dev/null; then
	    graph_datum contents edit "${node}"
	else
	    echo "from stdin"
	    graph_datum contents write "${node}"
	fi
    else
	echo "$*" | graph_datum contents write "${node}"
    fi

    database_commit "${SAVED_ARGV}"

    echo "${node}" > "${DATA_DIR}/last_captured"
}

# Clobber the database
function clobber {
    forbid_preview
    database_clobber;
}

# Initialize the database
function init {
    forbid_preview
    database_init;
    mkdir -p "${BUCKET_DIR}"
}

# interactively build query
function interactive {
    forbid_preview
    # inspired by https://github.com/paweluda/fzf-live-repl
    : | fzf \
	    --print-query \
	    --preview "$0 --preview \$(echo {q})" \
	| into interactive "$@"
}

# Create edges between sets of nodes in the given named buckets.
#
# The first argument is the "edge set", which is either `task` or
# `context`.
#
# The second argument is the *from bucket*.
#
# The third argument is the *into bucket*.
#
# Every node in the *from* set will be linked to every node in the
# *into* set. Typically, one of these sets will contain only a single
# node.
function link {
    forbid_preview

    case "$1" in
	subtask) local link="task_add_subtask";;
	context) local link="task_assign";;
	*)       error "Not one of subtask | context";;
    esac

    local from_ids="$(from "$2")"
    local into_ids="$(from "$3")"

    for u in ${from_ids}; do
	for v in ${into_ids}; do
	    "${link}" "${u}" "${v}" "${edge_set}"
	done
    done

    database_commit "${SAVED_ARGV}"
}

# remove edges between sets of nodes in different buckets
function unlink {
    forbid_preview

    case "$1" in
	subtask) local link="task_remove_subtask";;
	context) local link="task_unassign";;
	*)       error "Not one of subtask | context";;
    esac

    local from_ids="$(from "$2")"
    local into_ids="$(from "$3")"

    for u in ${from_ids}; do
	for v in ${into_ids}; do
	    "${link}" "${u}" "${v}" "${edge_set}"
	done
    done

    database_commit "${SAVED_ARGV}"
}

# interactively distribute items in the input set into buckets
function triage {
    local -a choice
    while read id; do
	if choices=( $(__triage "${id}" "$@" ) ); then
	    for choice in "${choices[@]}"; do
		echo "triaging $(task_gloss "${id}") as ${choice}"
		echo "${id}" | into "${choice}"
	    done
	else
	    return 1
	fi
    done
}

function __triage {
    local choice
    local -a choices
    while true; do
	if choice="$(__triage_select "$@")"; then
	    if test "${choice}" = '<done>'; then
		break
	    elif test "${choice}" = '<new>'; then
		choices+=( "$(__triage_new)" )
	    else
		choices+=( "${choice}" )
	    fi
	else
	    return 1
	fi
    done
    for choice in "${choices[@]}"; do
	echo "${choice}"
    done
}

function __triage_select {
    local id="$1"; shift
    __triage_buckets "$@" \
	| fzf \
	      --tac \
	      --no-sort \
	      --preview "echo '${choices[*]}'; $0 task_contents read ${id}"
}

function __triage_new {
    : | fzf --print-query --prompt="New Bucket: "
}

function __triage_buckets {
    if test -z "$*"; then
	buckets
    else
	for bucket in "$@"; do
	    echo "${bucket}"
	done
    fi
    echo '<new>'
    echo '<done>'
}

## Live Queries ***************************************************************

# evaluate the given non-interactive query each time the database changes
function follow {
    local -r query="$@"
    local -r fifo="${DATA_DIR}/follow"

    # tbd: allow multiple live queries. just one will do for now.
    if test -e "${fifo}"; then
	error "at most live query at is supported"
    else
	trap __follow_exit EXIT
	mkfifo "${fifo}"

	# the protocol is really simple. we just read a line from the
	# fifo, re-running the query each time we do. the contents of
	# the line don't matter.
	while true; do
	    "$0" --preview ${query}
	    printf '\0'
	    read -r ignored < "${fifo}" || true
	done
    fi
}

function __follow_exit {
    test -e "${DATA_DIR}/follow" && rm "${DATA_DIR}/follow"
}

# notify live queries to re-run after database commits.
function notify_follow {
    local -r fifo="${DATA_DIR}/follow"
    if test -e "${fifo}"; then
	echo "notify" > "${fifo}"
    fi
}

## State management ***********************************************************

# restore the last undone command, if one exists
function redo {
    forbid_preview
    database_redo
}

# roll back to the state prior to execution of the last destructive
function undo {
    forbid_preview
    database_undo
}

# show the current database undo
function history {
    # cat here to prevent pager from being invoked, which is annoying
    # within emacs. but maybe I should remove this.
    database_history | cat ;
}

# Main entry point ************************************************************

# save args for undo log
SAVED_ARGV="$@"

# parse options
if test "$1" = "--preview"; then
   declare GTD_PREVIEW_MODE=""; shift
fi

case "$1" in
    # handle the case where we actually want to read nodes from `stdin`
    -) shift; graph_filter_chain "$@" ;;
    # if the first argument is a query filter, `all` is the implied producer
    *) if graph_filter_is_valid "$1"; then all | "$@" ; else "$@" ; fi ;;
esac
