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

