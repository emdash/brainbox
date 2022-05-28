#! /usr/bin/env python3


import os
import sys


# Helper Functions #######################################################


def read_ids(f=sys.stdin):
    for line in f:
        yield line.strip()

def filter(predicate):
    for node in read_ids():
        if predicate(node):
            print(node)

def bucket_list(bucket):
    bucket_dir = os.path.join(os.getenv("BUCKET_DIR"), bucket)
    try:
        return os.listdir(bucket_dir)
    except OSError:
        return []

def union(lhs, rhs):
    for node in set(read_ids(open(lhs, "r"))) | set(read_ids(open(rhs, "r"))):
        print(node)


## Edges #################################################################


def edge_list(edge_set):
    try:
        path = os.path.join(os.getenv("STATE_DIR"), edge_set)
        ret = {
            tuple(edge.split(':'))
            for edge in os.listdir(path)
            if ':' in edge
        }
        return ret
    except OSError:
        return set()

def edge_touches(u, v, nodes):
    return (u in nodes) and (v in nodes)

def node_adjacent(node, edges, direction):
    if direction == "outgoing":
        for (u, v) in edges:
            if node == u: yield v
    elif direction == "incoming":
        for (u, v) in edges:
            if node == v: yield u

def traverse(node, edges, direction, ancestors=set(), seen=set()):
    if node in ancestors:
        print("Graph contains a cycle", file=sys.stderr)
        exit(1)

    if node not in seen:
        yield node
        for adj in node_adjacent(node, edges, direction):
            yield from traverse(
                adj,
                edges,
                direction,
                ancestors | {node},
                seen      | {node})

def expand(node, edges, direction, ancestors, depth):
    if node in ancestors:
        print("Graph contains a cycle", file=sys.stderr)
        exit(1)
    print(node, depth)
    for adj in node_adjacent(node, edges, direction):
        expand(adj, edges, direction, ancestors | {node}, depth + 1)

def filter_edges(edge_set, predicate):
    edges = edge_list(edge_set)
    filter(lambda node: predicate(node, edges))

def has_adjacent(node, edges, direction):
    return len(list(node_adjacent(node, edges, direction))) > 0

def adjacent(edge_set, direction):
    edges = edge_list(edge_set)
    seen = set()
    for node in read_ids():
        print (node)
        for node in node_adjacent(node, edges, direction):
            if not node in seen:
                seen.add(node)
                print(node)

def is_root():
    filter_edges("dependencies", lambda n, e: not has_adjacent(n, e, "incoming"))

def is_leaf():
    filter_edges("dependencies", lambda n, e: not has_adjacent(n, e, "outgoing"))

def is_project():
    filter_edges("dependencies", lambda n, e:
                 has_adjacent(n, e, "incoming") and
                 has_adjacent(n, e, "outgoing"))

def is_unassigned():
    filter_edges("contexts", lambda n, e: not has_adjacent(n, e, "incoming"))

def is_context():
    filter_edges("contexts", lambda n, e: has_adjacent(n, e, "outgoing"))

def reachable(edges, direction):
    edges = edge_list(edges)
    seen = set()

    for node in read_ids():
        for subtask in traverse(node, edges, direction, set(), seen):
            if subtask not in seen:
                seen.add(subtask)
                print(subtask)

## Data #################################################################


def datum_read(datum, id):
    cache = {}
    if (datum, id) not in cache:
        try:
            path = os.path.join(os.getenv("NODE_DIR"), id, datum)
            cache[(datum, id)]=open(path, "r").read().strip()
        except OSError:
            cache[(datum, id)]="[no contents]"
    return cache[(datum, id)]
 
def task_contents(id): return datum_read("contents", id)
def task_gloss(id):    return task_contents(id).split('\n')[0]
def task_state(id):    return datum_read("state", id)

def filter_state(*keep):
    keep_set = set(keep)
    filter(lambda node: task_state(node) in keep_set)


## Dotfile Export ########################################################


def dot_quote(value):
    quoted=value.replace("\"", "\\\"")
    return f"\"{quoted}\""

def dot_attrs(*args):
    pairs = (f"{key}={dot_quote(value)}" for key, value in args)
    attrs = ", ".join(pairs)
    return f"[{attrs}]"

def dot_bucket(name):
    items = "\n".join(dot_quote(id) for id in bucket_list(name))
    print(
          f"""subgraph \"cluster_{name}\" {{ 
          label = {dot_quote(name)};
          style = rounded;
          color = grey90;
          bgcolor = grey90;
          fontname = "italic";
          fontsize = "9pt"
          {items}}}
          """
    )
    
def dot_state_colors(state):
    if   state == "NEW":     return ("deeppink", "black")
    elif state == "TODO":    return ("grey95",   "black"  )
    elif state == "DONE":    return ("#CCFFCC",  "#99CC99")
    elif state == "DROPPED": return ("#FFDDDD",  "#FF9999")
    elif state == "WAITING": return ("red",      "black"  )
    elif state == "SOMEDAY": return ("#DDAAFF",  "#99AA99")
    elif state == "PERSIST": return ("green",    "black"  )
    else:                    return ("grey95",   "grey50" )

def dot_node(id):
    fill, label = dot_state_colors(task_state(id))
    formatted_attrs = dot_attrs(
        ("label",     task_gloss(id)),
        ("style",     "filled"),
        ("shape",     "box"),
        ("color",     fill),
        ("penwidth",  "2"),
        ("fillcolor", fill),
        ("fontcolor", label),
    )
    return f"{dot_quote(id)} {formatted_attrs};"

def dot_edge(u, v, style):
    return f"{dot_quote(u)} -> {dot_quote(v)} [style={dot_quote(style)}];"

def dot_edges(edges, nodes, style):

    for (u, v) in edge_list(edges):
        if edge_touches(u, v, nodes):
            print(dot_edge(u, v, style))

def dot():
    nodes = set([])

    print("digraph {")
    print("rankdir = LR;")
    print("fontname = monospace;")

    for line in sys.stdin:
        id = line.strip()
        print(dot_node(id))
        nodes.add(id)

    dot_edges("dependencies", nodes, "solid")
    dot_edges("contexts", nodes, "dashed")

    dot_bucket("source")
    dot_bucket("dest")
    dot_bucket("target")
    dot_bucket("cur")

    print("}")
    


if __name__ == "__main__":
    dispatch = {
        "from":          bucket_list,
        "adjacent":      adjacent,
        "reachable":     reachable,
        "union":         union,
        "filter_state":  filter_state,
        "is_context":    is_context,
        "is_leaf":       is_leaf,
        "is_project":    is_project,
        "is_root":       is_root,
        "is_unassigned": is_unassigned,
        "dot":           dot
    }[sys.argv[1]](*sys.argv[2:])
