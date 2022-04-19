#! /usr/bin/env bash

# This is a *very* rough example script to try and import my org-mode files.
set -eo pipefail

base="$(pwd)"
declare -x GTD_DATA_DIR="${base}/org_import/gtdgraph"
TAG_DIR="${base}/org_import/tags"

function gtd         { "${base}/gtd.sh" "$@"; }
function debug       { echo "$@" >&2 ; }
function error       { debug "$@" ; exit 1 ; }

function find_or_create_tag {
    mkdir -p "${TAG_DIR}"
    local tag="$1"
    local id
    if test -f "${TAG_DIR}/${tag}"; then
	read -r id < "${TAG_DIR}/${tag}"
	echo "${id}"
    else
	debug "creating tag: ${tag}"
	id="$(gtd graph_node_create)"
	echo "${id}" > "${TAG_DIR}/${tag}"
	echo "PERSIST" | gtd task_state write "${id}"
	echo "${tag}"  | gtd task_contents write "${id}"
	gtd task_state exists    "${id}" || error "wtf?"
	gtd task_contents exists "${id}" || error "wtaf?"
	echo "${id}"
    fi
}

function process_dir {
    debug "enter: $1"
    pushd "$1" > /dev/null
    local id="$(gtd graph_node_create)"
    echo "${id}"
    debug "${id}"

    gtd task_state    write "${id}" < state
    gtd task_contents write "${id}" < contents

    gtd task_state exists    "${id}" || error "wtf?"
    gtd task_contents exists "${id}" || error "wtaf?"

    if test -e tags; then
	while read tag; do
	    debug "tag: ${tag}" >&2
	    gtd task_assign "${id}" "$(find_or_create_tag "${tag}")"
	done < tags
    fi

    ls | while read file; do
	if test -d "${file}"; then
	    local child="$(process_dir "${file}")"
	    gtd graph_edge_create "${id}" "${child}" dep
	fi
    done

    popd > /dev/null
}

function extract_headings {
    grep '^\*' "$1"
}

function begin {
    local path="$1"
    test -e && rm -rf org_import
    mkdir -p org_import
    cd org_import

    # convert org file to directory tree
    echo "creating python dir"
    ../orgtodir.py < "${path}"
    echo NEW > org_to_dir/state
    echo Root > org_to_dir/contents

    # do some sanity checks on the conversion
    extract_headings "${path}" > headings
    if ! diff -u tattle.org headings; then
	echo "Some headings were not processed. Exiting."
	exit 1
    fi

    local -i n_headings="$(wc -l < headings)"
    local -i n_subdirs="$(find org_to_dir -type d | wc -l)"
    if test "${n_headings}" -gt "${n_subdirs}"; then
	echo "Some headings are missing from the output directory. Exiting."
	echo "headings: ${n_headings}"
	echo "dirs:     ${n_subdirs}"
	exit 1
    fi
    
    gtd init
    process_dir org_to_dir
}

"$@"
