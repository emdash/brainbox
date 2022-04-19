#! /usr/bin/env bash

# This is a *very* rough example script to try and import my org-mode files.
set -eo pipefail

base="$(pwd)"
declare -x GTD_DATA_DIR="${base}/org_import/gtdgraph"
declare -A tags

function gtd         { "${base}/gtd.sh" "$@"; }

function find_or_create_tag {
    if ! test -v tags["$1"]; then
	tags["${1}"]="$(gtd graph_node_create)"
    fi
    echo "${tags["${1}"]}"
}

function process_dir {
    pushd "$1" > /dev/null
    local id="$(gtd graph_node_create)"
    echo "${id}"

    gtd task_state    write "${id}" < state
    gtd task_contents write "${id}" < contents

    if test -e tags; then
	for tag in "$(cat tags)"; do
	    gtd task_assign "${id}" "$(find_or_create_tag "${tag}")"
	done
    fi

    ls | while read file; do
	if test -d "${file}"; then
	    local child="$(process_dir "${file}")"
	    gtd graph_edge_create "${id}" "${child}" dep
	fi
    done

    popd > /dev/null
}

function begin {
    test -e && rm -rf org_import
    mkdir -p org_import
    cd org_import

    echo "creating python dir"
    ../orgtodir.py
    echo NEW > org_to_dir/state
    echo Root > org_to_dir/contents

    gtd init
    process_dir org_to_dir
}

"$@"
