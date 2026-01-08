#! /usr/bin/env python3

"""This file contains optimized implementations of graph functions.

It turns out that bash is just slow at some things, particularly
command substitutions, so it proved necessary to implement some
functions in python once the database grew beyond about 700
nodes. Though potentially, leaning more on bash built-ins could have
avoided this. Or adopting a worfklow that would keep the active
portion of the database smaller.

The intention is for this file to remain relatively small, and to plug
into the outer shell-based infrastructure as much as possible.

To that end, the top-level functions in this file operate on sets of
node IDs written to stdin, and send their output directly to stdout.

This code is not well-optimized, and could certainly be improved. But
I would definitely perform some real-world benchmarks, rather than
making any assumptions. Just moving to python was really enough to
make a significant difference.
"""

import os
import sys
from itertools import pairwise

# Helper Functions #######################################################

BUCKET_DIR = os.getenv("BUCKET_DIR")

def dict_append(d, key, value):
  if not key in d:
    d[key] = []
  d[key].append(value)

def get_env_bool(var, default="1"):
  match os.getenv(var, default):
    case "1": return True
    case "0": return False
    case x:   raise ValueError(f"Invalid Bool: {x}")

def debug(*args):
  "Print all the arguments to stderr, returning the last one"
  print(*args, file=sys.stderr)
  return args[-1]

def has(datum, id):
  "True if a node has a given datum"
  return os.path.exists(
    os.path.join(os.getenv("NODE_DIR"), id, datum))

def read_ids(f=sys.stdin):
  "A generator yielding all the node IDs from `f` (defaults to `stdin`)"
  for line in f:
    yield line.strip()

def filter_nodes(predicate, *args, f=sys.stdin):
  "Yields all nodes from stdin which satisfy `predicate`."
  for node in read_ids(f):
    if predicate(*args, node):
      print(node)

def filter_nodes_with_edges(edge_set, predicate):
  """Like filter_nodes, but the predicate is also passed an edge set.

  Predicate is passed node as the first argument and a set of edges as
  the second argument.

  This is a special case to avoid reading edge sets off the disk
  more often than we need to, as many queries don't rely on them.
  """
  edges = edge_list(edge_set)
  filter_nodes(lambda node: predicate(node, edges))

def bucket_list(bucket):
  "Return the contents of the given bucket"
  try:
    buckets = os.listdir(os.path.join(BUCKET_DIR, bucket))
    buckets.sort()
    return buckets
  except OSError:
    return []

def union(rhs):
  "Return the set union of stdin and the nodes in `rhs`."
  for node in sorted(set(read_ids()) | set(read_ids(open(rhs, "r")))):
    print(node)

def difference(rhs):
  "Return the set difference of stdin and the nodes in `rhs`."
  for node in sorted(set(read_ids()) - set(read_ids(open(rhs, "r")))):
    print(node)

def nodes():
  "Return all the nodes in the database."
  for node in os.listdir(os.path.join(os.getenv("STATE_DIR"), "nodes")):
    yield node

def read_subtasks(node):
  """Get the list of subtasks for the given node.

  If the node has no subtasks, and empty list is returned.
  """
  match datum_read("subtasks", node).splitlines():
    case ["[no contents]"]: return []
    case lines:             return lines

## Edges #################################################################

def read_edges(edge_set):
  """A generator which yields the explicit edges from the database.

  I.e. it does not include "subtask" edges, which are stored under
  their respective nodes.

  Edges are represented as a tuple (u, v).
  """
  path = os.path.join(os.getenv("STATE_DIR"), edge_set)
  for e in os.listdir(path):
    match e.split(':'):
      case (u, v): yield (u, v)

def subtask_groups(node):
  """Group input into clusters of serial tasks according to file format.
  """
  ret = []
  cur_group = []

  for subtask in read_subtasks(node):
    if subtask == '':
      if cur_group:
        ret.insert(0, cur_group)
        cur_group = []
    else:
      cur_group.insert(0, subtask)

  if cur_group:
    ret.insert(0, cur_group)

  return ret

def project_subgraph(node, groups):
  """Compute subgraph for a given project node.

  Groups are parallel w/r/t each other. Each group is a linear chain
  of tasks.
  """

  for group in groups:
    match group:
      case [prev, *rest] as subtasks:
        yield (node, prev, "implicit")
        for next in rest:
          yield (prev, next, "implicit")
          prev = next
      case _:
        raise ValueError("Empty group")

def get_subtasks(node):
  """Get all the subtasks of a project.

  This will skip blank lines that separate subtask groups.
  """
  return filter(bool, read_subtasks(node))

def dependencies():
  """A generator which yields all dependency edges.

  We have to special-case "Project" nodes to get the correct
  graph.

  Confusion arises from the tension between "outline format" and the
  naive interpretation of a tree as a DAG. Outline format implies:

   1. Reverse ordering, with the first subtask considered a leaf.
   2. Implicit chaining, with a happens-before between each successive sibling.
   3. Project-level dependencies implicitly project from the first child.

  In addition, we want to allow arbitrary parallelism within the
  project, where appropriate.
  """

  # Find all the project nodes
  projects = {
    node: subtask_groups(node)
    for node in nodes()
    if has("subtasks", node)
  }

  # Emit all the project subtask edges.
  for (node, groups) in projects.items():
    yield from project_subgraph(node, groups)

  # Emit all the explicit edges in the graph, special-casing direct
  # dependencies from project nodes.
  #
  # Project-level dependencies implicitly block all the leaves of a
  # project. Direct dependencies between a project's subtasks may also
  # exist.
  #
  # The leaves of a project are just the last task in each subtask
  # group.
  for (u, v) in read_edges("dependencies"):
    if u in projects and projects[u]:
      for subtask in [g[-1] for g in projects[u]]:
        yield (subtask, v, "implicit")
    else:
      yield (u, v)

def edge_list(edge_set, subtasks=True):
  """Get the set of edges for the given edge set.

  Client code should call this function to so that project subtasks
  are handled correctly.
  """
  try:
    match edge_set:
      case "dependencies" if subtasks:
        return set(dependencies())
      case _: return set(read_edges(edge_set))
  except OSError as e:
    print(e, sys.stderr)
    return set()

def edge_touches(u, v, nodes):
  """Returns true if the given edge touches any of the given nodes."""
  return (u in nodes) or (v in nodes)

def edge_contained(u, v, nodes):
  """Returns true if the given edge is contained by the set of nodes."""
  return (u in nodes) and (v in nodes)

def node_adjacent(node, edges, direction):
  """Return all nodes adjacent to any node in the input set.

  The direction specifies whether to include incoming, outgoing, or
  both directions.
  """
  match direction:
    case "outgoing":
      for (u, v, *_) in edges:
        if node == u: yield v
    case "incoming":
      for (u, v, *_) in edges:
        if node == v: yield u
    case "all":
      for (u, v, *_) in edges:
        if   node == u: yield v
        elif node == v: yield u

def traverse(node, edges, direction, ancestors=None, seen=None):
  """Yield nodes from the subgraph rooted at `node`.

  @node      - the root node
  @edges     - the edge set to follow
  @direction - incoming, outoging, or both.
  @ancestors - the path up to the root.
  @seen      - a.k.a. the "visited" set.

  This is the general traversal, special cases of which appear below.
  """
  if node in ancestors:
    if direction == "all":
      return
    else:
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
        seen    | {node}
      )

def has_adjacent(node, edges, direction):
  """True if a node has edges in the given direction"""
  return len(list(node_adjacent(node, edges, direction))) > 0

def adjacent(edge_set, direction, subtasks=True):
  """Get directly adjacent nodes from edge set, along a given direction.
  """
  edges = edge_list(edge_set, subtasks)
  seen = set()
  for node in read_ids():
    print(node)
    for node in node_adjacent(node, edges, direction):
      seen.add(node)
  for node in seen:
    print(node)

def is_root():
  """True if a task does not block any other node."""
  filter_nodes_with_edges("dependencies", lambda n, e:
    not has_adjacent(n, e, "incoming")
  )

def is_leaf():
  """True if a task has no dependencies."""
  filter_nodes_with_edges("dependencies", lambda n, e:
    not has_adjacent(n, e, "outgoing")
  )

def is_nonterminal():
  """True if a task is neither a root nor a leaf."""
  filter_nodes_with_edges("dependencies", lambda n, e: (
    has_adjacent(n, e, "outgoing") and
    has_adjacent(n, e, "incoming")
  ))

def is_orphan():
  """True if a task has both a root and a leaf."""
  filter_nodes_with_edges("dependencies", lambda n, e: not (
    has_adjacent(n, e, "outgoing") or
    has_adjacent(n, e, "incoming")
  ))

def is_actionable():
  """Return true if a node is a task or other action item."""
  filter_state("NEW", "TODO", "WAIT", "SOMEDAY")

def is_next():
  """True if a task has no active dependencies."""
  filter_nodes_with_edges(
    "dependencies",
    lambda n, e: \
    task_state(n) in ["NEW", "TODO"] and not \
    any(task_state(o) in {"NEW", "TODO", "WAIT", "SOMEDAY"}
    for o in node_adjacent(n, e, "outgoing")
  ))

def is_project():
  """True if a task has subtask dependencies."""
  filter_nodes(lambda n: has("subtasks", n))

def is_unassigned():
  """True if a task has no incoming edges from a context."""
  filter_nodes_with_edges("contexts", lambda n, e:
    not has_adjacent(n, e, "incoming")
  )

def reachable(edges, direction):
  """Get the set of nodes reachable via `edges` along `direction`."""
  edges = edge_list(edges)
  seen = set()
  for node in read_ids():
    for subtask in traverse(node, edges, direction, set(), seen):
      if subtask not in seen:
        seen.add(subtask)
        print(subtask)

## Data #################################################################

def datum_path(datum, id):
  return os.path.join(os.getenv("NODE_DIR"), id, datum)

def datum_open(datum, id, mode="r"):
  return open(datum_path(datum, id), mode)

def datum_read(datum, id):
  """Python implementation of `graph_datum <datum> read`.

  This is here as an optimization to avoid shelling out.
  """
  cache = {}
  if (datum, id) not in cache:
    try:
      cache[(datum, id)] = datum_open(datum, id, "r").read().strip()
    except OSError:
      cache[(datum, id)] = "[no contents]"
  return cache[(datum, id)]

# re-implementations of gtd.sh functions to avoid shelling out.
def task_contents(id): return datum_read("contents", id)

def task_gloss(id):
  if has("contents", id):
    return task_contents(id).split('\n')[0]
  else:
    if id in os.listdir(BUCKET_DIR):
      return id
    else:
      return "[no contents]"

def task_state(id):    return datum_read("state", id)

def filter_state(*keep):
  filter_nodes(lambda node: task_state(node) in set(keep))

def touches(*edge_sets):
  """Show edges which touch or are contained by the input set."""
  if not edge_sets:
    edge_sets = ('contexts', 'dependencies')
  nodes = set(read_ids())
  for edge_set in edge_sets:
    for (u, v, *_) in read_edges(edge_set):
      if edge_touches(u, v, nodes):
        print(f"{u} {v} {edge_set}")

def contained(*edge_sets):
  """Calculate which edges """
  if not edge_sets:
    edge_sets = ('contexts', 'dependencies')
  nodes = set(read_ids())
  for edge_set in edge_sets:
    for (u, v, *_) in read_edges(edge_set):
      if edge_contained(u, v, nodes):
        print(f"{u} {v} {edge_set}")

## Dotfile Export ########################################################

def dot_quote(value):
  """Quote a value for dot file export.

  This implementation naively wraps the string in double quotes,
  naively escaping any internal double quotes.x
tgf  """
  quoted=value.replace("\"", "\\\"")
  return f"\"{quoted}\""

def dot_attrs(*args):
  """Given an arg-list of tuples, formats into a dot file attrlist"""
  pairs = (f"{key}={dot_quote(value)}" for key, value in args)
  attrs = ", ".join(pairs)
  return f"[{attrs}]"

def dot_subgraph(name, nodes, id=None):
  """Print a subgraph cluster in dot syntax to stdout."""
  items = ";\n".join(dot_quote(id) for id in nodes)
  print(f"""subgraph \"cluster_{id if id else name}\" {{
    label = {dot_quote(name)};
    style = rounded;
    color = grey90;
    bgcolor = grey90;
    fontname = "italic";
    fontsize = "9pt";
  """)

  for id in nodes:
    print(f"    {dot_quote(id)};")

  print("}")

def dot_state_colors(state):
  """Map task state to colors in dot synax."""
  if   state == "NEW":     return ("deeppink", "black")
  elif state == "TODO":    return ("grey95",   "black"  )
  elif state == "DONE":    return ("#CCFFCC",  "#99CC99")
  elif state == "DROPPED": return ("#FFDDDD",  "#FF9999")
  elif state == "WAITING": return ("red",      "black"  )
  elif state == "SOMEDAY": return ("#DDAAFF",  "#99AA99")
  elif state == "PERSIST": return ("green",    "black"  )
  elif state == "CONTEXT": return ("#aaFFdd",  "black"  )
  else:                    return ("grey95",   "grey50" )

def dot_node(id, node_labels={}, shape="box"):
  """Return a formatted node in dot syntax.

  Node attributes are set according to the task state.
  """
  fill, label = dot_state_colors(task_state(id))
  formatted_attrs = dot_attrs(
    ("label"  ,   task_gloss(id)),
    ("style",     "filled"),
    ("shape",     shape),
    ("color",     fill),
    ("penwidth",  "2"),
    ("fillcolor", fill),
    ("fontcolor", label),
    ("xlabel",    " ".join(node_labels.get(id, ())))
  )
  return f"{dot_quote(id)} {formatted_attrs};"

def dot_edge(u, v, style, color):
  """Return a formatted edge in dot syntax.

  Context edges are dashed, dependency edges are solid.
  """
  return f"{dot_quote(u)} -> {dot_quote(v)}" \
         f"[style={dot_quote(style)}, color={dot_quote(color)}];"

def dot_edges(edges, nodes, color):
  """Format the given edge sets to stdout"""
  for e in edges:
    match e:
      case (u, v):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "solid", color))
      case (u, v, "implicit"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "dashed", color))

def dot(*selection):
  """Read nodes from stdin, write dot syntax to stdout."""
  selected = set(selection)
  nodes = set([])
  node_labels = {}

  buckets = set(os.listdir(BUCKET_DIR))

  projects = set()

  print( "digraph {")
  print(f"rankdir  = {rankdir};")
  print( "compound = true;")
  print(f"fontname = {font};")
  print(f"bgcolor  = {dot_quote(background)};")

  for node in read_ids():
    if has("subtasks", node):
      projects.add(node)
    nodes.add(node)

  match subtasks_mode:
    case "cluster":
      for project in projects:
        subtasks = set(get_subtasks(project))
        subtasks.add(project)
        nodes |= subtasks
        dot_subgraph(task_gloss(project), subtasks, id=project)
    case "label":
      for project in projects:
        subtasks = set(get_subtasks(project))
        subtasks.add(project)
        nodes |= subtasks
        label = task_gloss(project)
        for subtask in subtasks:
          dict_append(node_labels, subtask, label)
    case "hidden":
        pass
    case invalid:
        raise ValueError(f"Invalid Mode: {invalid}")

  match bucket_mode:
    case "cluster":
      for bucket in buckets:
        contents = bucket_list(bucket)
        for node in contents:
          if node not in projects:
            nodes.add(node)
        dot_subgraph(bucket, contents)
    case "label":
      for bucket in buckets:
        contents = bucket_list(bucket)
        for node in contents:
          if not node in projects:
            nodes.add(node)
          dict_append(node_labels, node, bucket)
    case "node":
      for bucket in buckets:
        contents = bucket_list(bucket)
        print(dot_node(bucket, shape="house"))
        for c in contents:
          nodes.add(c)
          print(dot_edge(bucket, c, "dashed", "grey"))
    case "hidden":
      pass
    case invalid:
      raise ValueError(f"Invalid mode: {invalid}")

  # draw selection as a cluster, regardless of bucket style
  nodes |= selected
  dot_subgraph("Selection", selection)

  # show implicit edges from source and target
  source = bucket_list("source")
  target = bucket_list("target")
  for u in source:
    nodes.add(u)
    for v in target:
      nodes.add(v)
      print(dot_edge(u, v, "dashed", "grey"))

  for node in sorted(nodes):
    if node in projects:
      print(dot_node(node, node_labels=node_labels, shape="folder"))
    else:
      print(dot_node(node, node_labels))

  if show_deps:
    dot_edges(edge_list("dependencies"), nodes, "red")

  if show_contexts:
    dot_edges(edge_list("contexts"), nodes, "green")

  print("}")

font          =    os.getenv("GTD_GRAPH_FONT",          "monospace")
background    =    os.getenv("GTD_GRAPH_BG",            "white")
bucket_mode   =    os.getenv("GTD_GRAPH_BUCKET_MODE",   "cluster")
subtasks_mode =    os.getenv("GTD_GRAPH_SUBTASKS_MODE", "cluster")
rankdir       =    os.getenv("GTD_GRAPH_RANKDIR",       "TB")
show_contexts = get_env_bool("GTD_GRAPH_SHOW_CONTEXTS", "1")
show_deps     = get_env_bool("GTD_GRAPH_SHOW_DEPS",     "1")

if __name__ == "__main__":
  dispatch = {
    "adjacent":      adjacent,
    "from":          bucket_list,
    "reachable":     reachable,
    "union":         union,
    "filter_state":  filter_state,
    "is_actionable": is_actionable,
    "is_leaf":       is_leaf,
    "is_next":       is_next,
    "is_orphan":     is_orphan,
    "is_project":    is_project,
    "is_root":       is_root,
    "is_unassigned": is_unassigned,
    "is_nonterminal":is_nonterminal,
    "dot":           dot,
    "touches":       touches,
    "contained":     contained
  }[sys.argv[1]](*sys.argv[2:])
