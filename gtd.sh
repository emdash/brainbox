#! /usr/bin/env bash


set -eo pipefail
shopt -s failglob

if test "$1" = "--trace"
then
    shift
    set -x
fi


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
export HIST_DIR="${DATA_DIR}/hist/"
export BUCKET_DIR="${DATA_DIR}/buckets"


# These directories represent distinct sets of edges, which express
# different relations between nodes. Hopefully the names are
# self-explanatory.
EDGES=("dependencies", "contexts")


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
    if test "$1" = "-n"
    then
	shift
	local input
	while IFS="" read -r input; do	
	    if ! "$@" "${input}"; then
		echo "${input}"
	    fi
	done
    else
	local input
	while IFS="" read -r input; do	
	    if "$@" "${input}"; then
		echo "${input}"
	    fi
	done
    fi
}

# Apply "$@" to each line of stdin.
function map {
    local input
    while IFS='' read -r input; do
	"$@" "${input}"
    done
}


# Database Management *********************************************************


# Initialize a GTD database relative to the current working directory.
function database_init {
    if ! test -e "${DATA_DIR}"; then
	mkdir -p "${NODE_DIR}"
	for dir in "${EDGE_DIRS[@]}"; do
	    mkdir -p "${STATE_DIR}/${dir}"
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

# list all the valid edge sets
function edges { echo "${EDGE_DIRS[@]}" ; }

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

# Print the path to the edge connecting nodes u and v, if it exists.
function graph_edge_path {
    database_ensure_init
    local u="$1"
    local v="$2"
    local edge_set="$3"
    echo "${STATE_DIR}/${edge_set}/$(graph_edge "${u}" "${v}")"
}

# Link two nodes in the graph.
function graph_edge_create {
    database_ensure_init
    test -e "${STATE_DIR}/${3}"       || error "Invalid edge set: $3"
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

# These associative arrays store meta-data about query commands which
# help in command parsing.
declare -a GTD_COMMANDS
declare -A GTD_COMMAND_ARGS
declare -A GTD_QUERY_DEFAULT
declare -A GTD_QUERY_TYPE
declare -A GTD_QUERY_CANONICAL_NAME

# register a command for completion suggestions
function command_declare {
    local -r cmd="$1"
    shift
    GTD_COMMANDS+=("${cmd}")
    GTD_COMMAND_ARGS["${cmd}"]="$*"
}

# true if given command is registered as a query
function command_is_query {
    case "$(query_command_type "$1")" in
	invalid) return 1;;
	*)       return 0;;
    esac
}

# list all registered commands
function commands {
    for cmd in "${GTD_COMMANDS[@]}"
    do
	echo "${cmd}"
    done
}

# list the arguments for the given command
function command_args { echo "${GTD_COMMAND_ARGS[$1]}" ; }

# list all query subcommands
function queries {
    commands | filter command_is_query
}

# list all chainable commands
function filters {
    commands | filter query_command_is_chainable_to
}

# list all non-producer commands
function chainable {
    commands | filter -n query_command_is_chainable_from
}

# annotate a query filter or consumer with its "default query"
function query_declare_default_producer {
    GTD_QUERY_DEFAULT["$1"]="${@:2:$# - 1}"
}

# print the "default query" for the given filter or consumer
function query_default_producer {
    if test -v "GTD_QUERY_TYPE[$1]"
    then
	echo "${GTD_QUERY_DEFAULT[$1]}"
    else
	error "$1 defines no default producer"
    fi
}

# declare the canonical name of of the query command
#
# this will also register the canonical name for completion.
function query_declare_canonical_name {
    if test -v "GTD_QUERY_CANONICAL_NAME[$2]"
    then
	error "a canonical name for $2 is already defined"
    fi

    GTD_QUERY_CANONICAL_NAME["$2"]="$1"
    command_declare "$2"
}

# set the type function to the given constant type
#
# this also registers the function in the list of completions
function query_declare_type {
    GTD_QUERY_TYPE["$1"]="$2"
    command_declare "$1" "${@:3:$# - 2}"
}

# output the type of the query command
function query_command_type {
    if test -v "GTD_QUERY_TYPE[$1]"
    then
	echo "${GTD_QUERY_TYPE[$1]}"
    else
	echo "invalid"
    fi
}

# exit true if the given query command is valid.
function query_command_is_valid {
    test ! "$(query_command_type $@)" = "invalid"
}

# true if the given query command acts as a filter
function query_command_is_filter {
    case "$(query_command_type $@)" in
	filter) return 0;;
	binop)  return 0;;
	*)      return 1;;
    esac
}

# true if the given query command is a filter or consumer
function query_command_is_chainable_to {
    case "$(query_command_type "$@")" in
	filter)    return 0;;
	binop)     return 0;;
	formatter) return 0;;
	selection) return 0;;
	update)    return 0;;
	*)         return 1;;
    esac
}

# true if the given query command is a producer or filter
function query_command_is_chainable_from {
    case "$(query_command_type "$@")" in
	filter)    return 0;;
	binop)     return 0;;
	producer)  return 0;;
	*)         return 1;;
    esac
}

# true if the given query command is not a filter or consumer
function query_command_is_producer {
    case "$(query_command_type "$@")" in
	producer) return 0;;
	*)        return 1;;
    esac
}

# true if the given query command consumes the query
function query_command_is_consumer {
    case "$(query_command_type "$@")" in
	formatter) return 0;;
	update)    return 0;;
	selection) return 0;;
	*)         return 1;;
    esac
}

# return true if the given query command allows 

# print the index into which the 
function query_find_consumer {
    local -i i=1
    while test -n "$*"; do
	if query_command_is_consumer "$@"; then
	    echo "${i}"
	    return 0
	else
	    shift
	    i="$((i + 1))"
	fi
    done
    return 1
}

# split command into `query` and `consumer` arrays
#
# where `query` is the pure part of the query
# and `consumer` is a downstream formatter or action
#
# returns 1 if no consumer is found, meaning the query is pure.
function query_split_consumer {
    local -ir query_length="$#"
    local -i  tail_start
    if tail_start="$(query_find_consumer "$@")"; then
	query=( "${@:1:tail_start - 1}" )
	consumer=( "${@:tail_start:query_length - tail_start + 1}" )
	return 0
    else
	return 1
    fi
}

# convert a query to its canonical form, inserting implicit prodcers
# if needed.
#
# to avoid quoting issues, the canoncical query is placed into the
# `canonical` array, rather than printed to stdout.
#
# returns true if the canonical query is distinct from the given query.
function query_canonicalize {
    local -ir query_length="$#"
    local -i  tail_start

    canonical=( "$@" )

    local -i i=0
    while test "${i}" -lt "${query_length}"
    do
	local cmd="${canonical[${i}]}"
	if test -v "GTD_QUERY_CANONICAL_NAME[${cmd}]"
	then
	    canonical["${i}"]="${GTD_QUERY_CANONICAL_NAME[${cmd}]}"
	fi
	i="$((i + 1))"
    done

    if query_command_is_chainable_to "$1"; then
	canonical=( $(query_default_producer "$@") "$@" )
    fi
}

# allow further chaining of graph query filters.
#
# if args are given, and a valid filter, then fold the given command
# into the pipeline.
#
# if no args are given, forward stdin to stdout
function query_filter_chain {
    if test -n "$*"; then
	if query_command_is_chainable_to "$1"; then
	    "$@"
	else
	    error "$1 is not a valid graph query filter"
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
query_declare_type all producer
function all { graph_node_list | query_filter_chain "$@" ; }

# output tasks from named bucket
query_declare_type from producer bucket
function from {
    local bucket="${BUCKET_DIR}/$1"; shift;
    test -e "${bucket}" || mkdir -p "${bucket}"
    ls "${bucket}" | query_filter_chain "$@"
}

# output all new tasks
query_declare_type inbox producer
function inbox { all | is_new | query_filter_chain "$@" ; }

# output the last captured node
query_declare_type last_captured producer
function last_captured { from last_captured | query_filter_chain "$@" ; }

# output an empty set
query_declare_type null producer
function null { : | query_filter_chain "$@" ; }

### Query Filters *************************************************************

# output nodes reachable from each node in the input set
query_declare_type             reachable filter edgeset direction
query_declare_default_producer reachable from cur 
function reachable {
    local edges="$1"
    local direction="$2"
    shift 2
    graph reachable "${edges}" "${direction}" | query_filter_chain "$@"
}

# output the nodes adjacent to each input node
query_declare_type             adjacent filter edgeset direction
query_declare_default_producer adjacent from cur
function adjacent {
    local edges="$1"
    local direction="$2"
    shift 2
    graph adjacent "${edges}" "${direction}" | query_filter_chain "$@"
}

# insert tasks assigned to each incoming context id
query_declare_type             assignees filter
query_declare_default_producer assignees from cur
function assignees { reachable contexts outgoing | query_filter_chain "$@" ; }

# insert contexts to which we have been directly assigned
query_declare_type             assignments filter
query_declare_default_producer assignments from cur
function assignments { adjacent contexts incoming | query_filter_chain "$@" ; }

# immediate subtasks of the input set
query_declare_type             children filter
query_declare_default_producer children from cur
function children { adjacent dependencies outgoing "$@" ; } 

# immediate context edgres
query_declare_type             contexts filter
query_declare_default_producer contexts from cur
function contexts { adjacent contexts incoming "$@" ; }

# keep only the node selected by the user
query_declare_type             choose   filter '--multi|--single'
query_declare_default_producer choose   all
function choose {
    # can't preview because this also uses FZF.
    forbid_preview

    case "$1" in
       -m|--multi)  local opt="-m"; shift;;
       -s|--single) local opt=""  ; shift;;
       *)           local opt="-m"       ;;
    esac

    summarize | fzf ${opt} | cut -d ' ' -f 1 | query_filter_chain "$@"
}

# keep nodes for which the given datum exists
query_declare_type             has filter datum
query_declare_default_producer has all
function has {
    local -r datum="$1"
    shift
    filter graph_datum "${datum}" exists | query_filter_chain "$@"
}

# Keep only actionable tasks.
query_declare_type             is_actionable filter
query_declare_default_producer is_actionable all
function is_actionable {
    graph filter_state NEW TODO | query_filter_chain "$@"
}

# Keep only active tasks.
query_declare_type             is_active filter
query_declare_default_producer is_active all
function is_active {
    graph filter_state \
	NEW \
	TODO \
	WAITING \
	PERSIST \
    | query_filter_chain "$@"
}

# Keep only completed tasks
query_declare_type             is_complete filter
query_declare_default_producer is_complete all
function is_complete { graph filter_state DONE | query_filter_chain "$@" ; }

# Keep only context nodes
query_declare_type             is_context filter
query_declare_default_producer is_context all
function is_context { graph is_context | query_filter_chain "$@" ; }

# Keep only deferred nodes
query_declare_type             is_deferred filter
query_declare_default_producer is_deferred all
function is_deferred {  graph filter_state SOMEDAY | query_filter_chain "$@" ; }

# keep only new tasks
query_declare_type             is_new filter
query_declare_default_producer is_new all
function is_new { graph filter_state NEW | query_filter_chain "$@" ; }

# Keep only next actions
query_declare_type             is_next filter
query_declare_default_producer is_next all
function is_next { graph is_next | is_actionable "$@" ; }

# Keep only tasks not associated with any other tasks
query_declare_type             is_orphan filter
query_declare_default_producer is_orphan all
function is_orphan { graph is_orphan | query_filter_chain "$@" ; }

# Keep only tasks in state PERSIST
query_declare_type             is_persistent filter
query_declare_default_producer is_persistent all
function is_persistent {
    graph filter_state PERSIST | query_filter_chain "$@"
}

# Keep only tasks which are considered projects
query_declare_type             is_project filter
query_declare_default_producer is_project all
function is_project { graph is_project | query_filter_chain "$@" ; }

# Keep only tasks which are the root of a subgraph
query_declare_type             is_root filter
query_declare_default_producer is_root all
function is_root { graph is_root | query_filter_chain "$@" ; }

# Keep only tasks not assigned to any context
query_declare_type             is_unassigned filter
query_declare_default_producer is_unassigned all
function is_unassigned { graph is_unassigned | query_filter_chain "$@" ; }

# Keep only waiting tasks
query_declare_type             is_waiting filter
query_declare_default_producer is_waiting all
function is_waiting { graph filter_state WAITING | query_filter_chain "$@" ; }

# adjacent incoming dependencies of input set
query_declare_type             parents filter
query_declare_default_producer parents from cur
function parents { adjacent dependencies incoming "$@" ; }

# insert parents of each incoming task id
query_declare_type             projects filter
query_declare_default_producer projects from cur
function projects { reachable dependencies incoming "$@" ; }

# insert subtasks of each incoming parent task id
query_declare_type             subtasks filter
query_declare_default_producer subtasks from cur
function subtasks { reachable dependencies outgoing "$@" ; }

# keep only nodes whose contents matches the given *pattern*.
#
# tbd: make this more configurable
query_declare_type             search filter
query_declare_default_producer search all
function search {
    local pattern="$1"; shift
    local id
    while IFS="" read -r id; do
	if graph_datum contents read "${id}" | grep -q "${pattern}" -; then
	    echo "${id}"
	fi
    done | query_filter_chain "$@"
}

## Binary queries *************************************************************

query_declare_type             union binop query
query_declare_default_producer union null
function union {
    local -a canonical
    local -a query
    local -a consumer

    if ! query_split_consumer "$@"
    then
	query=( "$@" )
    fi

    test -z "${query[*]}" && error "union must have RHS query"

    if query_canonicalize "${query[@]}"
    then
	query=( "${canonical[@]}" )
    fi

    if test -z "${consumer[*]}"
    then
	graph union <("${query[@]}")
    else
	graph union <("${query[@]}") | "${consumer[@]}"
    fi
}

## Formatters *****************************************************************

BUCKET_OPTS='--union|--subtract|--intersect|--noempty'

# print the path to the given datum for each node in the input set
query_declare_type             get formatter datum
query_declare_default_producer get all
function get {
    if test -z "$1"
    then
	local datum="contents"
    else
	local datum="$1"
	shift
    fi
    end_filter_chain "$@"
    map graph_datum "${datum}" read
}

# dotfile export for graphviz
query_declare_type             dot formatter
query_declare_default_producer dot all
function dot {
    end_filter_chain "$@"
    graph dot
}

# select nodes from input set to be placed into the given bucket
query_declare_type             goto selection "${BUCKET_OPTS}" bucket
query_declare_default_producer goto all
function goto {
    forbid_preview

    case "$1" in
	--*) local -r opt="$1"; shift;;
	*)   local -r opt="--noempty";;
    esac
    
    echo "$@"
    local bucket="$1"
    shift

    end_filter_chain "$@"
    choose into "${opt}" "${bucket}"
}

# Add node ids to the named bucket
#
# By default, the new contents replace the old contents. Give `--union`
# is this is undesired.
query_declare_type             into selection "${BUCKET_OPTS}" bucket
query_declare_default_producer into null
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
    __into_delete_empty
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

function __into_delete_empty {
    find "${BUCKET_DIR}" -maxdepth 1 -mindepth 1 -empty -delete
}

# Print a one-line summary for each task id
query_declare_type             summarize formatter
query_declare_default_producer summarize inbox
function summarize {
    end_filter_chain "$@"
    map task_summary
}

# tree expansion of project rooted at the given node for given edge set and direction.
#
# tree filters can be chained onto this, but not graph filters
query_declare_type             tree formatter
query_declare_default_producer tree inbox
function tree { graph expand "$1" "$2" | __tree_indent "$@" ; }

function __tree_indent {
    local marker='  '

    local depth
    while IFS="" read -r id depth; do
	printf "%s %7s" "${id}" "$(task_state read "${id}")"

	# indent the line.
	for i in $(seq $(("${depth}"))); do
	    echo -n "${marker}"
	done

	printf " $(task_gloss "${id}")\n"
    done
}


## Updates ********************************************************************

# Reactivate each task id
query_declare_type             activate update
query_declare_default_producer activate from target
function activate {
    forbid_preview
    end_filter_chain "$@"
    map task_activate
    database_commit "${SAVED_ARGV}"
}

# Complete each task id
query_declare_type             complete update
query_declare_default_producer complete from target
function complete {
    forbid_preview
    end_filter_chain "$@"
    map task_complete
    database_commit "${SAVED_ARGV}"
}

# Defer each task id
query_declare_type             defer update
query_declare_default_producer defer from target
function defer {
    forbid_preview
    end_filter_chain "$@"
    map task_defer
    database_commit "${SAVED_ARGV}"
}

# drop each task in the input set
query_declare_type             drop update
query_declare_default_producer drop from target
function drop {
    forbid_preview
    end_filter_chain "$@"
    map task_drop
    database_commit "${SAVED_ARGV}"
}

# edit the contents of node in the input set in turn.
query_declare_type             edit update
query_declare_default_producer edit from last_captured
function edit {
    forbid_preview

    # xargs -o: reopens stdin / stdout as tty in the child
    # process, allowing the editor to function even though stdin
    # is the query result.
    map graph_datum "${1:-contents}" path | xargs -o "${EDITOR}"
    database_commit "${SAVED_ARGV}"
}

# persist each task
query_declare_type             persist update
query_declare_default_producer persist from target
function persist {
    forbid_preview
    end_filter_chain "$@"
    map task_persist
    database_commit "${SAVED_ARGV}"
}

# set the given datum on the input set to the given args or stdin.
query_declare_type             set_ formatter datum
query_declare_default_producer set_ from target
query_declare_canonical_name   set_ set
function set_ {
    forbid_preview
    while IFS='' read -r id
    do
	echo "${@:2}" | graph_datum "$1" write "${id}"
    done
    database_commit "${SAVED_ARGV}"
}


# Non-query commands **********************************************************

command_declare swap bucket bucket
function swap {
    case "$#" in
	1) local a="source" b="$1";;
	2) local a="$1"     b="$2";;
	*) local a="source" b="target";;
    esac
    mv "${BUCKET_DIR}/${a}" "${BUCKET_DIR}/temp"
    mv "${BUCKET_DIR}/${b}" "${BUCKET_DIR}/${a}"
    mv "${BUCKET_DIR}/temp" "${BUCKET_DIR}/${b}"
    follow_notify
}

# add subtasks to target
command_declare add bucket bucket
function add {
    link dependencies "$@"
}

# assign tasks to contexts
command_declare assign bucket bucket
function assign {
    case "$#" in
	1) link contexts source "$1";;
	2) link contexts "$1"   "$2";;
	*) link contexts source target;;
    esac
}

# List all known buckets
function buckets {
    debug "buckets:"
    ls "${BUCKET_DIR}"
}

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
command_declare capture '--bucket|--context|--parents|--dependents:bucket'
function capture {
    forbid_preview
    while true
    do
	case "$1" in
	    -b|--bucket)
		local bucket="$2"
		shift 2
		;;
	    -c|--context)
		local contexts="$2"
		shift 2
		;;
	    -p|--parents)
		local parents="$2"
		shift 2
		;;
	    -d|--dependents)
		local dependents="$2"
		shift 2
		;;
	    *)
		break
		;;
	esac
    done

    local node="$(graph_node_create)"
    echo "NEW" | graph_datum state write "${node}"

    # no need to call "end filter chain", as we consume all arguments.
    if test -z "$*"; then
	if tty > /dev/null; then
	    graph_datum contents edit "${node}"
	else
	    debug "from stdin"
	    graph_datum contents write "${node}"
	fi
    else
	echo "$*" | graph_datum contents write "${node}"
    fi

    database_commit "${SAVED_ARGV}"

    echo "${node}" | into this

    if test -n "${bucket}"; then
	from this into "${bucket}"
    fi

    if test -n "${contexts}"; then
	assign "${contexts}" this
    fi

    if test -n "${parents}"; then
	add "${parents}" this
    fi

    if test -n "${dependents}"; then
	add this "${dependents}"
    fi

    from this into last_captured
    null into this
}

# Clobber the database
command_declare clobber
function clobber {
    forbid_preview
    database_clobber;
}

# move downward from cur
command_declare down '--union' bucket
function down {
    forbid_preview

    if test "$1" = "--union"
    then
	local -r opt="$1"
	shift
    else
	local -r opt="--noempty"
    fi

    from "$1" children goto "${opt}" "$1"
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
command_declare link edgeset bucket bucket
function link {
    forbid_preview
    local edge_set="$1"
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

# shortcut for:
# - capture into bucket
# - persist
# - set date (defaults to today)
function log {
    if test "$1" = "--date"
    then
	local -r d="$2"
	shift 2
    else
	local -r d="$(date --iso)"
    fi

    if test -n "$1"
    then
	local bucket="$1"
	shift
    else
	error "A bucket is required"
    fi

    capture -b "${bucket}" "$@"
    last_captured persist
    last_captured set_ date "${d}"
}

# remove subtasks
command_declare remove bucket bucket
function remove {
    unlink dependencies "$@"
}

# unassign tasks and contexts
command_declare unassign
function unassign {
    case "$#" in
	1) unlink contexts source "$1";;
	2) unlink contexts "$1"   "$2";;
	*) unlink contexts source target;;
    esac
}

# remove edges between sets of nodes in different buckets
command_declare unlink edgeset bucket bucket
function unlink {
    forbid_preview

    local -r edge_set="$1"
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
command_declare up '--union' bucket
function up {
    forbid_preview

    if test "$1" = "--union"
    then
	local -r opt="$1"
	shift
    else
	local -r opt="--noempty"
    fi

    from "$1" parents goto "${opt}" "$1"
}

## Live Queries ***************************************************************

# evaluate read-only queries each time the database changes
#
# the arguments are interpreted as the *initial query*.
#
# only one live query is supported per database. if called multiple
# times, the *initial query* is replaced.
command_declare follow query
function follow {
    local -r initial_query="$@"
    local -r fifo="${DATA_DIR}/follow"

    if query_find_consumer
    then
	error "live queries may not contain consumers"
    fi

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
	    "$0" "${query[@]}"

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
command_declare visualize query
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
command_declare redo
function redo {
    forbid_preview
    database_redo
}

# roll back to the state prior to execution of the last destructive
command_declare undo
function undo {
    forbid_preview
    database_undo
}

# show the current database undo
command_declare history
function history {
    # cat here to prevent pager from being invoked, which is annoying
    # within emacs. but maybe I should remove this.
    database_history | cat ;
}


# Syntax-directed completion **************************************************

# bash completion hook
#
# bind with `complete -C 'gtd suggest' gtd
# expects: COMP_LINE and COMP_POINT to be set
# expects: completion word in $2"
function suggest {
    # take the partial command up to the current cursor position...
    local slice="${COMP_LINE:0:COMP_POINT}"
    local -a cmd=( ${slice} )

    if test -n "${GTD_DEBUG_COMPLETIONS}"
    then
	local debug_file="${DATA_DIR}/compdbg"
    else
	local debug_file="/dev/null"
    fi

    echo "suggest: len   ${len}"          >> "${debug_file}"
    echo "suggest: type  ${COMP_TYPE}"    >> "${debug_file}"
    echo "suggest: line  ${COMP_LINE}"    >> "${debug_file}"
    echo "suggest: slice ${slice@Q}"      >> "${debug_file}"
    echo "suggest: point ${COMP_POINT}"   >> "${debug_file}"
    echo "suggest: \$@:  $@"              >> "${debug_file}"
    echo "suggest: cmd:  ${cmd[@]}"       >> "${debug_file}"

    # ...discarding the first word, pipe through completion algorithm
    # and then compgen.
    echo "${cmd[@]:1} " \
	| __suggest_command $(commands) 2>> "${debug_file}" \
	| __suggest_compgen "$2"        2>> "${debug_file}"
}

function __suggest_compgen {
    # read results from stdin, and then pipe through compgen
    local -a results
    debug sugest_copmgen "$@"

    while read -r result
    do
	debug result: "${result@Q}"
	results+=( "${result}" )
    done
    compgen -W "${results[*]}" -- "$1"
}

function __suggest_command {
    debug suggest_command

    local cmd
    if __suggest_next cmd "$@"
    then
	debug suggest_next: cmd: "${cmd}"

	for kind in $(command_args "${cmd}")
	do
	    debug suggest_args: kind: "${kind}"
	    __suggest_arg "${kind}" || return 1
	done

	if query_command_is_chainable_from "${cmd}"
	then
	    __suggest_command $(filters) || return 1
	fi
    fi
}

function __suggest_arg {
    debug suggest_arg "$@"
    local -r kind="$1"
    case "${kind}" in
	bucket)    __suggest_next    - $(buckets)        || return 1;;
	edgeset)   __suggest_next    - "${EDGE_DIRS[@]}" || return 1;;
	direction) __suggest_next    - incoming outgoing || return 1;;
	query)     __suggest_command $(queries)        || return 1;;
	-*:*)      __suggest_option  "${kind}"         || return 1;;
	-*)        __suggest_flags   "${kind}"         || return 1;;
   esac
}

function __suggest_option {
    debug suggest_option "$@"
    local -r flags="$(echo "$1" | cut -d ':' -f 1)"
    local -r option="$(echo "$1" | cut -d ':' -f 2)"

    if __suggest_flags "${flags}"
    then
	if __suggest_arg "${option}"
	then
	    return 0
	else
	    return 1
	fi
    else
	return 1
    fi
}


function __suggest_flags {
    debug suggest_flags
    local flag
    local -ar flags=( $( echo "$1" | tr '|' ' ') )

    if read -r -d "${IFS}" flag
    then
	case "${flag}" in
	    -*) : ;;
	    *)  return 0;;
	esac
	if __suggest_matches "${flag}" "${flags[@]}"
	then
	    return 0
	else
	    for flag in "${flags[@]}"
	    do
		echo "${flag}"
	    done
	    return 1
	fi
    fi
    return 0
}

function __suggest_next {
    case "$1" in
	-) local var;;
	*) local -n var="$1";;
    esac

    shift

    debug suggest_next "$1"

    if read -r -d "${IFS}" var
    then
	debug suggest_next: read: "${var@Q}"
	if __suggest_matches "${var}" "$@"
	then
	    debug suggest_next: matches
	    return 0
	fi
    fi

    debug suggest_next: complete
    for s in "$@"
    do
	echo "${s}"
    done
    return 1
}

function __suggest_matches {
    local -r match="$1"
    shift
    debug suggest_matches: "$1" : "$@"

    while ! test "$#" -eq 0
    do
	if test "$1" = "${match}"
	then
	    debug suggest_matches: match "${var}"
	    return 0
	fi
	shift
    done
    return 1
}			


# Main entry point ************************************************************

# save args for undo log
SAVED_ARGV="$@"

# I painted myself into a bit of a corner here, with the postfix
# syntax.
function dispatch {
    if query_command_is_valid "$1"; then
	local -a canonical
	if query_canonicalize "$@"; then
	    "${canonical[@]}"
	else
	    "$@"
	fi
    else
	"$@"
    fi
}

if test "$1" = "--debug"
then
    shift
    for name in GTD_COMMAND_ARGS GTD_QUERY_DEFAULT \
		    GTD_QUERY_TYPE \
		    GTD_QUERY_CANONICAL_NAME
    do
	declare -n arr="${name}"
	echo "${name}"
	for key in "${!arr[@]}"
	do
	    echo "    ${key} = ${arr[${key}]}"
	done
    done

    declare -a canonical
    query_canonicalize "$@"
    echo "Canonical query"
    echo "${canonical[@]}"
else
    dispatch "$@"
fi
