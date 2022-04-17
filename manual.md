# GtdGraph manual

**Note**: This is pre-release, everything in here is subject to change.

Once v1.0 is released, everything documented in this manual will be
considered stable until v2.0, where breaking changes to the user-level
command set may be considered.

Commands not documented here are implementation details, and are
subject to change at any time.

## Overview

GtdGraph is command-line driven. You should be comfortable in a shell environment.

You must first create a database:

```
$ gtd init
```

This will initialize a `gtdgraph` under the current working
directory. You can create multiple databases in different
directories. Each one is stand-alone, like .git.

Once you have your database, add some tasks to it:

`gtd capture`

This will create a new node, and invoke your `${EDITOR}`.

Alternatively, you can enter the description on the command line:

`gtd capture buy milk`

You can see the list of tasks by typing:

`gtd summarize`

That is all you need to get started. When your task list has grown to
the point where it no longer fits on one screen is when thing get interesting.

## Queries ##

Graphs are more complex to manage than trees. I suspect this is why
most productivity tools are tree based. GtdGraph tames this complexity
with a simple, post-fix query language.

### Examples ###

**TBD**: provide a working example data directory, where all these
examples will work.

Summarize all tasks. As your database grows, this will quickly become
overwhelming.

```
$ gtd summarize
```

List the node ids of all tasks identified as *next actions*.

```
$ gtd next
```

You can summarize any set of node ids by appending the *summarize*
keyword.

```
$ gtd next summarize
```

Print a summary of the next actions for your "Kitchen Remodel" project.

```
$ gtd search "Kitchen Remodel" subtasks next summarize
```

Print a tree formatted summary of your entire kitchen remodel project.

```
$ gtd search "Kitchen Remodel" as_tree indent
```

Print a summary of all the things you need to get during your next
grocery shopping trip.

```
$ gtd search "Grocery Store" assigned next summarize
```

**TBD** add examples which mutate the database.

Hopefully these exapmles give you some intuition for how the language works.

## Other Non-Query Commands

Some subcommands don't fit into the query model.

### `capture`

Create a node and place it in the inbox. If additional arguments are
given, they become the node's "contents". If stdin is interactive,
opens contents file in your favorite editor. Otherwise, node contents
is read from stdin.

### `clobber`

Deletes the database, with confirmation.

### `init`

Initializes a new graph database.

### `interactive`

You can build non-destructive queries interactively, with the result
being printed to stdout.

### `link`

This is a powerful command which:
- expresses task dependencies
- assigns tasks to contexts

### `redo`

Restores the last undone operation.

### `undo`

Undoes the last operation, restoring whatever the previous state
happened to be.

# Query Language Reference #

**TBD**: Generate this list from doc comments.
**TBD**: Format these lists as tables.

The basic syntax: [ *producer* [args...] ]  [ (*filter* [args...])... ] [ *consumer* [args ... ] ]

Each query starts optionally with a *producer*, which will print a
list of node ids to stdout.

As we've seen above, filters can be appended which will perform some
combination of addition or removal of node ids.

Finally, a *consumer* may be appended which will do something with
these node ids, terminating the query.

*producers* and *filters* are read-only operations. Some *consumers*
modify the database.

Consumers may appear only at the end of a query, making it
syntactically impossible to modify the database while traversing it
within a single query (with a few caveats).

## Producers ##

| Command         | Description                                                      |
|-----------------|------------------------------------------------------------------|
| `-`             | consume node ids from stdin                                      |
| `all`           | (implied if no producer is specified)                            |
| `from` *bucket* | output the node ids contained in the named *bucket* (see `into`) |
| `inbox`         | alias for `all is_new`                                           |


## Filters ##

| Command                  | Description                                                 |
|--------------------------|-------------------------------------------------------------|
| `assigned`               | output all tasks assigned to each context                   |
| `choose` [ `-m` \| `-s`] | interactively select one or many nodes                      |
| `datum` *datum* `exists` | keep only nodes for which the given datum is defined        |
| `is_actionable`          | keep only nodes considered actionable (omits WAITING nodes) |
| `is_active`              | keep only nodes considered active (includes status WAITING) |
| `is_complete`            | keep only nodes considered completed                        |
| `is_new`                 | keep only nodes with status NEW                             |
| `is_next`                | keep only nodes considered *next actions*                   |
| `is_orphan`              | keep only orphaned nodes                                    |
| `is_root`                | keep only nodes which are roots in the dependency graph     |
| `is_unassigned`          | keep only nodes not assigned to any context                 |
| `is_waiting`             | keep only waiting in state WAITING                          |
| `is_someday`             | keep only nodes with status SOMEDAY                         |
| `projects`               | insert ancestors of each node                               |
| `subtasks`               | insert subtasks of each upstream task                       |
| `search`                 | keep nodes whose description matches *pattern*              |

## Consumers ##

Nondestructive Formatters:

| Command                        | Description                                                                       |
|--------------------------------|-----------------------------------------------------------------------------------|
| `datum` *datum* `read`         | print the specified datum for each node                                           |
| `datum` *datum* `path`         | print the path to the specified datum for each node                               |
| `dot` [ `display` ]            | subgraph visualization using dotfile syntax.                                      |
| `into` [`--replace`] *bucket*  | save nodes into named bucket, optionally replacing existing contents (see `from`) |
| `summarize`                    | print a short summary of each node                                                |
| `tree` [ `indent` [ *prefix* ] | print a tree expansion of each node [^]                                           |

Destructive Operations:

| Command                                       | Description                             |
|-----------------------------------------------|-----------------------------------------|
| `activate`                                    | mark tasks as TODO                      |
| `complete`                                    | mark tasks as COMPLETED                 |
| `datum` *datum* `write`                       | print the specified datum for each node |
| `datum` *datum* `append`                      | print the specified datum for each node |
| `datum` *datum* `mkdir`                       | create the specified datum directory    |
| `datum` *datum* `cp` [ flags...] [ *path*...] | copy given paths into datum directory   |
| `defer`                                       | mark tasks as SOMEDAY                   |
| `drop`                                        | mark tasks as DROPPED                   |