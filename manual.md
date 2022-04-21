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
the point where it no longer fits on one screen is when it gets
interesting.

## Queries ##

Graphs are more complex to manage than trees. I suspect this is why
most productivity tools are tree-based, if they go beyond flat
lists. GtdGraph tames this complexity with a simple, post-fix query
language.

### Examples ###

**TBD**: provide a working example data directory, where all these
examples will work.

#### Summarize All Tasks

```
$ gtd summarize
```

This is enough to get you started; however, as your database grows, it will quickly become overwhelming.

#### List Task Ids which are *Next Actions* 

```
$ gtd is_next
```

This command by itself is not terribly useful: it lists *IDs*, which
are strings of gibberish. However, you can fix this by appending
*summarize*, as above.

```
$ gtd is_next summarize
```

**Key Concept**: `summarize` is a *query consumer*, while is `is_next`
is a *query filter*. A *query filter* operates on sets of nodes, while
a *query consumer* does *something* with those nodes, and ends the
query.

#### Search Task Descriptions

```
$ gtd search "Kitchen Remodel" subtasks next summarize
```

Print a summary of *next actions* for the `"Kitchen Remodel"` project.

`search` is another *query filter*. Unlike `is_next`, `search`
consumes consumes an *argument*. This *argument* may be:

- a single unquoted word
- a double-quoted string 
- a single-quoted string

The word is interpreted as a regex by the `grep` command on your
system. If you really want to use a regex, then I recommend
single-quoting, as you would with `grep`.

#### Tree Formatting

```
$ gtd search "Kitchen Remodel" tree dep outgoing indent
```

This will format all the subtasks of the "Kitchen Remodel" project as
a tree.

*Trees* and *graphs* are closely related. In short: trees are a
*subset* of graphs, where each node may only have one incoming
edge. In task management, it isn't uncommon for subgraphs to have
tree-like structure.

In the example database, the *project* labeled `"Kitchen Remodel"`
has tree-like structure.

- `tree` is a *query consumer* whichcomputes the *tree expansion* of
  each node in the *input set*.
- `dep` `outgoing` are *arguments* to `tree`. They specify which edges to follow, and in which direction. In this case: *follow outgoing dependency edges*.
- `indent` Is like `summarize`, but it works on the output of `tree`.

`tree` will work fine on input which does *not* have tree
structure. Any shared nodes will be *duplicated* in the *tree
expansion*.

#### *Contexts* and *Edge Sets*

```
$ gtd search "Grocery Store" assigned is_next summarize
```

This will show a summary of all *next actions* assigned to the
`"Grocery Store"` context in the example database.

#### Buckets: Naming Query Results, and Database Updates

```
$ gtd choose into trash
```

This will bring up an interactive menu, where you can search and
select whichever tasks you wish. If you *accept* the query, then these
tasks will be placed into a *bucket* named `trash`.

- By default, `fzf` uses the `tab` key to select nodes. 
- Press `<enter>` to accept the selection.
- Use `Ctrl-C` to cancel the entire operation.

`fzf` is a separate project. Consult the documentation for `fzf` for
details on its configuration and use.

- `choose` is a *query filter*, which uses `fzf` to allow interactive
  selection of whichever tasks it receives from the *upstream* query
  command. The *IDs* of whichever nodes you select will be passed
  *downstream* to the next *query command*.
- `into` is a *query consumer* which will place the IDs it receives
  into the *bucket* named by its *argument*.

```
$ gtd from trash complete
```

This will mark every node in the `trash` bucket as `COMPLETED`. A task
with *state* `COMPLETED` is no longer considered *active*. This means
that various filters, including `is_next` will exclude such nodes from
their output. `COMPLETED` tasks are still present in the database, and
as such, will appear in the output of `gtd summarize`, `gtd all`, and
`gtd dot`. They are merely *filtered* as desired.

- `from` is a *query producer*. It sends the tasks from the *bucket*
  named by its argument *downstream* to the next *query command*. It
  may only appear at the beginning of a query.
- `complete` is a *query consumer*, which places the tasks it from
  *upstream* into the `COMPLETED` state.

## Non-Query Commands

Some commands don't fit into the query model.

### `capture`

Create a node and place it in the inbox. If additional arguments are
given, they become the node's "contents". If stdin is interactive,
opens contents file in your favorite editor. Otherwise, node contents
is read from stdin.

### `clobber`

Deletes the database forever, with confirmation.

### `init`

Initializes a new graph database.

### `interactive`

Allows you to build non-destructive queries interactively.

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
