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
from functools import reduce
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

def subtask_edge(u, v, kind, projects):
  if u in projects:
    return (f"{u}-start", v, kind)
  else:
    return (u, v, kind)

def subtask_edges(node, groups, projects):
  """Generate the edges for a set of subtask groups.

  Groups are parallel w/r/t each other. Each group is a linear chain
  of tasks. Tasks groups are assumed to be in reverse order from the
  on-disk format.

  """

  if debug_edges:
    debug("STE: project start", node, repr(task_gloss(node)))
    def debug_edge(msg, edge):
      u, v, kind = edge
      debug(f"{msg}: {repr(task_gloss(u))} -> {repr(task_gloss(v))} ({kind})")
      return edge
  else:
    def debug_edge(msg, edge):
      return edge

  start_node = f"{node}-start"

  if not groups:
    yield debug_edge("STE: empty", (node, start_node, "leaf"))

  for (i, group) in enumerate(groups):
    if debug_edges:
      debug(f"STE: group({i})")
    match group:
      case []:
        yield debug_edge("STE: empty", (node, start_node, "leaf"))
      case [single]:
        yield debug_edge("STE: single", (node, single, "subtask"))
        yield debug_edge("STE: single", subtask_edge(single, start_node, "leaf", projects))
      case [prev, *rest] as subtasks:
        yield debug_edge("STE: chain start", (node, prev, "subtask"))
        for next in rest:
          yield debug_edge("STE: chain link", subtask_edge(prev, next, "sibling", projects))
          prev = next
        yield debug_edge("STE: end chain", subtask_edge(prev, start_node, "leaf", projects))
      case wtf:
        debug("STE: wtf", wtf)

  if debug_edges:
    debug("STE: project end", node, repr(task_gloss(node)))

def get_subtasks(node):
  """Get all the subtasks of a project.

  This will skip blank lines that separate subtask groups.
  """
  return filter(bool, read_subtasks(node))

def is_start_node(node):
  """True if a node id identifies a virtual start node."""
  return node.endswith("-start")

def project_subgraph(projects):
  """Construct the intermediate project task graph.

  This is the union of all subtask edges and all the explicit eges,
  with project-level dependencies blocking the project
  start node.
  """

  for (node, groups) in projects.items():
    yield from subtask_edges(node, groups, projects)

  for (u, v) in read_edges("dependencies"):
    yield subtask_edge(u, v, "explicit", projects)

def merge_start_nodes_iter(edges):
  """Remove one layer of virtual nodes, preserving connectivity.
  """

  edges = set(edges)
  outgoing = adjacency_list(edges)
  incoming = adjacency_list(flipped(edges))
  empty = set()

  for (u, v, *rest) in edges:
    us = incoming.get(u, empty) if is_start_node(u) else {u}
    vs = outgoing.get(v, empty) if is_start_node(v) else {v}
    for u in us:
      for v in vs:
        if u != v:
          yield (u, v, *rest)

def merge_start_nodes(edges):
  recurse = False
  ret = set(merge_start_nodes_iter(edges))

  if any((is_start_node(u) or is_start_node(v) for (u, v, *_) in ret)):
    yield from merge_start_nodes(ret)
  else:
    yield from iter(ret)

def dependencies(show_virtual=False):
  """A generator which yields all dependency edges.

  We have to special-case "Project" nodes to get the correct
  graph.

  Complexity arises from the "outline format" of the substasks file
  and the naive interpretation of a tree as an explicit DAG. Outline
  format implies:

   1. Reverse ordering, with the first subtask in a group considered a leaf.
   2. Implicit chaining, with each successive sibling depending on the previous.
   3. Project-level dependencies implicitly block project leaves.

  This requires a multi-pass approach. The first pass constructs an
  incomplete project dag from the subtasks file for each
  project. During this pass, we in insert virtual start nodes which
  implicitly block the leaves of each project.

  We then process the explicit edges of the graph, adjusting any
  project-level dependencies to block to the virtual start node,
  rather than the project node itself.

  Finally, the virtual nodes are removed by merging edges with their
  neighbors. We could skip this step, but this breaks the invariant
  that node IDs always refer to a valid path in the DB, resulting in
  numerous downstream issues.

  Earlier approaches were simpler, but incorrectly treated
  project-level dependencies as leaves in some cases. The intention is
  that as a task expands into a project, any explicit dependencies it
  might have continue to depend on the task as a whole, including its
  transitive dependencies.

  """

  # Find all the project nodes
  projects = {
    node: subtask_groups(node)
    for node in nodes()
    if has("subtasks", node)
  }

  if show_virtual:
    yield from project_subgraph(projects)
  else:
    yield from merge_start_nodes(project_subgraph(projects))

def edge_list(edge_set, subtasks=True, show_virtual=False):
  """Get the set of edges for the given edge set.

  Client code should call this function to so that project subtasks
  are handled correctly.
  """
  try:
    match edge_set:
      case "dependencies" if subtasks:
        return set(dependencies(show_virtual))
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

# XXX: this doesn't work for scheduled dependencies
# because the task state doesn't change.
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

def flipped(edges):
  """Return the reverse graph, with all edges flipped."""
  for (u, v, *rest) in edges:
    yield (v, u, *rest)

def adjacency_list(edges):
  """Build forward edge adjacency list."""
  ret = {id: set() for id in nodes()}
  for (u, v, *rest) in edges:
    if u not in ret:
      ret[u] = set()
    ret[u].add(v)
  return ret

def reachability_set(edges, nodes, mem=None):
  """Return the reachability set for the given node."""
  adj = adjacency_list(edges)
  mem = mem if mem is not None else {}
  empty = set()

  def rec(n):
    if n not in mem:
      mem[n] = {n}
      for a in adj.get(n, empty):
        mem[n] |= rec(a)
    return mem[n]

  return reduce(set.__ior__, (rec(n) for n in nodes))

def reachable_from(edges, direction, *nodes):
  """Keep nodes reachable via `edges` along `direction` from the given set of nodes."""

  match direction:
    case "outgoing": edges = edge_list(edges)
    case "incoming": edges = flipped(edge_list(edges))
    case invalid: raise ValueError(f"{invalid} is not one of incoming or outgoing")

  reachable = reachability_set(edges, nodes)
  filter_nodes(lambda n: n in reachable)

def reachable(edges, direction):
  """Expand the incoming node set to include nodes reachable from the input set."""
  match direction:
    case "outgoing": edges = edge_list(edges)
    case "incoming": edges = flipped(edge_list(edges))
    case invalid: raise ValueError(f"{invalid} is not one of incoming or outgoing")

  nodes = set(read_ids())
  for node in reachability_set(edges, nodes):
    print(node)

def dangling_contexts():
  """List nodes still linked to deleted nodes."""
  existing = set(nodes())
  for (u, v, *rest) in edge_list("contexts"):
    match (u not in existing, v not in existing):
      case (True, False): print(v)
      case (False, True): print(u)

def dangling_subtasks(*args):
  """Keep nodes which have subtasks referring to deleted nodes."""
  existing = set(nodes())

  match args:
    case []:
      filter_nodes(
        lambda node:
        any(st not in existing for st in get_subtasks(node))
      )
    case ["edges"]:
      for node in read_ids():
        for st in get_subtasks(node):
          if st not in existing:
            print(f"{node}:{st}")

def dangling(*args):
  match args:
    case ["subtasks", *rest]: return dangling_subtasks(*rest)
    case ["contexts", *rest]: return dangling_contexts(*rest)

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
def task_contents(id):
  return datum_read("contents", id)

def task_gloss(ref):
  def gloss(id):
    if has("contents", id):
      return task_contents(id).split('\n')[0]
    else:
      if id in os.listdir(BUCKET_DIR):
        return id
      else:
        return "[no contents]"

  match ref.split("-start"):
    case [id, '']: return gloss(id) + "\nΦ"
    case [id]:     return gloss(id)

def task_state(id):
  return datum_read("state", id)

def filter_state(*keep):
  filter_nodes(lambda node: task_state(node) in set(keep))

def touches(*edge_sets):
  """Show edges which touch or are contained by the input set."""
  if not edge_sets:
    edge_sets = ('contexts', 'dependencies')
  nodes = set(read_ids())
  for edge_set in edge_sets:
    for (u, v, *_) in edge_list(edge_set):
      if edge_touches(u, v, nodes):
        print(f"{u} {v} {edge_set}")

def contained(*edge_sets):
  """Calculate which edges """
  if not edge_sets:
    edge_sets = ('contexts', 'dependencies')
  nodes = set(read_ids())
  for edge_set in edge_sets:
    for (u, v, *_) in edge_list(edge_set):
      if edge_contained(u, v, nodes):
        print(f"{u} {v} {edge_set}")

def summary(*args):
  match args:
    case []:                delimiter = ' '
    case ["-d", delimiter]: pass

  for id in read_ids():
    print(f"{id}{delimiter}{task_state(id):7s}{delimiter}{task_gloss(id)}")

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
  match state:
    case "NEW":     return ("deeppink", "black"  )
    case "TODO":    return ("grey95",   "black"  )
    case "DONE":    return ("#CCFFCC",  "#99CC99")
    case "DROPPED": return ("#FFDDDD",  "#FF9999")
    case "WAITING": return ("red",      "black"  )
    case "SOMEDAY": return ("#DDAAFF",  "black"  )
    case "INFO":    return ("gold",     "black"  )
    case "FOCUS":   return ("green",    "black"  )
    case "CONTEXT": return ("#aaFFdd",  "black"  )
    case _:         return ("grey95",   "grey50" )


def dot_node(id, shape="box"):
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
    ("fontcolor", label)
  )
  return f"{dot_quote(id)} {formatted_attrs};"

def dot_edge(u, v, style, color, arrow="normal"):
  """Return a formatted edge in dot syntax.

  Context edges are dashed, dependency edges are solid.
  """
  return f"{dot_quote(u)} -> {dot_quote(v)}" \
         f"[style={dot_quote(style)}, color={dot_quote(color)}, arrowhead={arrow}];"

def dot_edges(edges, nodes, color):
  """Format the given edge sets to stdout"""
  for e in sorted(edges):
    match e:
      case (u, v) | (u, v, "explicit"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "solid", color))
      case (u, v, "subtask"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "dashed", color))
      case (u, v, "leaf"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "dashed", color, "empty"))
      case (u, v, "sibling"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "dashed", color, "odot"))
      case (u, v, "suspect"):
        if edge_contained(u, v, nodes):
          print(dot_edge(u, v, "dashed", color, "odiamond"))

def dot(*selection):
  """Read nodes from stdin, write dot syntax to stdout."""
  selected = set(selection)
  nodes = set([])
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
      if show_virtual:
        nodes.add(f"{node}-start")
    nodes.add(node)


  for bucket in buckets:
    contents = bucket_list(bucket)
    print(dot_node(bucket, shape="house"))
    for c in contents:
      nodes.add(c)
      print(dot_edge(bucket, c, "dashed", "grey"))

  nodes |= selected

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
      print(dot_node(node, shape="folder"))
    elif is_start_node(node):
      print(dot_node(node, shape="cds"))
    else:
      print(dot_node(node))

  if show_deps:
    dot_edges(
      edge_list(
        "dependencies",
        show_subtasks,
        show_virtual
      ),
      nodes,
      "red"
    )

  if show_contexts:
    dot_edges(edge_list("contexts"), nodes, "green")

  # draw selection as a cluster, regardless of bucket style
  dot_subgraph("Selection", selection)

  print("}")

font           =    os.getenv("GTD_GRAPH_FONT",          "monospace")
background     =    os.getenv("GTD_GRAPH_BG",            "white")
rankdir        =    os.getenv("GTD_GRAPH_RANKDIR",       "TB")
show_contexts  = get_env_bool("GTD_GRAPH_SHOW_CONTEXTS", "1")
show_deps      = get_env_bool("GTD_GRAPH_SHOW_DEPS",     "1")
show_virtual   = get_env_bool("GTD_GRAPH_SHOW_VIRTUAL",  "1")
show_subtasks  = get_env_bool("GTD_GRAPH_SHOW_SUBTASKS", "1")
debug_edges    = get_env_bool("GTD_GRAPH_DEBUG_EDGES",   "0")

def printall(f):
  def printall_(*args):
    for i in f(*args):
      print(i)
  return printall_

if __name__ == "__main__":
  dispatch = {
    "adjacent":       adjacent,
    "from":           bucket_list,
    "reachable":      reachable,
    "reachable_from": reachable_from,
    "union":          union,
    "filter_state":   filter_state,
    "is_leaf":        is_leaf,
    "is_next":        is_next,
    "is_orphan":      is_orphan,
    "is_project":     is_project,
    "is_root":        is_root,
    "is_unassigned":  is_unassigned,
    "is_nonterminal": is_nonterminal,
    "dot":            dot,
    "touches":        touches,
    "contained":      contained,
    "summary":        summary,
    "dangling":       dangling,
    "dependencies":   printall(lambda *unused: dependencies(False))
  }[sys.argv[1]](*sys.argv[2:])
