#! /usr/bin/bash

set -eo pipefail

DATA_DIR="./data"
NODE_DIR="${DATA_DIR}/nodes/"
EDGE_DIR="${DATA_DIR}/edges/"

mkdir -p "${NODE_DIR}"
mkdir -p "${EDGE_DIR}"


# Print error message and exit.
function error {
    echo "$1" >&2
    exit 1
}


# Abstract over platform UUID
function gen_id {
    uuid -m
}


# print the full path to a given node
function node_path {
    local id="$1"
    echo "${NODE_DIR}/$1"
}

# print the path to the edge connecting nodes u and v
function edge_path {
    local u="$1"
    local v="$2"
    test -e "${u}" || return 1
    test -e "${v}" || return 1
    echo "{EDGE_DIR}/${u}::{v}"
}


# TBD: how do I avoid using cat, and just perform io redir?
function update {
    cat > "$(node_path "$1")"
}

# TBD: how do I avoid using cat, and just perform io redir?
function append {
    cat >> "$(node_path "$1")"
}

# create a node
function create {
    if test -z "$1"; then
	id="$(gen_id)"
    else
	id="$1"
    fi

    if test -e "${id}"; then
	error "${id} exists."
    fi
    touch "${id}"
    echo "${id}"
}
