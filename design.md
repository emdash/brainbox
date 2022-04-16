# Designed

GtdGraph is written in shell. I'm officially targeting bash, since
it's the most popular shell by a mile, but I would accept PRs
supporting others shells.

## Coding Style

This project is in early days, and so I have minimal style
guidelines. This is some rough notes, to be expanded on later.

- when in doubt, make it match the surrounding code
  - or whatever code you're drawing inspiration from
- minimum: single-line comment for each function not starting with a `__`
  - I haven't stuck to this religiously.
  - Not sure what style doc-comments to use, and no doc generation yet.
- in some cases, I align things on punctuation to make typos easier to spot
- avoid [shell antipatterns](tbd: oilshell link)
- embrace [the good parts](tbd: oilshell link)
- as much an exploration of shell as it is an end in and of itself

## Datastructure

GtdGraph manages a special subdirectory -- called the *data directory*
-- somewhat inspired by git, but not hidden by default.

This directory implements a textbook graph datastruacture. By
"textbook" and "graph", I mean:

> A graph, *G*, is a tuple *G* = (*V*, *E*), where:
> - *V* is a set of vertices, and
> - *E* is a set of edges, and
> - each edge is a tuple of vertices, (*u*, *v*), where:
>  - *u*, *v* are elements of *E*

In the case of GtdGraph, sets are represented as subdirectories under
the *data directory*.

In particular, *V* corresponds to the `nodes` subdirectory. There are
multiple *edge sets*. The `dependencies` set expresses task dependency
relationships. The `contexts` set expresses context membership.

### `nodes`

Nodes are identified by UUID strings. This might be overkill, but the
`uuid` package makesi t easy to generate UUIDs, and we can be
reasonably sure they're unique, even across systems.

This is referred to as the `NODE_DIR` in the source.

### Edges: `dependencies`, `contexts`

There are two sets of edges:
- `dep`: `DEPS_DIR` in the source
- `context`: `CTXT_DIR` in the source

Edges a string, containing a pair of UUIDs separated by a `:`.

This separator was chosen because it seemed easy to work with, and
doesn't feel like it needs a space. I realize this could cause issues
with some filesystems.
  
## Datum / Data

Graph nodes can contain arbitrary data. Data is plural of datum. Each
graph node datum is simply a file or directory underneath the node's
directory.

The `graph_datum` graph function is a low-level command which operates on a
single datum of a single node.

The `datum` query function is a graph filter which exposes a subset of
the datum subcommands in a filter chain.

Most data are arbitrary, there are a few special keys which support
more opinionated functions and GTD-specific functionality.

### `contents`

`contents`: datum containing summary of graph node entry

It is a plain text file whose contents is the canonical description
for the node. The first line of this file is used as the *gloss*,
which is printed by `graph_node_gloss` and `task_summary`.

**Note** I don't like this name. I am considering renaming this datum
to `description`.

### `state`
s
`state`: datum containing the node's state. This is a single-line text
file, whose contents is one of:
- `NEW`
- `TODO`
- `COMPLETE`
- `WAITING`
- `DELAYED`
- `SOMEDAY`
- `DROPPED`
- `REPEATS` *date pattern*

`NEW` and `TODO` indicate active nodes. The `capture` command creates
nodes with status `NEW` in order to easily filter them for later
triage.

Where *date pattern* is some DSL describing the pattern of repetition.

`COMPLETED` indicates a node should be ignored except for time tracking
purposes.

`DELAYED` indicates a node should be ignored until after the specified
date.

`SOMEDAY` indicates a node should be ignored indefinitely, except for
Someday/Maybe reports.

`DROPPED` indicates a node should be ignored, where *excuse* is an
aribtrary string. This is for your own benefit, and may be left
blank. A lengthy excuse may be written on subsequent lines.

#### Not Yet Implemented

`REPEATS` indicates a repeating event, where *pattern* is an
expression that defines the pattern of repetition. See [Repeating
events](#Repeating_Events)

### Data (graph-datum)

You can store whatever files you like directly within this database,
(including symlinks, if you don't care about being the database being
self-contained).

Task state is implemented using the same mechansim, so perhaps an
abstraction is neded for user data.

## How GtdGraph implements GTD

### Next Actions, Projects, and Contexts

Unlike other systems, which force you to explicitly designate
"projects" and "next actions", in GtdGraph, this level of reporting is
completely automatic.

You only have to explicitly track the relationship between your tasks
and contexts.

Your tasks form what in computer science is called a *graph*. Certain
concepts in GTD have a straight-forward expression in graph theoretic
terms.

#### Task Dependency

For example: task `A` depends on task `B`. In graph theoretic terms,
we say that there is a "directed edge" (visually drawn as an arrow)
between "nodes" `A` and `B`, or just `A -> B`.

#### Context Assignment

For example: task A is assigned to context C. In graph theoretic
terms, we say that there is "directed edge" from A to C.

#### Context Subsetting

For example: context "Safeway" is a subset of context "Grocery
Store". Every task assigned to "Safeway" is logically also assigned to
"Grocery Store".

The same context "Safeway" is also a subset of the geographic context
"South Side", so every task assigned to "Safeway" is also logically
assigned to "South Side". Both "South Side" and "Grocery Store" are
subsets of "Errands".

In dotfile syntax:
```
"South Side"    -> "Safeway;"
"Grocery Store" -> "Safeway;"
"Errands"       -> "Grocery Store;"
"Errands"       -> "South Side;"
```

We can easily "filter" tasks by context simply by performing a graph
traversal, starting with the given context node, and following only
"context" edges.

#### Next Actions, Projects, and Project Roots

Next actions are simply task nodes with no dependencies.

Projects are simply task nodes with at least one dependency.

A "project root" is a task which is not a dependency of any other task
-- which if your database is well maintained, would ideally represent
major life goals or core values.

The "Someday/Maybe" list merely consists of tasks whose status is
deferred.

# Undesigned

## Repeating Events

Tasks with status REPEATS have their activity is controlled by a
*pattern* and a *completion set*.

The *pattern* defines the time windows during which the task may be
completed, while the *completion set* records the status for each
instance of the task.

The task is considered active *if* the current system time is within
within a completion window *and* the completion set does not contain
an entry for this instance.

### Completion Set

The *completion set* is simply a text file, `completions`, containing
a line for each completed instance. Each line may a subset of the
status file syntax:
- `COMPLETED` *date*
- `DELAYED` *date*
- `DROPPED` *excuse*

#### Patterns

The pattern format is TBD.

This is a major feature which is still being designed.

At minimum we can translate from ical.

I might borrow some ideas from my old calendar app.

The key thing is that patterns define *completion windows*, not just
sets of datetimes.

I.e. each instance has both a start time where it becomes active, and
a due date, where it's considered missed if not completed by this
time.

#### Reporting

GtdGraph can generate completion reports for any recurring task or set
of tasks in a vareity of formats.

If no entry exists in the completion set for a given task intstance,
it is considered "missed". This counts the same as DROPPED.

DELAYED counts as "missed" unless a corresponding completion event
exists in the time window defined by the given *date*.

If multiple completions exist for the same time window, it's reflected
in the report but doesn't improve your "score". It's just provided for
feedback.

#### Dependencies and Repeating Tasks

There are two scenarios:
- pattern defines finite time period:
  - the parent task is blocked until the time period elapses
  - you can define a percentage goal. the parent task fails if the goal is not met.
- repeats indefinitely
  - parent task is just used for justification purposes.
  
#### Open Questions

- do dependencies of repeating tasks become themselves repeating?
  - can we have one-off dependencies which block the repeating task as a whole?
- is a repeating task like a template, which stamps out new instances of its entire subgraph?
  - do we want changes to the template to propagate to each instance?

### Checklists

These are related to repeating events, except that they're under the
user's control.

They could be implemented in terms of repeating events, or they could
be a separate notion.

- should each instance of a checklist be tracked separately
