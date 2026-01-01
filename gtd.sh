#! /usr/bin/env bash

# Initialization **************************************************************

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
EDGE_DIRS=("dependencies" "contexts")

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

# Print all arguments to stdout, one per line.
function splat {
    for id in "${@}"
    do
        echo "${id}"
    done
}

# Invoke a command with arguments from stdin, one per line.
#
# Example:
#   $ seq 10 | apply echo foo
#   foo 1 2 3 4 5 6 7 8 9 10
function apply {
    declare -a args
    readarray -t args
    "${@}" "${args[@]}"
}

# Menu System *****************************************************************

# Helper for creating fzf bindings
#
# key     - fzf-compatible key spec
# help    - text to show in the help menu
# action  - fzf-compatible action to be bound
# [extra] - optional additional actions to be bound
function fzf_bind_action {
    local key="${1}"
    local help="${2}"
    shift 2
    local actions="$(splat "${@}" | paste -sd '+')"
    echo "${key}|${help}|${actions}"
}

# Helper to create execution bindings.
#
# The `cmd` argument is wrapped in `execute(...)`, and any remaining
# arguments are interpreted as extra actions to be performed
# (e.g. "up" or "down").
#
# You can bind any command you want, but it must be a string. To bind
# an internal command, prefix the string with "$0". Because the
# command must be a single string, you need to properly escape any
# shell variables. Since escaping is notoriously error-prone, it's
# recommended to pass values via the environment instead.
function fzf_bind_exec {
    local key="${1}"
    local help="${2}"
    local cmd="${3}"
    shift 3
    fzf_bind_action "${key}" "${help}" "execute(${cmd})" "${@}"
}

# Helper to create execution bindings.
#
# Exactly like `fzf_bind_exec`, but wraps with `execute-silent` to
# reduce visual flicker with non-interactive commands.
function fzf_bind_sexec {
    local key="${1}"
    local help="${2}"
    local cmd="${3}"
    shift 3
    fzf_bind_action "${key}" "${help}" "execute-silent(${cmd})" "${@}"
}

# Convert a list of bindings into the FZF binding string.
#
# Bindings are passed one-per-line on stdin, each of which should be
# the output of an `fzf_bind`-family function.
function fzf_bind {
    while IFS='|' read key _ action
    do
        echo "${key}:${action}"
    done | paste -sd ','
}

# Convert a list of bindings to the FZF header string.
#
# This first agument is used as the header label, followed by the
# table of key bindings read from stdin.
function fzf_help {
    if test -v COLUMNS
    then
        local columns="${COLUMNS}"
    else
        read columns < <(tput cols)
    fi
    local -r width="$(( ("${columns}" / 2 ) ))"
    echo "${1}"
    while IFS='|' read key help _
    do
      echo "${key}|${help}"
    done | tabulate -f tsv -s '\|'
}

# Display an interactive menu using FZF.
#
# header      - header, or title of the menu.
# bindings_fn - function which prints a list of bindings on its stdout.
# reload_fn   - function which loads the menu contents.
# ...         - remaining arguments are forwarded to FZF.
function fzf_menu {
    local -r header="${1}"
    local -r bindings_fn="${2}"
    local -r load_fn="${3}"
    shift 3
    "${load_fn}" | fzf \
       --style=full \
       --layout=reverse \
       --no-input \
       --cycle \
       --header="$("${bindings_fn}" | fzf_help "${header}")" \
       --bind="$("${bindings_fn}" | fzf_bind)" \
       "${@}"
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
	yes) rm -r "${DATA_DIR}";;
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
	rm -r "${DATA_DIR}/undo_stack"
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
}

# revert any uncommitted changes
function database_revert {
    database_git reset --hard HEAD
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

# Preferences and Settings ****************************************************

# Read or write global preference settings.
#
# Preferences are stored in a subdirectory under `DATA_DIR`, rather
# than `STATE_DIR`, and therefore ephemeral. They should not be used
# for the user's primary data, but for application state that must be
# mutable across process boundaries. This comes up often in shell
# programming.
#
# Usage:
# prefs path       <path>
# prefs read       <path> [<default>]`
# prefs write [-a] <path> [<value>]
# prefs clobber    <path>
#
# @cmd      - `read` or `write`
# @path     - a relative path to the preferences file in question
#             e.g. `"nav/mode"`.
# @default  - the value to return if no value exists.
# @value    - the value to write if given as an argument.
#
# Without a default, read will fail if the given preference doesn't
# exist. Without a value, write expects the value on stdin.
function prefs {
    local -r cmd="${1}"
    # it's technically possible to avoid uses of cat here, but it
    # involves manipulating global file descriptors, and feels like a
    # bad idea. `cat` seems like the least bad options here, despite
    # it being technically not needed. these
    case "${1}" in
        path)
            local -r path="${DATA_DIR}/prefs/${2}"
            echo "${path}"
            ;;
        read)
            local -r path="${DATA_DIR}/prefs/${2}"
            if test -e "${path}"
            then
                cat "${path}"
            else
                if test -v 3
                then
                    echo "${3}"
                else
                    return 1
                fi
            fi
            ;;
        write)
            case "${2}" in
                -a) local -r append=1; shift;;
            esac

            local -r path="${DATA_DIR}/prefs/${2}"

            local dir
            read dir < <(dirname "${path}")
            mkdir -p "${dir}"
            local -r dir

            if test -v append
            then
                if test -v 3
                then
                    echo "${3}" >> "${path}"
                else
                    cat >> "${path}"
                fi
            else
                if test -v 3
                then
                    echo "${3}" > "${path}"
                else
                    cat > "${path}"
                fi
            fi
            ;;
        clobber)
            local -r path="${DATA_DIR}/prefs/${2}"
            if test -f "${path}"
            then
                rm "${path}"
            fi
            ;;
        *)
            debug "invalid subcommand: ${1}"
            exit 1;
            ;;
    esac
}

# Read a pref value, succeding iff the value is exactly "1"
function prefs_bool_test {
    local -r path="${1}"
    local value

    read value < <(
        if test -v 2
        then
            prefs read "${path}" "${2}"
        else
            prefs read "${path}"
        fi
    )

    test "${value}" = 1
}

# Toggle a boolean pref value. This always succeeds.
function prefs_bool_toggle {
    local -r path="${1}"
    local -r default="${2}"

    if prefs_bool_test "${path}" "${default}"
    then
        prefs write "${path}" 0
    else
        prefs write "${path}" 1
    fi
}

# Cycle a pref value through its variants.
#
# The zeroth variant is assumed to be the default.
function prefs_cycle {
    local -r path="${1}"
    local -a values=("${@:2}")

    local current
    read current < <(prefs read "${path}" "${values[0]}")

    read i < <(seq 0 $(("${#values[@]}" - 1)) | while read i
    do
        if test "${values["${i}"]}" = "${current}"
        then
            echo "${i}"
            break
        fi
    done)
    prefs write "${path}" "${values[$(( ("${i}" + 1) % "${#values[@]}" ))]}"
}

# Execute a command, exporting multiple preference values to the environment.
#
# Usage:
#
#  prefs_export_env (<path> <var> <default)... -- cmd (arg)...
#
# Preferences are read in triplets of:
#
#   path    - preferences path key
#   var     - the env var to export to
#   default - the default value if the preference key is absent.
#
# Separate preference declarations from the final command with --.
#
# Example: prefs_export_as 'test/foo' PREFS_TEST_FOO bar -- env | grep FOO
function prefs_export_env {
    local pref var default
    while test "$#" -gt 0
    do
        pref="${1}"
        if test "${pref}" = "--"
        then
            shift
            break
        fi
        var="${2}"
        default="${3}"
        shift 3
        read "${var}" < <(prefs read "${pref}" "${default}")
        IFS='' declare -x "${var}=${!var}"
    done
    "${@}"
}

# Declare a menu key binding that sets a preference key to a specific value
function prefs_bind {
    fzf_bind_sexec \
        "${1}" \
        "${2}" \
        "$0 prefs write ${3} ${4}" \
        "refresh-preview"
}

# Declare a menu key that toggles a boolean preference on or off.
function prefs_bind_toggle {
    fzf_bind_sexec \
        "${1}" \
        "Toggle ${2}" \
        "$0 prefs_bool_toggle ${3}" \
        "refresh-preview"
}

# Declare a menu key that cycles between multiple values.
function prefs_bind_cycle {
    local -r key="${1}"
    local -r help="${2}"
    local -r path="${3}"
    shift 3
    fzf_bind_sexec \
        "${key}" \
        "Cycle ${help}" \
        "$0 prefs_cycle ${path} ${*}" \
        "refresh-preview"
}

# Graph Database **************************************************************

# Wraps a python script which is used to "accelerate" some operations.
#
# The script can be tweaked with a number of enivronment variables,
# which we store in the prefs system, and export before executing the
# script.
function graph {
    prefs_export_env \
        "graph/font"          GTD_GRAPH_FONT          "monospace" \
        "graph/bg"            GTD_GRAPH_BG            "white"     \
        "graph/bucket_mode"   GTD_GRAPH_BUCKET_MODE   "cluster"   \
        "graph/subtasks_mode" GTD_GRAPH_SUBTASKS_MODE "cluster"   \
        "graph/rankdir"       GTD_GRAPH_RANKDIR       "TB"        \
        "graph/show_contexts" GTD_GRAPH_SHOW_CONTEXTS "1"         \
        "graph/show_deps"     GTD_GRAPH_SHOW_DEPS     "1"         \
        -- "${GTD_DIR}/components/graph.py" "$@"
}

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

# Delete the given node, and any edges which touch it.
function graph_node_delete {
    database_ensure_init
    rm -rf "$(graph_node_path "${1}")"
}

# Common keybindings for graph views
function __graph_bindings {
    prefs_bind_cycle \
      "alt-b" \
      "Bucket Mode" \
      "graph/bucket_mode" \
      "cluster" \
      "label" \
      "hidden"

    prefs_bind_cycle \
        "alt-r" \
        "Rankdir" \
        "graph/rankdir" \
        "TB" "LR" "RL" "BT"

    prefs_bind_cycle \
       "alt-s" \
       "Subtasks Mode" \
       "graph/subtasks_mode" \
       "cluster" \
       "label" \
       "hidden"

    fzf_bind_exec \
        "shift-delete" \
        "Clear Buckets" \
        "$0 buckets clear" \
        "refresh-preview"
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
    case "${1}" in
        -d|--delimiter)
            local -r sep="${2}"
            shift 2
            ;;
        *)
            local -r sep=' '
           ;;
    esac
    printf \
        "%s%c%7s%c%s\n" \
        "$1" \
        "${sep}" \
        "$(task_state read "$1")" \
        "${sep}" \
        "$(task_gloss "$1")"
}

# display extended task information.
#
# this is used for preview windows and the like.
function task_details {
    local -r width="${FZF_PREVIEW_COLUMNS:-"${LINES:-80}"}"
    local -r nodes_file="${DATA_DIR}/details/nodes"

    mkdir -p "$(dirname "${nodes_file}")"
    rm -f "${nodes_file}" || true

    task_summary "${1}"
    echo

    if prefs_bool_test "details/show_contents" 1
    then
      task_contents read "${1}" \
          | bat -f --file-name "Contents" --terminal-width "${width}"
      echo
    fi > "${DATA_DIR}/contents.txt"

    if prefs_bool_test "details/show_subtasks" 1
    then
      echo "Subtasks"
      if graph_datum subtasks exists "${1}"
      then
        # don't show ourselves as the first subtask.
        echo "${1}" \
          | subtasks \
          | head -n 1 \
          | tee -pa "${nodes_file}" \
          | summarize -d '|' \
          | cut -d '|' -f '2,3'
      fi
      echo
    fi > "${DATA_DIR}/subtasks.txt"

    if prefs_bool_test "details/show_contexts" 1
    then
      echo "Contexts"
      echo "${1}" \
        | graph adjacent contexts incoming \
        | tee -pa "${nodes_file}" \
        | tail -n +2 \
        | summarize -d '|' \
        | cut -d '|' -f '3' \
        | while read context
          do
            echo  "        ${context}"
          done
      echo
    fi > "${DATA_DIR}/contexts.txt"

    if prefs_bool_test "details/show_deps" 1
    then
      echo "Depends"
      echo "${1}" \
        | graph adjacent dependencies outgoing --nost \
        | tee -pa "${nodes_file}" \
        | tail -n +2 \
        | summarize -d '|' \
        | cut -d '|' -f '2,3'
      echo
    fi > "${DATA_DIR}/deps.txt"

    if prefs_bool_test "details/show_rdeps" 1
    then
      echo "Blocks"
      echo "${1}" \
        | graph adjacent dependencies incoming \
        | tee -pa "${nodes_file}" \
        | tail -n +2 \
        | summarize -d '|' \
        | cut -d '|' -f '2,3'
      echo
    fi > "${DATA_DIR}/rdeps.txt"

    if prefs_bool_test "details/show_buckets" 1
    then
        echo "Buckets"
        buckets show
        echo
    fi > "${DATA_DIR}/buckets.txt"

    if prefs_bool_test "details/show_graph" 1
    then
        local source
        read source < <(prefs read "details/graph_nodes" selected)
        echo "Graph Source: ${source}"
        case "${source}" in
            selected) chafa < "${nodes_file}";;
            query)    chafa < "${DATA_DIR}/query_results";;
        esac
    fi

    cat "${DATA_DIR}/contents.txt" \
        "${DATA_DIR}/contexts.txt" \
        "${DATA_DIR}/subtasks.txt" \
        "${DATA_DIR}/deps.txt" \
        "${DATA_DIR}/rdeps.txt"

    cat "${DATA_DIR}/buckets.txt"
}

function __details_bindings {
    prefs_bind_toggle "ctrl-alt-c" "Contents" "details/show_contents"
    prefs_bind_toggle "ctrl-alt-b" "Buckets"  "details/show_buckets"
    prefs_bind_toggle "ctrl-s"     "Subtasks" "details/show_subtasks"
    prefs_bind_toggle "ctrl-c"     "Contexts" "details/show_contexts"
    prefs_bind_toggle "ctrl-b"     "Blocks"   "details/show_rdeps"
    prefs_bind_toggle "ctrl-d"     "Depends"  "details/show_deps"
    prefs_bind_toggle "ctrl-g"     "Graph"    "details/show_graph"
    prefs_bind_cycle \
        "alt-g" \
        "Graph Source" \
        "details/graph_nodes" "selected" "query"
    __graph_bindings
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
    case "${1}" in
        -d|--date)
            local date="${2}"
            shift 2
            ;;
        *)
            local date
            read date < <(date -Iminute)
            ;;
    esac

    local -r id="${1}"

    if graph_datum schedule exists "${id}"
    then
        :
    else
      echo "DONE" | task_state write "${id}"
    fi

    echo "${date}" | graph_datum completed append "${id}"
}

# mark the given task as someday
function task_defer {
    echo "SOMEDAY" | task_state write "$1"
}

# mark the given node as persistent
function task_persist {
    echo "PERSIST" | task_state write "$1"
}

# mark the given node as context
function make_context_node {
    echo "CONTEXT" | task_state write "$1"
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
    case "${2}" in
        filter|producer|consumer|formatter|update|binop|selection) : ;;
        *) error "Invalid query type: ${2}" ;;
    esac

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

# output fromstdin
query_declare_type stdin producer
function stdin { cat | query_filter_chain "$@" ; }

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

# immediate neighbors of node
query_declare_type             neighbors filter
query_declare_default_producer neighbors from cur
function neighbors { adjacent dependencies all "$@" ; }

# reachable dependencies in either direction
query_declare_type             family filter
query_declare_default_producer family from cur
function family { reachable dependencies all "$@" ; }

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

# immediate context edges
query_declare_type             contexts filter
query_declare_default_producer contexts from cur
function contexts { adjacent contexts incoming "$@" ; }

# keep only the node selected by the user
query_declare_type             choose   filter '--multi|--single'
query_declare_default_producer choose   all
function choose {
    case "$1" in
       -m|--multi)  local opt="-m"; shift;;
       -s|--single) local opt=""  ; shift;;
       *)           local opt="-m"       ;;
    esac

    fzf_menu \
      "Choose Node: ${SAVED_ARGV[*]}" \
      __choose_bindings \
      __choose_items \
      -d '|' \
      ${opt} \
      --with-nth='{2} {3}' \
      --accept-nth='{1}' \
      --preview="$0 task_details {1}" \
      --bind="load:enable-search+show-input" \
      --bind="focus:execute-silent($0 splat {+1} | $0 stdin into cur)" \
    | query_filter_chain "$@"
}

function __choose_items {
    tee -p "${DATA_DIR}/query_results" | summarize -d '|'
}

function __choose_bindings {
    __details_bindings
    fzf_bind_action "ctrl-q" "Quit"      "accept"
}

# keep nodes for which the given datum exists
query_declare_type             has filter datum
query_declare_default_producer has all
function has {
    local -r datum="$1"
    shift
    filter graph_datum "${datum}" exists | query_filter_chain "$@"
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
        CONTEXT \
    | query_filter_chain "$@"
}

# Keep only completed tasks
query_declare_type             is_complete filter
query_declare_default_producer is_complete all
function is_complete { graph filter_state DONE | query_filter_chain "$@" ; }

# Show DONE / DROPPED items
query_declare_type             inactive filter
query_declare_default_producer inactive all
function inactive {
    graph filter_state DONE DROPPED | query_filter_chain "$@"
}

# Keep only context nodes
query_declare_type             is_context filter
query_declare_default_producer is_context all
function is_context { graph filter_state CONTEXT | query_filter_chain "$@" ; }

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

# Keep only tasks which are the root of a subgraph
query_declare_type             is_leaf filter
query_declare_default_producer is_leaf all
function is_leaf { graph is_leaf | query_filter_chain "$@" ; }

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
query_declare_type             blockers filter
query_declare_default_producer blockers from cur
function blockers { reachable dependencies outgoing "$@" ; }

# insert direct subtasks of each parent id
query_declare_type             subtasks filter
query_declare_default_producer subtasks from cur
function subtasks {
    while read id
    do
        if graph_datum subtasks exists "${id}"
        then
            graph_datum subtasks read "${id}"
        fi
    done | "${@}"
}

# Schedule queries ************************************************************

# invoke schedule component with preferences exported to environment.
function _schedule {
    prefs_export_env \
        "schedule/default_reminders" GTD_SCHEDULE_DEFAULT_REMINDERS '
           -10 * minute,
           -2  * hour,
           -1  * day,
           -1  * week' \
        -- "${GTD_DIR}/components/schedule.py" "$@"
}

# keep nodes which have an associated schedule
query_declare_type             is_scheduled filter
query_declare_default_producer is_scheduled all
function is_scheduled {
    _schedule is_scheduled | query_filter_chain "${@}"
}

# keep nodes which have do not have an associated schedule.
query_declare_type             is_unscheduled filter
query_declare_default_producer is_unscheduled all
function is_unscheduled {
    _schedule is_unscheduled | query_filter_chain "${@}"
}

# keep nodes which have an infinite schedule.
query_declare_type             is_scheduled filter
query_declare_default_producer is_scheduled all
function is_eternal { _schedule is_eternal ; }

# keep nodes which have a finite schedule.
query_declare_type             is_scheduled filter
query_declare_default_producer is_scheduled all
function is_temporal { _schedule is_temporal ; }

# keep nodes with schedule intervals beginning within the given time window.
query_declare_type             is_upcoming filter window
query_declare_default_producer is_upcoming all
function is_upcoming {
    declare -x GTD_DEFAULT_REMINDERS
    read GTD_DEFAULT_REMINDERS < <(
        prefs read 'schedule/default_reminders' '
        -10 * minute,
        -2  * hour,
        -1  * day,
        -1  * week
        '
    )
    case "${1}" in
        -d|--date)
            shift
            _schedule is_upcoming "${1}" | query_filter_chain "${@}"
            ;;
        *)
            _schedule is_upcoming  | query_filter_chain "${@}"
            ;;
    esac
}

# keep nodes with schedule intervals ending within the given time window.
query_declare_type             is_due filter "--window:window"
query_declare_default_producer is_due all
function is_due {
    case "${1}" in
        -w|--window)
            shift
            _schedule is_due "${1}" | query_filter_chain "${@}"
            ;;
        *)
            _shchedule is_due  | query_filter_chain "${@}"
            ;;
    esac
}

# keep nodes which are complete
query_declare_type             is_complete filter "--window:window"
query_declare_default_producer is_complete all
function is_complete {
    case "${1}" in
        -w|--window)
            shift
            _schedule is_complete "${1}" | query_filter_chain "${@}"
            ;;
        *)
            _schedule is_complete | query_filter_chain "${@}"
            ;;
    esac
}

# keep nodes which are actionable at the given timestamp
query_declare_type             is_actionable filter "--date:string"
query_declare_default_producer is_actionable all
function is_actionable {
    case "${1}" in
        -d|--date)
            shift
            _schedule is_actionable "${1}" | query_filter_chain "${@}"
            ;;
        *)
            _schedule is_actionable | query_filter_chain "${@}"
            ;;
    esac
}

# preview date patterns according to mode
query_declare_type             preview_schedule formatter "list|month|week"
query_declare_default_producer preview_schedule last_captured
function preview_schedule {
    if test -v 1
    then
        local style="${1}"
        shift
    else
        local style="week"
    fi

    end_filter_chain "${@}"

    local schedule
    local path

    while read id
    do
        read path < <(graph_datum schedule path "${id}")
        if test -f "${path}"
        then
            task_summary "${id}"
            graph_datum schedule read "${id}" | _schedule preview "${style}"
            echo
        fi
    done
}

# set the schedule for the given nodes
query_declare_type             schedule update dateset
query_declare_default_producer schedule all
function schedule {
    echo "${@}" | graph_datum schedule write
}

# remove any scheduling from the given node
query_declare_type             schedule update
query_declare_default_producer schedule all
function unschedule { filter graph_datum schedule rm ; }

# show an agenda view with the given nodes
query_declare_type             agenda formatter type window
query_declare_default_producer agenda is_actionable
function agenda {
    _schedule agenda "${@}"
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

# render graph directly to svg, printed to stdout
query_declare_type             svg formatter
query_declare_default_producer svg all
function svg {
    end_filter_chain "$@"
    graph dot | env dot -Tsvg
}

# render a project graph straight to the terminal (uses chafa).
query_declare_type             chafa formatter
query_declare_default_producer chafa from cur subtasks
function chafa {
    local -r width="${FZF_PREVIEW_COLUMNS:-"${COLUMNS:-80}"}"
    local -r height="${FZF_PREVIEW_LINES:-"${LINES:-24}"}"
    end_filter_chain "$@"
    svg | env chafa -s "${width}x$(("${height}" - 10))"
}

# select nodes from input set to be placed into the given bucket
query_declare_type             goto selection "${BUCKET_OPTS}" bucket
query_declare_default_producer goto all
function goto {
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
}

function __into_clear {
    if test -e "${BUCKET_DIR}/$1/${id}"; then
	rm -r "${BUCKET_DIR}/$1/${id}"
    fi
    mkdir -p "${BUCKET_DIR}/$1/${id}"
}

function __into_copy {
    mkdir -p "${BUCKET_DIR}/${1}"
    ls "${temp}" | while read -r id; do
	touch "${BUCKET_DIR}/$1/${id}"
    done
}

function __into_delete_empty {
    find "${BUCKET_DIR}" -maxdepth 1 -mindepth 1 -empty -delete
}

# Print a one-line summary for each task id
query_declare_type             summarize formatter --delimiter:string
query_declare_default_producer summarize inbox
function summarize {
    case "${1}" in
        -d|--delimiter)
            local -r sep="${2}"
            shift 2
            ;;
        *)
            local -r sep=' '
            ;;
    esac
    end_filter_chain "$@"
    map task_summary -d "${sep}"
}

## Updates ********************************************************************

# Reactivate each task id
query_declare_type             activate update
query_declare_default_producer activate from target
function activate {
    end_filter_chain "$@"
    map task_activate
    database_commit "${SAVED_ARGV}"
}

# Complete each task id
query_declare_type             complete update
query_declare_default_producer complete from target
function complete {
    end_filter_chain "$@"
    map task_complete
    database_commit "${SAVED_ARGV}"
}

# Defer each task id
query_declare_type             defer update
query_declare_default_producer defer from target
function defer {
    end_filter_chain "$@"
    map task_defer
    database_commit "${SAVED_ARGV}"
}

# drop each task in the input set
query_declare_type             drop update
query_declare_default_producer drop from target
function drop {
    end_filter_chain "$@"
    map task_drop
    database_commit "${SAVED_ARGV}"
}

# edit the contents of node in the input set in turn.
query_declare_type             edit update
query_declare_default_producer edit from last_captured
function edit {
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
    end_filter_chain "$@"
    map task_persist
    database_commit "${SAVED_ARGV}"
}

# make each node a context node
query_declare_type             make_context update
query_declare_default_producer make_context from target
function make_context {
    end_filter_chain "$@"
    map make_context_node
    database_commit "${SAVED_ARGV}"
}

# set the given datum on the input set to the given args or stdin.
query_declare_type             set_ formatter datum
query_declare_default_producer set_ from target
query_declare_canonical_name   set_ set
function set_ {
    case "${1}" in
        -a) shift; local -r cmd="append";;
        *)  local -r cmd="write";;
    esac
    while IFS='' read -r id
    do
	echo "${@:2}" | graph_datum "$1" "${cmd}" "${id}"
    done
    database_commit "${SAVED_ARGV}"
}

command_declare                delete bucket
function delete {
    local -r bucket="${1:-trash}"
    from "${bucket}" | graph touches | while read u v edge_set
    do
        graph_edge_delete "${u}" "${v}" "${edge_set}"
    done

    from "${bucket}" | while read node
    do
        graph_node_delete "${node}"
    done

    database_commit "${SAVED_ARGV}"
    dispatch null into "${bucket}"
}

# Non-query commands **********************************************************

command_declare swap bucket bucket
function swap {
    case "$#" in
	1) local a="source" b="$1";;
	2) local a="$1"     b="$2";;
	*) local a="source" b="target";;
    esac
    mv "${BUCKET_DIR}/${a}" "${DATA_DIR}/temp"
    mv "${BUCKET_DIR}/${b}" "${BUCKET_DIR}/${a}"
    mv "${DATA_DIR}/temp"   "${BUCKET_DIR}/${b}"
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
  if test -v 1
  then
    case "${1}" in
      clear)
        if test -v 2
        then
          # lookup find command
          rm -rv --one-file-system --preserve-root=all "${BUCKET_DIR}/${2}"
        else
          rm -rv --one-file-system --preserve-root=all "${BUCKET_DIR}"
          mkdir -p "${BUCKET_DIR}"
        fi
        ;;
      show)
        # fail if there are no buckets
        if test -s "${BUCKET_DIR}"
        then
          local tmpdir
          read tmpdir < <(mktemp -d)
          ls "${BUCKET_DIR}" | while read bucket
          do
            { echo "${bucket}"
              ls "${BUCKET_DIR}/${bucket}" \
                | summarize -d '|' \
                | cut -d '|' -f '2,3'
            } > "${tmpdir}/${bucket}"
          done
          find "${tmpdir}" \
            | tail -n +2 \
            | sort \
            | apply paste -d '^' \
            | tabulate -f plain -s '\^'
          fi
        ;;
    esac
  else
    ls "${BUCKET_DIR}"
  fi
}

# capture takes so many options they don't fit on one line
declare -a capture_args=(
    '--oneline'
    '--bucket'
    '--context'
    '--parents'
    '--dependents:bucket'
)

# Create a new task.
#
# If arguments are given, they are written as the node contents.
#
# If no arguments are given:
# - and stdin is a tty, invokes $EDITOR to create the node contents.
# - otherwise, stdin is written to the contents file.
command_declare capture "$(echo "${capture_args[@]}" | paste -sd '|'))"
function capture {
    while true
    do
	case "$1" in
            -1|--oneline)
                local oneline="1"
                shift 1
                ;;
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
            if test -v oneline
            then
                local line
                read -ep "Gloss> " line
                echo "${line}" | graph_datum contents write "${node}"
            else
	        graph_datum contents edit "${node}"
            fi
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
    database_clobber;
}

# move downward from cur
command_declare down '--union' bucket
function down {
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
    if test "$1" = "--union"
    then
	local -r opt="$1"
	shift
    else
	local -r opt="--noempty"
    fi

    from "$1" parents goto "${opt}" "$1"
}

# Project-Subtasks Editor *****************************************************

function __plan_modify {
    read path < <(graph_datum subtasks path "${SUBTASK_ID}")
    case "${1}" in
        add) all | choose >> "${path}";;
        capture)
            echo | xargs -o "$0" capture --oneline
            last_captured >> "${path}"
            ;;
        edit) echo "${2}" | edit;;
        *) "${GTD_DIR}/components/subtasks.py" "${path}" "${@}";;
    esac
}

function __plan_items {
    graph_datum subtasks read "${SUBTASK_ID}" | while read id
    do
        if test -n "${id}"
        then
            task_summary -d '|' "${id}"
        else
            echo "|--||"
        fi
    done
}

function __plan_preview {
    task_details "${SUBTASK_ID}"
}

function __plan_bindings {
    local rls="reload-sync($0 __plan_items)"
    local plm="$0 __plan_modify"
    fzf_bind_sexec  "shift-up"   "Move Up"     "${plm} up     {n}"      "${rls}" "up"
    fzf_bind_sexec  "shift-down" "Move Down"   "${plm} down   {n}"      "${rls}" "down"
    fzf_bind_sexec  "space"      "Split Group" "${plm} split  {n}"      "${rls}" "down"
    fzf_bind_sexec  "delete"     "Delete"      "${plm} delete {n}"      "${rls}"
    fzf_bind_exec   "enter"      "Edit"        "${plm} edit   {1}"      "${rls}"
    fzf_bind_exec   "a"          "Add"         "${plm} add"             "${rls}"
    fzf_bind_exec   "c"          "Capture"     "${plm} capture"         "${rls}" "last"
    fzf_bind_action "q"          "Quit"        "accept"                 "${rls}"
    fzf_bind_action "h"          "Toggle Help" "toggle-header"          "${rls}"
    fzf_bind_sexec  "focus"      ""            "echo {1} | $0 into cur"
    __details_bindings
}

command_declare plan
function plan {
    if test -v 1
    then
       export SUBTASK_ID="${1}"
    else
        declare SUBTASK_IDf
        read SUBTASK_ID < <(dispatch "${@}" choose --single)
        export SUBTASK_ID
    fi

    fzf_menu \
      "Edit Project Subtasks" \
      __plan_bindings \
      __plan_items \
      --preview="$0 __plan_preview" \
      --with-nth='{2} {3}' \
      -d '|'
}

## State management ***********************************************************

# restore the last undone command, if one exists
command_declare redo
function redo {
    database_redo
}

# roll back to the state prior to execution of the last destructive
command_declare undo
function undo {
    database_undo
}

# show the current database undo
command_declare history
function history {
    # cat here to prevent pager from being invoked, which is annoying
    # within emacs. but maybe I should remove this.
    database_history | cat ;
}

# Interactive Mode ************************************************************

## Combining multiple specialized modes into a single gui with submenus.

function __interactive_top {
    prefs read "interactive/path" | tail -n 1
}

function __interactive_push {
    prefs write -a "interactive/path" "${1}"
}

function __interactive_pop {
    local temp
    read temp < <(mktemp -p "${DATA_DIR}")
    prefs read  'interactive/path' | head -n -1 > "${temp}"
    prefs write 'interactive/path' < "${temp}"
    rm "${temp}"
}

function __interactive_path {
    prefs read 'interactive/path' | map task_gloss | paste -sd '/'
}

function __interactive_preview {
    local top mode
    read mode < <(prefs read 'interactive/mode' neighbors)

    echo "Mode: ${mode} "

    if read top < <(__interactive_top)
    then
        echo -n "Path: " ; __interactive_path
    else
        echo "Path: [Root]"
        top="${1}"
    fi

    task_details "${top}"
}

function __interactive_items {
    local top mode
    read mode   < <(prefs read 'interactive/mode' neighbors)
    if read top < <(__interactive_top)
    then
      # XXX: validate before blindly executing ${mode}
      echo "${top}" \
          | "${mode}" \
          | filter test "${top}" !=
    else
        prefs read 'interactive/query' | apply
    fi | tee -p "${DATA_DIR}/query_results" | summarize -d '|'
}

function __interactive_capture {
    echo | xargs -o "$0" capture --oneline
}

function __interactive_bucket {
    local bucket
    read bucket < <(
        buckets | fzf \
          --style=full \
          --layout=reverse \
          --cycle \
          --header="Choose Bucket" \
          --bind="enter:accept-or-print-query"
    )
    splat "${@}" | into --union "${bucket}"
}

function __interactive_node_submenu {
    local rls="reload-sync($0 __interactive_items)"
    local selected="$0 splat {+1} |"
    fzf_bind_exec  "e"         "Edit"         "${selected} $0 stdin edit"         "${rls}"
    fzf_bind_exec  "c"         "Capture"      "$0 __interactive_capture"          "${rls}"
    fzf_bind_sexec "x"         "Aassign"      "$0 assign"                         "refresh-preview"
    fzf_bind_sexec "X"         "Unassign"     "$0 unassign"                       "refresh-preview"
    fzf_bind_sexec "a"         "Activate"     "${selected} $0 stdin activate"     "${rls}"
    fzf_bind_sexec "C"         "Make Context" "${selected} $0 stdin make_context" "${rls}"
    fzf_bind_sexec "P"         "Persist"      "${selected} $0 stdin persist"      "${rls}"
    fzf_bind_sexec "delete"    "Drop"         "${selected} $0 stdin drop"         "${rls}"
}

function __interactive_nav_submenu {
    local rls="reload-sync($0 __interactive_items)"
    local setpref="$0 prefs write"
    fzf_bind_sexec  "f"         "Family"    "${setpref} 'interactive/mode' family"    "${rls}"
    fzf_bind_sexec  "n"         "Neighbors" "${setpref} 'interactive/mode' neighbors" "${rls}"
    fzf_bind_sexec  "p"         "Parents"   "${setpref} 'interactive/mode' parents"   "${rls}"
    fzf_bind_sexec  "C"         "Children"  "${setpref} 'interactive/mode' children"  "${rls}"
}

function __interactive_view_submenu {
    prefs_bind_toggle "c" "Contents" "details/show_contents"
    prefs_bind_toggle "b" "Buckets"  "details/show_buckets"
    prefs_bind_toggle "s" "Subtasks" "details/show_subtasks"
    prefs_bind_toggle "C" "Contexts" "details/show_contexts"
    prefs_bind_toggle "d" "Depends"  "details/show_deps"
    prefs_bind_toggle "D" "Blocks"   "details/show_rdeps"
    prefs_bind_toggle "g" "Graph"    "details/show_graph"
    prefs_bind_cycle \
        "G" \
        "Graph Source" \
        "details/graph_nodes" "selected" "query"

    prefs_bind_cycle \
      "B" \
      "Bucket Mode" \
      "graph/bucket_mode" \
      "cluster" \
      "label" \
      "hidden"

    prefs_bind_cycle \
        "r" \
        "Rankdir" \
        "graph/rankdir" \
        "TB" "LR" "RL" "BT"

    prefs_bind_cycle \
       "S" \
       "Subtasks Mode" \
       "graph/subtasks_mode" \
       "cluster" \
       "label" \
       "hidden"
}

function __interactive_graph_submenu {
    local rls="reload-sync($0 __interactive_items)"
    local selected="$0 splat {+1} |"
    fzf_bind_sexec "s"       "Set Source" "${selected} $0 stdin into source" "refresh-preview"
    fzf_bind_sexec "t"       "Set Target" "${selected} $0 stdin into target" "refresh-preview"
    fzf_bind_sexec "S"       "Swap"       "$0 swap source target"            "refresh-preview"
    fzf_bind_sexec "d"       "Add Dep"    "$0 add"                           "refresh-preview"
    fzf_bind_sexec "D"       "Remove Dep" "$0 add"                           "refresh-preview"
    fzf_bind_exec  "b"       "Bucket"     "$0 __interactive_bucket {+1}"     "${rls}"
}

function __interactive_bindings {
    local rls="reload-sync($0 __interactive_items)"
    fzf_bind_sexec "u"         "Undo"         "$0 undo"                           "${rls}"
    fzf_bind_sexec "U"         "Redo"         "$0 redo"                           "${rls}"
    fzf_bind_sexec  "backspace" "Move Back" "$0 __interactive_pop"                    "${rls}"
    fzf_bind_sexec  "enter"     "Goto Cur"  "$0 __interactive_push {1}"               "${rls}"
    case "$(prefs read 'interactive/menu' node)" in
        node)   __interactive_node_submenu;;
        nav)    __interactive_nav_submenu;;
        graph)  __interactive_graph_submenu;;
        view)   __interactive_view_submenu;;
    esac
    fzf_bind_action "F5" "Refresh"     "reload-sync($0 __interactive_items)"
    fzf_bind_action "?"  "Toggle Help" "toggle-header"
    fzf_bind_action "q"  "Quit"        "clear-screen" "accept"
}

# run interactive mainloop
function __interactive {
    prefs write "interactive/menu" "${1}"

    # build the tab bar according to current mode.
    local tabs
    case "${1}" in
        node)  tabs="[_ Node] [2 Nav] [3 Graph] [4 View]";;
        nav)   tabs="[1 Node] [_ Nav] [3 Graph] [4 View]";;
        graph) tabs="[1 Node] [2 Nav] [_ Graph] [4 View]";;
        view)  tabs="[1 Node] [2 Nav] [3 Graph] [_ View]";;
        *) debug "wtf" $1;;
    esac

    fzf_menu \
        "${tabs}" \
        __interactive_bindings \
        __interactive_items \
        --multi \
        --track \
        -d '|' \
        --with-nth='{2} {3}' \
        --accept-nth='{1}' \
        --preview="$0 __interactive_preview {1}" \
        --bind="1:become($0 __interactive node)" \
        --bind="2:become($0 __interactive nav)" \
        --bind="3:become($0 __interactive graph)" \
        --bind="4:become($0 __interactive view)" \
        --bind="5:reload-sync($0 __interactive items)"
}

query_declare_type             interactive formatter     "node|nav|links|graph"
query_declare_default_producer interactive all is_active
function interactive {
    prefs clobber "interactive/path"

    # save initial query results to prevent stdin from blocking.
    prefs write "interactive/query_results"
    end_filter_chain "${@}"

    # save the first part of the query so we can re-run it.
    local query
    query_split_consumer "${canonical[@]}"
    splat "${query[@]}" | prefs write "interactive/query"

    __interactive node
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

case "$1" in
    "--debug")
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
      ;;
    "--query")
        declare -a query
        read -a query < <(echo "${2}")
        dispatch "${query[@]}" "${@:3}"
        ;;
    *)
        dispatch "$@"
        ;;
esac
