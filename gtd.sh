#! /usr/bin/env bash

set -eo pipefail
shopt -s failglob

# name-prefixed variable here, but ...
if test -v GTD_DATA_DIR; then
    # ... prefer to keep the short name in the rest of the code.
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

# Return true if stdin is empty
function empty {
    xargs -rn 1 false
}

# Subclass of error for umimplemented features.
function not_implemented {
    error "$1 is not implemented."
}

# Filter each line of stdin according to the exit status of "$@"
function filter {
    local input
    while IFS="" read -r input; do	
	if "$@" "${input}"; then
	    echo "${input}"
	fi
    done
}

# Apply "$@" to each line of stdin.
function map {
    local input
    while IFS="" read -r input; do
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
	mkdir -p "${HIST_DIR}"
	git init -q --bare "${HIST_DIR}"
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
    local confirm
    read -re confirm
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
    follow_notify
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
	follow_notify
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
    follow_notify
}

# revert any uncommitted changes
function database_revert {
    database_git reset --hard HEAD
    follow_notify
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

# wraps a python script which is used to "accelerate" some operations.
function graph { "${GTD_DIR}/graph.py" "$@" ; }


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

    case "${edge_set}" in
	dep)     echo  "${DEPS_DIR}/$(graph_edge "${u}" "${v}")";;
	context) echo  "${CTXT_DIR}/$(graph_edge "${u}" "${v}")";;
	*)       error "$3 not one of dep | context";;
    esac
}

# Link two nodes in the graph.
function graph_edge_create {
    database_ensure_init

    test -d "$(graph_node_path "$1")" || error "Invalid ID $1"
    test -d "$(graph_node_path "$2")" || error "Invalid ID $2"
    
    mkdir -p "$(graph_edge_path "$1" "$2" "$3")"
}

# Break the link between two nodes.
#
# also remove any related edge properties.
function graph_edge_delete {
    database_ensure_init
    rm -rf "$(graph_edge_path "$1" "$2" "$3")"
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

function graph_filter_default {
    case "$1" in
	adjacent)          echo "from" "cur";;
	assignees)         echo "from" "cur";;
	children)          echo "from" "cur";;
	choose)            echo "all";;
	contexts)          echo "from" "cur";;
	# datum exists
	datum)             echo "from" "target";;
	is_actionable)     echo "all";;
	is_active)         echo "all";;
	is_complete)       echo "all";;
	is_context)        echo "all";;
	is_deferred)       echo "all";;
	is_new)            echo "all";;
	is_next)           echo "all";;
	is_orphan)         echo "all";;
	is_persistent)     echo "all";;
	is_project)        echo "all";;
	is_root)           echo "all";;
	is_unassigned)     echo "all";;
	is_waiting)        echo "all";;
	parents)           echo "from" "cur";;
	project)           echo "from" "cur";;
	projects)          echo "from" "cur";;
	subtasks)          echo "from" "cur";;
	search)            echo "all";;
	someday)           echo "from" "target";;
	# formatters
	# datum read
	# datum path
	dot)               echo "all";;
	into)              echo "all" "choose";;
	summarize)         echo "all";;
	tree)              echo "from" "cur";;
	# updates
	activate)          echo "from" "target";;
	complete)          echo "from" "target";;
	# datum write
	# datum append
	# datum mkdir
	# datum cp
	defer)             echo "from" "target";;
	drop)              echo "from" "target";;
	edit)              echo "from" "cur";;
	goto)              echo "all";;
	persist)           echo "from" "target";;
    esac
}

# returns true if "$@" is recognized as a valid filter keyword
function graph_filter_is_valid {
    test -n "$(graph_filter_default "$1")"
}

# execute a query from the given arguments
function graph_filter_begin {
    local default

    if graph_filter_is_valid "$1"; then
	$(graph_filter_default "$1") "$@"
    elif test "$1" = "-"; then
	shift
	graph_filter_chain "$@"
    else
	"$@"
    fi
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
    local -r name="${FUNCNAME[1]}"
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
    test -e "${bucket}" || mkdir -p "${bucket}"
    ls "${bucket}" | graph_filter_chain "$@"
}

# output all new tasks
function inbox { all | is_new | graph_filter_chain "$@" ; }

# output the last captured node
function last_captured {
    if test -e "${DATA_DIR}/last_captured"; then
	cat "${DATA_DIR}/last_captured"
    fi | graph_filter_chain "$@"
}

# output an empty set
function null { : | graph_filter_chain "$@" ; }

### Query Filters *************************************************************

# output nodes reachable from each node in the input set
function reachable {
    local edges="$1"
    local direction="$2"
    shift 2
    graph reachable "${edges}" "${direction}" | graph_filter_chain "$@"
}

# output the nodes adjacent to each input node
function adjacent {
    local edges="$1"
    local direction="$2"
    shift 2
    graph adjacent "${edges}" "${direction}" | graph_filter_chain "$@"
}

# insert tasks assigned to each incoming context id
function assignees { reachable context outgoing "$@" ; }

# immediate subtasks of the input set
function children { adjacent dependencies outgoing "$@" ; } 

# immediate context edgres
function contexts { adjacent context incoming "$@" ; }

# keep only the node selected by the user
function choose {
    # can't preview because this also uses FZF.
    forbid_preview

    case "$1" in
       -m|--multi)  local opt="-m"; shift;;
       -s|--single) local opt=""  ; shift;;
       *)           local opt="-m"       ;;
    esac

    summarize | fzf ${opt} | cut -d ' ' -f 1 | graph_filter_chain "$@"
}

# Keep only actionable tasks.
function is_actionable {
    graph filter_state NEW TODO | graph_filter_chain "$@"
}

# Keep only active tasks.
function is_active {
    graph filter_state \
	NEW \
	TODO \
	WAITING \
	PERSIST \
    | graph_filter_chain "$@"
}

# Keep only completed tasks
function is_complete { graph filter_state DONE | graph_filter_chain "$@" ; }

# Keep only context nodes
function is_context { graph is_context | graph_filter_chain "$@" ; }

# Keep only deferred nodes
function is_deferred {  graph filter_state SOMEDAY | graph_filter_chain "$@" ; }

# keep only new tasks
function is_new { graph filter_state NEW | graph_filter_chain "$@" ; }

# Keep only next actions
function is_next { graph is_next | is_actionable "$@" ; }

# Keep only tasks not associated with any other tasks
function is_orphan { graph is_orphan | graph_filter_chain "$@" ; }

# Keep only tasks in state PERSIST
function is_persistent {
    graph filter_state PERSIST | graph_filter_chain "$@"
}

# Keep only tasks which are considered projects
function is_project { graph is_project | graph_filter_chain "$@" ; }

# Keep only tasks which are the root of a subgraph
function is_root { graph is_root | graph_filter_chain "$@" ; }

# Keep only tasks not assigned to any context
function is_unassigned { graph is_unassigned | graph_filter_chain "$@" ; }

# Keep only waiting tasks
function is_waiting { graph filter_state WAITING | graph_filter_chain "$@" ; }

# adjacent incoming dependencies of input set
function parents { adjacent dependencies incoming "$@" ; }

# insert parents of each incoming task id
function projects { reachable dependencies incoming "$@" ; }

# insert subtasks of each incoming parent task id
function subtasks { reachable dependencies outgoing "$@" ; }

# keep only nodes whose contents matches the given *pattern*.
#
# tbd: make this more configurable
function search {
    local pattern="$1"; shift
    local id
    while IFS="" read -r id; do
	if graph_datum contents read "${id}" | grep -q "${pattern}" -; then
	    echo "${id}"
	fi
    done | graph_filter_chain "$@"
}

## Formatters *****************************************************************

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
function capture {
    forbid_preview

    case "$1" in
	-b|--bucket)
	    local bucket="$2"
	    shift 2
	    ;;
    esac

    local node="$(graph_node_create)"
    echo "NEW" | graph_datum state write "${node}"

    # no need to call "end filter chain", as we consume all arguments.
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

    if test -n "${bucket}"; then
	from "${bucket}" | while IFS="" read -r parent; do
	    graph_edge_create "${parent}" "${node}" dep
	    task_auto_triage "${node}"
	done
    fi
}

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
    graph dot
}

# Add node ids to the named bucket
#
# By default, the new contents replace the old contents. Give `--union`
# is this is undesired.
function into {
    # copy stdin into demp dir
    local temp="${DATA_DIR}/temp"
    test -e "${temp}" && rm -r "${temp}"
    mkdir -p "${temp}"
    while IFS="" read -r id; do
	touch "${temp}/${id}"
    done
    
    case "$1" in
	--union)
	    __into_copy "$2"
	    ;;
	--subtract)
	    ls "${temp}" | while read -r id; do
		if test -e "${BUCKET_DIR}/$2/${id}"; then
		    rm -r "${BUCKET_DIR}/$2/${id}"
		fi
	    done
	    ;;
	--intersect)
	    ls "${BUCKET_DIR}/$2" | while read -r id; do
		if test ! -e "${temp}/${id}"; then
		    rm -r "${BUCKET_DIR}/$2/${id}"
		fi
	    done
	    ;;
	--noempty)
	    if test -s "${temp}"; then
		__into_clear "$2"
		__into_copy "$2"
	    else
		return 1
	    fi
	    ;;
	*)
	    __into_clear "$1"
	    __into_copy "$1"
	    ;;
    esac
    follow_notify
}

function __into_clear {
    if test -e "${BUCKET_DIR}/$1/${id}"; then
	rm -r "${BUCKET_DIR}/$1/${id}"
    fi
    mkdir -p "${BUCKET_DIR}/$1/${id}"
}

function __into_copy {
    ls "${temp}" | while read -r id; do
	touch "${BUCKET_DIR}/$1/${id}"
    done
}

# Print a one-line summary for each task id
function summarize {
    end_filter_chain "$@"
    map task_summary
}

# tree expansion of project rooted at the given node for given edge set and direction.
#
# tree filters can be chained onto this, but not graph filters
function tree { graph expand "$1" "$2" | indent "$@" ; }

# indent tree expansion
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

    local depth
    while IFS="" read -r id depth; do
	if test ! -v no_meta; then
	   printf "%s %7s" "${id}" "$(task_state read "${id}")"
	fi

	# indent the line.
	for i in $(seq $(("${depth}"))); do
	    echo -n "${marker}"
	done

	printf " $(task_gloss "${id}")\n"
    done
}


## Updates ********************************************************************

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

# Defer each task id
function defer {
    forbid_preview
    end_filter_chain "$@"
    map task_defer
    database_commit "${SAVED_ARGV}"
}

# Drop each task id
function drop {
    forbid_preview
    end_filter_chain "$@"
    map task_drop
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
	local line
	datum contents path | while IFS="" read -r line; do
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

# set the current node
function goto {
    forbid_preview
    local bucket="$1"; shift
    end_filter_chain "$@"
    choose into --noempty "${bucket}"
}

# persist each task
function persist {
    forbid_preview
    end_filter_chain "$@"
    map task_persist
    database_commit "${SAVED_ARGV}"
}


# Non-query commands **********************************************************

# add subtasks to target
function add {
    link subtask "$@"
}

# assign tasks to contexts
function assign {
    case "$#" in
	1) link context target "$1";;
	2) link context "$2" "$1";;
	*) link context target source;;
    esac
}

# List all known buckets
function buckets {
    ls "${BUCKET_DIR}"
}

# Clobber the database
function clobber {
    forbid_preview
    database_clobber;
}

# move downward from cur
function down {
    forbid_preview
    from "$1" children goto "$1"
}

# Initialize the database
function init {
    forbid_preview
    database_init;
    mkdir -p "${BUCKET_DIR}"
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
	subtask) local edge_set="dep";;
	context) local edge_set="context";;
	*)       error "Not one of subtask | context";;
    esac

    local from_ids="$(from "${2:-source}")"
    local into_ids="$(from "${3:-target}")"

    for u in ${from_ids}; do
	for v in ${into_ids}; do
	    graph_edge_create "${u}" "${v}" "${edge_set}"
	    task_auto_triage "${v}"
	done
    done

    database_commit "${SAVED_ARGV}"
}

# remove subtasks
function remove {
    unlink subtask "$@"
}

# unassign tasks and contexts
function unassign {
    case "$#" in
	1) unlink context target "$1";;
	2) unlink context "$2" "$1";;
	*) unlink context target source;;
    esac
}

# remove edges between sets of nodes in different buckets
function unlink {
    forbid_preview

    case "$1" in
	subtask) local edge_set="dep";;
	context) local edge_set="context";;
	*)       error "Not one of subtask | context";;
    esac


    local from_ids="$(from "${2:-source}")"
    local into_ids="$(from "${3:-target}")"

    for u in ${from_ids}; do
	for v in ${into_ids}; do
	    graph_edge_delete "${u}" "${v}" "${edge_set}"
	done
    done

    database_commit "${SAVED_ARGV}"
}

# Move upward from cur
function up {
    forbid_preview
    from "$1" parents goto "$1"
}

## Live Queries ***************************************************************

# evaluate read-only queries each time the database changes
#
# the arguments are interpreted as the *initial query*.
#
# only one live query is supported per database. if called multiple
# times, the *initial query* is replaced.
function follow {
    local -r initial_query="$@"
    local -r fifo="${DATA_DIR}/follow"

    echo "${initial_query}" > "${DATA_DIR}/query"

    if test -e "${fifo}"; then
	follow_notify
    else
	trap __follow_exit EXIT
	mkfifo "${fifo}"

	# the protocol is really simple. we just read a line from the
	# fifo, re-running the query each time
	while true; do
	    local ignored
	    # read the query into an array
	    local -a query
	    read -ra query < "${DATA_DIR}/query"

	    # run the query
	    "$0" --preview "${query[@]}"

	    # output the record delimiter
	    echo -ne '\0'

	    # wait for the next notification
	    read -r ignored < "${fifo}" || true
	done
    fi
}

function __follow_exit {
    test -e "${DATA_DIR}/follow" && rm "${DATA_DIR}/follow"
}

# notify live queries to re-run after database commits.
function follow_notify {
    local -r fifo="${DATA_DIR}/follow"
    if test -e "${fifo}"; then
	echo "notify" > "${fifo}"
    fi
}

# short for follow *query* *filter*... dot all | xdot --streaming-mode
#
# --streaming-mode is a customization I added, it's not available on
# --the official xdot. PR submitted
function visualize {
    if test -z "$*"; then
	error "An initial query is required"
    else
	if test -e "${DATA_DIR}/follow"; then
	    follow "$@" dot
	else
	    follow "$@" dot | xdot --streaming-mode
	fi
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

graph_filter_begin "$@"
