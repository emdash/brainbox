# Design Overview

GtdGraph is written in shell. It uses a persistent database stored in
a subdirectory.

I'm officially targeting bash, since it's the most popular shell by a
mile, but I would accept PRs supporting others shells.

# GTD Interms of Graphs #

I'm assuming you're familiar with [*Getting Things Done*](tbd: link),
else you wouldn't have read this far.

As a brief reminder, the gtd work flow includes: **TBD** insert
infographic here.

The fundamental issue with GTD is tedium of maintaining lists of "next
actions" and sorting them into contexts. This activity cries out for
automation with digital tools.

Where most digital tools go wrong is they:
- attempt to organize tasks *hierarchically* (a.k.a. as *trees*).
- model contexts as simple *tags*

GtdGraph lets you focus on what matters most: tasks, projects,
contexts, and the relationships between them.

## Inbox

GtdGraph has a `capture` command, which lets you quickly create a task
before you forget it. Tasks created this way are automatically placed
in the NEW state.

Your *inbox* is simply the set of all tasks in the `NEW` state. When
you assign a `NEW` task to a project or context, it is automatically
placed in the TODO state.

## Next Actions, Projects, and Contexts ##

Unlike other systems, which force you to manually organize your tasks
into "projects" and "next actions", in GtdGraph, this is done
automatically.

### Task Dependency ###

For example: *task `A` depends on task `B`*.

In graph theoretic terms: *a directed edge exists between nodes `A`
and `B` in the dependency graph*.

### Context Assignment ###

For example: *task "buy milk" is assigned to the "grocery" context.*

In graph theoretic terms: *a directed edge exists between the nodes
*buy milk* and *grocery* in the context graph*.

### Context Grouping ###

For example:

> Every task in the "Safeway" context should also appear in the to
> "Grocery Store" context. "Safeway" is included in a "South Side"
> context. Both "South Side" and "Grocery Store" are included in
> "Errands".

In dotfile syntax:
```
"South Side"    -> "Safeway"
"Grocery Store" -> "Safeway"
"Errands"       -> "Grocery Store"
"Errands"       -> "South Side"
```

We can easily "filter" tasks by context simply by performing a graph
depth first traversal, starting with the given context node, and
following the edges in the context graph.

### Next Actions, Projects, and Others ###

We can automatically categorize nodes as *next actions*, *projects*
and others with a little bit of graph theory.

Projects are simply task nodes with at least one dependency.

A *next action* is a task with no dependencies that is in an
*actionable* state.

The "Someday/Maybe" list is automatically constructed from any task
placed into a *deferred* state.

In GtdGraph, *task state* is modeled as a *datum* named `state`.

### Undesigned

This section contains features I'm planning, but am unsure how best to
model.

I am focusing on basic features, so that I can start dogfooding
GtdGraph as my main task manager.

Once I dogfood GtdGraph for a while, I am confident the right design
will come to me. I'm also not above taking cues from other task
managers, like TaskWarrior.

#### Triage Workflow

A high level `triage` command is planned to streamline daily review of
your *inbox*.

#### History management (a.k.a. Undo / Redo)

Kindof an important feature, given how easy it is to accidentally
`drop` all your tasks at the moment.

History management will semantically preserve the entire state between
high level operations.

The first pass will likely be implemented on top of `git`. This way,
you get rollback and remote sync "for free", though it would not be
ideal for those who may wish to manage large files with gtdgraph.

#### Recurring Tasks

Tasks whose state transitions between *completed* and *actionable*
according to some *pattern*, *event*, or other *trigger*.

The design will depend somewhat on how history management gets
implemented, and what kinds of reporting I want to enable (progress
reports, "completion calendars", etc).

#### Checklists

These are similar to repeating tasks, but are used in a different
context. Checklists will probably be a different UI around the same
underlying mechanism as used for recurring events.

#### Review Workflow

I'm focusing on the basic functionality, but the idea is that GtdGraph
should nag you to do periodic reviews.

Daily:
- triage your inbox
- view your next actions

Weekly:
- review all your active projects

Monthly or Quarterly:
- review all your projects

Annually:
- review your roots
  - I have this vague notion that in a well-maintained database, *root
    nodes* (aka *source nodes*) ultimately correspond to your *core
    values* and *life goals*.
	- dubbed *The view from 30,00 Feet* in the GTD book.
  - if you have "too many" roots, then either it's time for some
    serious self-reflection, or perhaps you need some help getting
    organized.

#### Stalled Project Detection

Again, need to dogfood for a while to get a sense for what counts as a
*stalled* project.

Is it:
- a task which hasn't been modified in a while?
- an entire subgraph within which no node has been modified?
- any task which hasn't been completed for a while?
- what counts as "a while"?

# Code Walkthrough

Total code is ~1k lines (including comments) at time of this writing
(Sun 17 Apr 2022).

## Tests

There is a `./test.sh` script along-side the main script. It is
intended to be run from the root of the source tree.

## Database

GtdGraph stores its data under a subdirectory -- (`"${DATA_DIR}"` in
the code), in a manner similar to git.

> A graph, *G*, is a tuple *G* = (*V*, *E*), where:
> - *V* is a set of vertices, and
> - *E* is a set of edges, and
> - each edge is a tuple of vertices, (*u*, *v*), where:
>  - *u*, *v* are elements of *E*

In other words, GtdGraph is based directy on the set-theoretic notion
of graphs.  More precisely, the GtdGraph database contains multiple
graphs, sharing a common set of nodes, but with distinct sets of
edges.

GtdGraph uses shell primitives and plain old filesystem directories as
generic, persistent sets.

### `nodes` ###

The `"${NODE_DIR}"` contains an entry for each node. Each node is
identified by a unique ID (not a content hash) which remains the same
through its life.

IDs are generated by `uuid -m`, which might be overkill, but seems at
least reasonably safe from collisions.

### Edges: `dependencies`, `contexts` ###

Edges are strings, containing a pair of UUIDs separated by a `:`.

There are two sets of edges:
- `dep`: `"${DEPS_DIR}"` in the source
- `context`: `${CTXT_DIR}"` in the source
  
### Datum / Data ###

Users can associate arbitrary data with graph nodes. Data is plural of
datum. Each *datum* is simply a file or directory underneath the
node's directory.

`graph_datum` is a low-level function which performs operations on a
single datum of a single node.

`datum` high-level query consumer which exposes a subset of the datum
subcommands.

There are a few `reserved` data used to implement the more opinionated
and gtd-specific functions.

#### `contents` ####

`contents`: datum containing summary of graph node entry

It is a plain text file whose contents is the canonical description
for the node. The first line of this file is used as the *gloss*,
which is printed by `graph_node_gloss` and `task_summary`.

**Note** I don't like this name. I am considering renaming this datum
to `description`.

#### `state` ####

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

##### Not Yet Implemented #####

`REPEATS` indicates a repeating event, where *pattern* is an
expression that defines the pattern of repetition. See [Repeating
events](#Repeating_Events)

#### Data (graph-datum) ####

You can store whatever you like directly within this database,
(including symlinks, if you don't care about being the database being
self-contained).

## Filter Chaining: A new shell pattern?

**TBD** Explain the `*_filter_chain` family of functions and how they
work together to parse the query language.

## Shell FP

**TBD** Explain `map_lines` and `filter_lines`.

# Coding Style

The basic rule is: *be understood by those less familiar with shell
programming*.

This project aims to manage one's most personal data. As such, I would
like to be as transparent as possible about how it works.

Many open-source and industry veterans are skeptical of shell. One of
my larger goals is to make the case for doing serious things with
shell.

The following is a set of rough guidelines.

- when in doubt, match the surrounding code
  - or whatever code you're drawing inspiration from
- prefer 80 columns
  - exceptions are allowed when:
    - the alternative would be awkward or impossible.
	- for tabular formatting (see below)
- quote almost all variable substitutions `"${foo}"`
  - exception: for loops `for f in ${foo}; ...`
- use tabular style:
  - for case constructs
  - for data-driven code
  - you may exceed the basic 80 column limit to maintain tabular style
    - but keep lines as short as possible.
  - TBD: include some representative examples
- prefer `snake_case` to `kebab-case` for implementation details
  - these are candidates for optimization in mainstream languages
    which do not allow `-` in identifiers.
- short function names are reserved for user-facing commands.
- prefer `test ...` to `[ ... ]`
- avoid using "$0"
  - directly test the status code of commands `if ...`
- avoid [shell anti-patterns](tbd: oilshell link)
- embrace [the good parts](tbd: oilshell link)
- bash extensions are acceptable iff they are:
  - *more* readable than portable shell, or
  - strictly necessary for required functionality.
  - avoid zsh or other incompatible shell constructs.
    - when unavoidable, hide behind an abstraction layer
- prefer `... | while read ...` to `... | sed ...`, `... | grep`, `... | awk ...`
  - use `test`, `[[ ... ]]`, `case ... in ...` within the loop t match each record or line.
  - afore-mentioned tools employ cryptic mini-languages, each of which
    has its own sordid history of pitfalls and misuse.
	- where such tools are truly appropriate, use dedicated scripts
   - sed, awk, and even grep can consume commands from a file
   - avoids many quoting hassles
	 - makes language composition explicit
	 - modern version control obviates the historical impulse to
     keep everything in one file.
  - these are *tool families* rather than specific tools, whose
    behavior diverges in ways both subtle and gross.
  - exception?: passing through user patterns to grep
- prefer pipelines to temp files
  - `foo | bar` is better than `foo > tmp; bar < tmp;`
  - when a command cannot consume from stdin
	- prefer process substitution (`bar <(foo)` or `foo >(bar)` even
      though this is shell-specific.
	- or use named pipes, if the feature is important enough to
      warrant broad portability.
- create and respect abstraction boundaries
  - factor out patterns into *composable* functions or scripts
  - shell has no module system, so we are stuck with:
    - C-style identifier prefixing
	- the "subcommand pattern"
	  - via pattern matching, or `"$@"` dispatch
	  - shelling out to another tool (with performance penalty)

Blank line between multi-line function definitions.

Very short function definitions can be formatted on one line:

```
function task_contents { graph_datum contents "$@"; }
function task_state    { graph_datum state    "$@"; }

```

A section comment looks like:

```
# Section *********************************************************************
```
Two blank lines surround section comments.


```
## Sub Section ****************************************************************
```

Single blank line around subection comments.

I could split sections into `gtd`.sh shell libraries, but for now I
prefer the script remain self-contained.

Sections are arranged in an inverted pyramid, with more generic layers
and at the top, and more specific layers at the bottom.
	  
## Blessed Shell Idioms

This section documents the unavoidably cryptic shell idioms that are
difficult to avoid.

**TBD**

- `cut -d ... -f ...`
- `head`
- `tail`
- bash array syntax
- redirections
- special shell vars
- `"$@"` dispatch"
- quoting idioms, corner-cases, and pitfalls

## Pull Requests

- create your own fork
  - create a topic branch on your own fork
    - The description should reference an issue on github.
	  - If no issue exists, create one yourself.
- unit tests pass
- you have added new tests for any new functions
- you have updated existing tests to cover new functionality
- you have comitted no egregious violations of official style
- at least a single-line doc comment for each function
  - exception: functions whose name begins with `__`
	- these are implementation details, and logically part of a parent
      function.
  - bonus points if you contribute or correct doc comments
  - bonus points if you document function arguments
- "unavoidably" cryptic shell code must:
  - include sufficient explanatory comments that it can be understood
    without reference to external documentation.
    - exception: *blessed idioms*, which compendium shall be appear herebelow.
    - bonus points if you successfully argue for a new *blessed idiom*.
