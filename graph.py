#! /usr/bin/env python3

import os
import sys
from itertools import pairwise

# Helper Functions #######################################################

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

def filter_nodes(predicate):
  "Yields all nodes from stdin which satisfy `predicate`."
  for node in read_ids():
    if predicate(node):
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
  bucket_dir = os.path.join(os.getenv("BUCKET_DIR"), bucket)
  try:
    return os.listdir(bucket_dir)
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
  "Return all the nodes in the database"
  for node in os.listdir(os.path.join(os.getenv("STATE_DIR"), "nodes")):
    yield node

def get_subtasks(node):
  """Get the list of subtasks for the given node.

  If the node has no subtasks, and empty list is returned.
  """
  match datum_read("subtasks", node).splitlines():
    case ["[no contents]"]: return []
    case lines:             return lines

## Edges #################################################################

def read_edges(edge_set):
  """A generator which yields the explicit edges from the database.

  Edges are represented as a tuple (u, v).
  """
  path = os.path.join(os.getenv("STATE_DIR"), edge_set)
  for e in os.listdir(path):
    match e.split(':'):
      case (u, v): yield (u, v)

def project_subgraph(node, subtasks):
  """Compute subgraph for a given project node.

  This is establishes a linear sequence of tasks with the first item
  in the list being the leaf. The node is then linked to the last item
  in the list.
  """
  subtasks.reverse()
  match subtasks:
    case ["[no contents]"]: pass
    case [first, *rest] as subtasks:
      yield (node, first)
      for (prev, next) in pairwise(subtasks):
        yield (prev, next)


def dependencies():
  """A generator which yields all dependency edges.

  We have to special-case "Project" nodes to get the correct
  graph.
  """

  # Find all the project nodes
  projects = {
    node: get_subtasks(node)
    for node in nodes()
    if has("subtasks", node)
  }

  # Emit all the project subtask edges.
  for (node, subtasks) in projects.items():
    yield from project_subgraph(node, subtasks)

  # Emit all the explicit edges in the graph, special-casing direct
  # dependencies from project nodes -- these are linked to the last
  # subtask in the project.
  for (u, v) in read_edges("dependencies"):
    if u in projects and projects[u]:
      yield (projects[u][-1], v)
    else:
      yield (u, v)

def edge_list(edge_set):
  """Get the set of edges for the given edge set.

  Client code should call this function to so that project subtasks
  are handled correctly.
  """
  try:
    match edge_set:
      case "dependencies": return set(dependencies())
      case _: return set(read_edges(edge_set))
  except OSError as e:
    print(e, sys.stderr)
    return set()

def edge_touches(u, v, nodes):
  """Returns true if the given edge touches any of the given nodes."""
  return (u in nodes) and (v in nodes)

def node_adjacent(node, edges, direction):
  """Return all nodes adjacent to any node in the input set.

  The direction specifies whether to include incoming, outgoing, or
  both directions.
  """
  match direction:
    case "outgoing":
      for (u, v) in edges:
        if node == u: yield v
    case "incoming":
      for (u, v) in edges:
        if node == v: yield u
    case "all":
      for (u, v) in edges:
        if   node == u: yield v
        elif node == v: yield u

def traverse(node, edges, direction, ancestors=set(), seen=set()):
  """A generator which recursively traverses a graph."""
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

def expand(node, edges, direction, ancestors, depth):
  """Compute the tree expansion of the subgraph rooted at node."""
  if node in ancestors:
    print("Graph contains a cycle", file=sys.stderr)
    exit(1)
  print(node, depth)
  for adj in node_adjacent(node, edges, direction):
    expand(adj, edges, direction, ancestors | {node}, depth + 1)

def has_adjacent(node, edges, direction):
  """True if a node has edges in the given direction"""
  return len(list(node_adjacent(node, edges, direction))) > 0

def adjacent(edge_set, direction):
  """Get directly adjacent nodes from edge set, along a given direction.
  """
  edges = edge_list(edge_set)
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

def is_next():
  """True if a task has no active dependencies."""
  filter_nodes_with_edges("dependencies", lambda n, e: not any(
    task_state(o) in {"NEW", "TODO"}
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

def is_context():
  """True if a node has any outging context links."""
  filter_nodes_with_edges("contexts",lambda n, e:
    has_adjacent(n, e, "outgoing")
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

def datum_read(datum, id):
  """Python implementation of `graph_datum <datum> read`.

  This is here as an optimization to avoid shelling out.
  """
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
  filter_nodes(lambda node: task_state(node) in set(keep))


def touches():
  """Calculate which edges to remove in order to remove the input set"""
  nodes = set(read_ids())
  for edge_set in ('contexts', 'dependencies'):
    for (u, v) in read_edges(edge_set):
      if edge_touches(u, v, nodes):
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
  else:                    return ("grey95",   "grey50" )

def dot_node(id):
  """Return a formatted node in dot syntax.

  Node attributes are set according to the task state.
  """
  fill, label = dot_state_colors(task_state(id))
  formatted_attrs = dot_attrs(
    ("label"  ,   task_gloss(id)),
    ("style",     "filled"),
    ("shape",     "box"),
    ("color",     fill),
    ("penwidth",  "2"),
    ("fillcolor", fill),
    ("fontcolor", label),
  )
  return f"{dot_quote(id)} {formatted_attrs};"

def dot_edge(u, v, style):
  """Return a formatted edge in dot syntax.

  Context edges are dashed, dependency edges are solid.
  """
  return f"{dot_quote(u)} -> {dot_quote(v)} [style={dot_quote(style)}];"

def dot_edges(edges, nodes, style):
  """Format the given edge sets to stdout"""
  for (u, v) in edge_list(edges):
    if edge_touches(u, v, nodes):
      print(dot_edge(u, v, style))

def dot():
  """Read nodes from stdin, write dot syntax to stdout."""
  nodes = set([])

  buckets = {
    b for b in os.listdir(os.getenv("BUCKET_DIR"))
  }

  projects = set()

  print("digraph {")
  # print("rankdir = LR;")
  print("compound = true;")
  print("fontname = monospace;")

  for node in read_ids():
    if has("subtasks", node):
      projects.add(node)
    nodes.add(node)

  for project in projects:
    subtasks = set(get_subtasks(project))
    nodes |= subtasks
    subtasks.add(project)
    dot_subgraph(task_gloss(project), subtasks, id=project)

  for bucket in buckets:
    contents = bucket_list(bucket)
    for node in contents:
      if node not in projects:
        nodes.add(node)
    dot_subgraph(bucket, contents)

  for node in nodes:
    print(dot_node(node))

  dot_edges("dependencies", nodes, "solid")
  dot_edges("contexts", nodes, "dashed")

  print("}")


if __name__ == "__main__":
  dispatch = {
    "adjacent":      adjacent,
    "from":          bucket_list,
    "reachable":     reachable,
    "union":         union,
    "filter_state":  filter_state,
    "is_context":    is_context,
    "is_leaf":       is_leaf,
    "is_next":       is_next,
    "is_orphan":     is_orphan,
    "is_project":    is_project,
    "is_root":       is_root,
    "is_unassigned": is_unassigned,
    "dot":           dot,
    "touches":       touches
  }[sys.argv[1]](*sys.argv[2:])
