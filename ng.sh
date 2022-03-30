set -eo pipefail


DATA_DIR="./data"
NODE_DIR="${DATA_DIR}/nodes"
EDGE_DIR="${DATA_DIR}/edges"
ROOTS_DIR="${DATA_DIR}/roots"
JOURNAL="${DATA_DIR}/journal"
LASTCMD="${DATA_DIR}/lastcmd"

# check whether we are initialized.
if ! test -e "${DATA_DIR}"; then
    echo "Nodegraph is not initialized. Please run $0 init"
fi

# Print error message and exit.
function error {
    echo "$1" >&2
    exit 1
}

# try to perform the given command, logging to the journal if it
# succeeds.
function log {
    echo "$*" > "${LASTCMD}"
    "$@"
    echo "$*" >> "${JOURNAL}"
}


# On-disk Graph datastucture **************************************************


# initialize a node or an edge
function graph_init {
    local path="$1"
    mkdir -p "${path}"
    touch "${path}/contents"
    ./props.py empty > "${path}/properties"
}


# Abstract over platform UUID
function graph_gen_id {
    uuid -m
}

# print the full path to a given node
function graph_node_path {
    local id="$1"
    echo "${NODE_DIR}/$1"
}

function graph_node_contents_path {
    echo "$(graph_node_path "$1")/contents"
}

function graph_node_contents {
    cat "$(graph_node_path "$1")/contents"
}

# generate a new uuid and initialize the directory
function graph_node_create {
    local id
    local addroot=1

    if test -z "$1"; then
	id="$(graph_gen_id)"
    else
	id="$1"
	addroot=0
    fi

    if test -e "${id}"; then
	error "${id} exists."
    else
	graph_init "$(graph_node_path ${id})"
	if (return "${addroot}"); then
	    touch "${ROOTS_DIR}/${id}"
	fi
	echo "${id}"
    fi
}

# print the path to the edge connecting nodes u and v
function graph_edge_path {
    local u="$1"
    local v="$2"
    test -e "$(graph_node_path "${u}")" || return 1
    test -e "$(graph_node_path "${v}")" || return 1
    echo "${EDGE_DIR}/${u}:${v}"
}

# link two nodes
function graph_link {
    graph_init "$(graph_edge_path "$1" "$2")"
}

# break the link between two nodes
function graph_unlink {
    rm -rf "$(graph_edge_path "$1" "$2")"
}

# get the outgoing edges for a given node
function graph_node_children {
    local u="$1"
    for entry in $(ls -t "${EDGE_DIR}"); do
	case "${entry}" in
	    "${u}":*) basename "${entry}" | cut -f 2 -d ':';;
        esac
    done
}

function graph_node_parents {
    local v="$1"
    for entry in $(ls -t "${EDGE_DIR}"); do
	case "${entry}" in
	    *:"${v}") basename "${entry}" | cut -f 1 -d ':';;
        esac
    done
}

# traverse the graph depth first, starting from `root`
function graph_traverse {
    local root="$1"
    local -a stack=("${root}")
    local -A seen

    while test -n "${stack}"; do
	local cur="${stack[-1]}"
	unset stack[-1]
	if ! test -v seen["${cur}"]; then
	    seen["${cur}"]="1"
	    stack+=( $(graph_node_children "${cur}") )
	    echo "${cur}"
	fi
    done
    
}


# Commands ********************************************************************


# initialize our GTD data struture
function init {
    mkdir -p "${NODE_DIR}"
    mkdir -p "${EDGE_DIR}"
    mkdir -p "${ROOTS_DIR}"

    graph_node_create "inbox"
    graph_node_create "projects"
    graph_node_create "contexts"
    graph_node_create "someday"
}

function capture {
    local node="$(graph_node_create)"
    echo "$*" > "$(graph_node_contents_path "${node}")"
    graph_link "inbox" "${node}"
}

function inbox {
    for id in $(graph_traverse "inbox"); do
	graph_node_contents "${id}"
    done
}

function triage {
}


log "$@"
