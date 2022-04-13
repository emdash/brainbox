# Design Notes

gtdgraph is mostly written in shell. I try to keep the bashisms to a
minimum, but I'm don't aim for compatibility with any other shell
besides `osh`.

## Datastructure

The database is just nested subdirectories. Nodes and edges are
themselves subdirectories. Essentially, certain directories are
interpreted as sets.

- Nodes are identified by a UUID.
- Edges are identified by a pair of UUIDs, separated by a colon.
- There are separate "edge sets" for dependency edges and context edges.
- Most queries come down to a graph traversal, plus a final filter
  operation on the result set.

Everything is relative to the current working directory, like git.

- Like `git`.
- you must call `gtd.sh init` to initialize your task dir.
- There is no user-level dotfile.
- This allows you to have multiple, independent graph repositories
  with different settings for different purposes.

### Contents File

Each node contains a special file named "contents", which contains
free-form text. The first line of this file is used as a "gloss",
i.e. a one-line summary for the node.

### Birth File

Each node may contain special file named "birth" which just contains
an iso date string indicating when the given node was first
created. `capture` will create this file for you. If this file is
missing, time tracking is disabled for this node.

### Status File

In addition to the contents file, there is also a "status" file. This
contains a short string which identifies the node's status:
- `NEW`
- `TODO`
- `COMPLETE` *date*
- `WAITING`
- `DELAYED` *date*
- `SOMEDAY`
- `DROPPED` *date* [*excuse*]
- `REPEATS` [*date pattern*]

`NEW` and `TODO` indicate active nodes. The `capture` command creates
nodes with status `NEW` in order to easily filter them for later
triage.

Where *date* is iso date string, compatible with the `date` command.

`COMPLETED` indicates a node should be ignored except for time tracking
purposes.

`DELAYED` indicates a node should be ignored until after the specified
date.

`SOMEDAY` indicates a node should be ignored indefinitely, except for
Someday/Maybe reports.

`DROPPED` indicates a node should be ignored, where *excuse* is an
aribtrary string. This is for your own benefit, and may be left
blank. A lengthy excuse may be written on subsequent lines.

`REPEATS` indicates a repeating event, where *pattern* is an
expression that defines the pattern of repetition. See [Repeating
events](#Repeating_Events)

### User Files

You can store whatever files you like directly within this database,
(including symlinks, if you don't care about being the database being
self-contained), so long as they don't conflict with the files named
above.

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

## Repeating Events

Tasks with status REPEATS have their activity is controlled by a
*pattern* and a *completion set*.

The *pattern* defines the time windows during which the task may be
completed, while the *completion set* records the status for each
instance of the task.

The task is considered active *if* the current system time is within
within a completion window *and* the completion set does not contain
an entry for this instance.

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

## Archiving and History Management

Over time, processing the graph db might get quite slow... some
provision for archiving old nodes should be made.

Where this gets tricky is when a completed node gets archived, but
there might still be active edges referring to it.

We probably only want to archive nodes with no active transitive
dependencies. And we probably want to delete incoming edges when we
remove the node. But since edges can contain user data, this needs to
be handled carefully.

Another way to think about it is with history management. If every
state is preserved, then maybe we can just delete nodes to mark them
as done. This complicates reporting, in that we have to inspect the
history to determine when a node disappeared.
