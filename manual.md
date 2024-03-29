# GtdGraph manual

**Note**: This is pre-release, everything in here is subject to change.

Once v1.0 is released, everything documented in this manual will be
considered stable until v2.0, where breaking changes to the user-level
command set may be considered.

Commands not documented here are implementation details, and are
subject to change at any time.

## Installation

Installation is documented [here](install.md)

## A Word of Caution

GtdGraph is intended for *individual*, as opposed to *team* use.

GtdGraph is intended to be used *locally* and *directly* by a *single
user*. The implementation is wholly unsuitable for *concurrent* use by
one or more users. With the sole exception of *live queries*, avoid
running multiple instances of `gtd` on the same database.

GtdGraph is itself a *shell program*, it is potentially vulnerable to
*shell injection* attacks. *never* pass comand-line *arguments* to
gtdgraph from an untrusted source via command substitution or any
other mechanism. If you absolutely *must* consume data from an
external tool, use the facilities for IO redirection. At the moment,
it is up to *the user* to ensure inputs to GtdGraph are benign, or
else choose an appropriate sandboxing strategy.

As with any command-line tool, avoid copy-pasting commands from random
websites (including *this one*) directly into your terminal. Type
examples in by hand, and think carefully before you press `<enter>`.

## Overview & Getting Started {#Overview}

GtdGraph is command-line driven. You should be comfortable in a unix
shell environment, and have some familiarity with the philosophy of
[Getting Things
Done](https://en.wikipedia.org/wiki/Getting_Things_Done).

You must first create a database:

	gtd init

This will create a `gtdgraph` subdirectory under the current working
directory. You can create multiple databases in different
directories. Each one is stand-alone, as with `git`.

Once you have your database, add some tasks to it:

	gtd capture buy milk
	gtd capture check mailbox
	gtd capture take out the trash

`capture`, with no arguments, will create a new node, and invoke your
`${EDITOR}` so you can edit its description.

	gtd capture

Or, you can `capture` the output of a command:

	echo "buy milk, but from stdin" | gtd capture

To see the tasks you've added:

	gtd inbox summarize
	
To mark interactively mark tasks as completed, droped, or defered:

	gtd choose complete
	gtd choose drop
	gtd choose defer
	
To see all your tasks, including inactive tasks:

	gtd summarize
	
GtdGraph uses `fzf` for interactive selection.

- By default, `fzf` uses the `tab` key to select nodes. 
- Press `<enter>` to accept the selection.
- Use `Ctrl-C` to cancel the entire operation.

[fzf](https://github.com/junegunn/fzf) is a separate project. Consult
its documentation for details on configuration and use.

That is all you need to get started. When your task list has grown to
the point where it no longer fits on one screen, read on.

**TBD**: include navigation examples
**TBD**: show how `cur` affects behavior of `capture`

## Queries ##

Graphs are more complex to manage than trees. I suspect this is why
most productivity tools are tree-based, if they go beyond flat lists
at all. GtdGraph tames this complexity with a simple, post-fix query
language.

Queries are created by combining one or more *query commands*. See
[examples](#Examples) below. Each *query command* is documented in
[Appendix A](#appendix-a)

## Non-Query Commands

There is a short list of non-query commands whose naming should be
self-explanatory.

### `add` [*tasks* [*subtasks*] ]

Links subtasks to supertasks.  Where *tasks* and *subtasks* are
buckets, defaulting to `source` and `target` respectively

### `assign` [*tasks* [*contexts*] ]

Links tasks to contexts, where *tasks* and *contexts* are buckets,
defaulting to `target` and `source` respectively. Note this order is
swapped from `add`, because context assignment is an *incoming* edge.

### `buckets`

List all known buckets.

### `clobber`

Deletes the database forever, with confirmation. This **cannot be
undone.**

### `down`

Move to one of current node's children

### `follow` *read-only query*

Create or update a *live query*. See [the example](#live-queries). The
query must be not modify the database.

When first given, a job is spawned. Each time `follow_notify` is
invoked, the given query will be re-evaluated.

### `follow_notify`

Force re-evaluation of the current *live query*. This is implicitly
called after every successful database transaction, or `into` write
query.

### `history`

List the history and commit id of each command which has altered the
database.

### `home` 

Unset the current node.

### `init`

Initializes a new graph database.

### `interactive`

Allows you to build non-destructive queries with an interactive
preview.

### `link`

Create *task dependencies* and *context assignments*. See the
[example](#link-example). See `unlink` below.

### `remove` [*source* [*target*] ]

Unlinks subtasks from supertasks.  Where *source* and *target* are
buckets, defaulting to `source` and `target` respectively

### `redo`

Restores the last undone operation. See `undo` below.

### `unassign` [*tasks* [*contexts*] ]

Unlinks tasks from contexts, where *tasks* and *contexts* are buckets,
defaulting to `target` and `source` respectively. Note this order is
swapped from `add`, because context assignment is an *incoming* edge.

### `unlink`

Remove *task dependencies* and *context assignments*. See `link`
above.

### `undo`

Undoes the last change to the database. See `redo` above.

### `up`

Move to one of current node's parents.

## Examples {#Examples}

You can try the following examples on a sample database:

	cd examples/sample

**TBD**: provide this directory.

### Viewing your *Inbox* ###

	gtd inbox summarize	
 
### Triaging your Inbox

**TBD**: rework this example

### Reviewing your *Next Actions* ###

	gtd is_next summarize
	
*Key Concept*: The entire command is a *query* consisting of two
*query commands*.

*Key Concept*: The *query command* `is_next` is a *query filter*. A
*query filter* selects tasks from an *input set*, yielding an *output
set*.

*Key Concept*: *Query commands* can be *chained*. The *output set* of
each *query command* becomes the *input set* of the following command.

*Key Concept*: `summarize` is a *query consumer*. A *query consumer*
performs some operation on each *task* in the *input set*. In this
case, `summarize` prints a summary of each selected task. *query
consumers* are only allowed at the *end* of a query.

### Searching Task Descriptions ###

	gtd search "Kitchen Remodel" subtasks is_next summarize

Print a summary of *next actions* for the `"Kitchen Remodel"` project.

`search` is another *query filter*. Unlike `is_next`, `search`
requires an *argument*. This *argument* may be:

- a single unquoted word
- a double-quoted string 
- a single-quoted string

The argument is interpreted as a regex pattern as interpreted by
`grep`. Consult `man grep` for more information.

### Show *Next Actions* assigned to a *Context* ###

	gtd search "Grocery Store" assigned is_next summarize

This will show a summary of all *next actions* assigned to the
`"Grocery Store"` *context*.

*Key Concept*: In GtdGraph, *contexts* also form a graph.

*Key Concept*: In GtdGraph, the distinction between *tasks*,
*contexts*, and *projects* is merely a conceptual one. What
I have previously referred to as *tasks*, *contexts*, and *projects*
are all simply *nodes* in a *graph*.

In the remainder of this document:

- *task* refers to a *node* used as a task, in the GTD sense.
- *context* refers to a *node* used as a context, in the GTD sense 
- *project* refers to a *node* used as a project, in the GTD sense.
- *node* is used when the distinction is irrelevant.

In any case, these terms refer to the same underlying construct witin
GtdGraph.

### Projects and Tree Formatting ###

	gtd is_project choose -
	
Interactively select a single *project* from the database, and print
its ID.

- `is_project` is a *query filter*.
- `choose -s` allows only a single node to be selected.

*Key Concept*: A *project* is a *node* with at least one *subtask* and
at least one *supertask*.

*Key Concept*: The relationship between a *subtask* and a *supertask*
is a *dependency*.

	gtd search "Kitchen Remodel" project

This will format all *subtasks* of the "Kitchen Remodel" project as
a nested list. The above example is equivalent to:

	gtd search "Kitchen Remodel" tree dep outgoing indent

*Trees* and *graphs* are closely related. In short: trees are a
*subset* of graphs, where each node may only have one *incoming*
edge. Within GTD, it isn't uncommon for a *project* to have tree-like
structure, in which case, it is useful to present as a hierarchy.

In the example database, the *project* labeled `"Kitchen Remodel"` is
tree-like.

- `project` is a *query consumer* which is equivalent to `tree dep
  outgoing indent`
- `tree` is a *query consumer* which computes the *tree expansion* of
  each node in the *input set*
  - at the same time, a *depth* value is computed for each node.
- In this case, the *input set* consists of a single task, but
  multiple tasks are allowed.
  - A *tree expansion* will be computed for *each* node in the *input
    set*.
- `dep` and `outgoing` are *arguments* to `tree`. They specify which
  *edge set* to use, and in which direction to follow edges.
  - In this case the *task dependency* edges, in the *outgoing*
  direction.
- `indent` formats each node ID using the depth information computed
  by `tree`.

`tree` works on input which is not strictly tree-structured:

- shared nodes will be *duplicated* in the *tree expansion*.
- `tree` will fail on subgraphs which contain cycles.

### Saving Query Results ###

	gtd choose into trash

This will bring up an interactive menu, where you can search and
select whichever tasks you wish. If you *accept* the query, then these
tasks will be placed into a *bucket* named `trash`.

- `choose` is a *query filter* we have seen before.
- `into` is a *query consumer* which will place the IDs it receives
  into the *bucket* named by its *argument*, in this case a bucket named `trash`.

*Key Concept*: A *bucket* is just a temporary container for a set of
nodes on which you intend to perform subsequent operations.

*Key Concept*: Buckets are created as needed. If a bucket already
exists, the *input set* is replaces the existing contents. Use
`--union` to also retain the existing contents of the bucket.

*Key Concept*: Bucket names are arbitrary strings. They can be as
short or as long as you like. As meaningful or meaningless as you
prefer. In the remainder of this document, bucket names are chosen to
help elucidate examples.

#### Buckets are Ephemeral.

Buckets are intended for short-term use. Bucket contents are not
stored in the database history, and are not affected by `undo` and
`redo`. Avoid the long-term use of buckets.

### Using Saved Query Results ###

	gtd from trash drop

This will mark every node in the bucket named `trash` as
`DROPPED`.

- `from` is a *query producer* which selects tasks the given
  *bucket*. It may only appear at the beginning of a query.
- `drop` is a *query consumer*, which alters the *task state* of the
  *input set*.
  
*Key Concept*: Nodes have *state*, which is used by certain *query
filters* to determine visibility.

*Key Concept*: A task with *state* `DROPPED` is no longer considered
*active*. Various filters, including `is_next` will exclude such
nodes. `DROPPED` tasks are still present in the database, and as such,
will appear in unfiltered output.

### Assigning tasks and contexts. {#link-example}

	gtd choose into source
	gtd choose into target
	gtd add
	
Choose a *project*. Then choose one or more *subtasks*. Finally, add
the *subtasks* tasks to the *project*.

	gtd inbox search milk into shopping
	gtd search "Grocery Store" into target
	gtd assign shopping

Link the task labeled `"buy milk"` to the context labeled `"Grocery
Store"`.

	gtd search "Grocery Store" assigned is_next summarize
	
Show the current shopping list.

### Breaking Links

TBD

### Moving Tasks

TBD

### Creating Context Hierarchies

*Key Concept*: In GtdGraph, *contexts* may also form graphs, allowing
for flexible filtering.

	gtd search "Errands" is_next summarize
	
This will show all the *Errands* that can be done right now. Note that
this does not include the *Grocery Store* items we added in the
previous section. Let's fix that:

	gtd search "Grocery Store" into target
	gtd search Errands into source
	gtd link context
	
Find the context named "Grocery Store", and add it as a subcontext of
"Errands".

	gtd search "Errands" is_next summarize
	
Note that the shopping list now appears in the output.

### Associating Tasks and Data

You can store anything you want inside a graph node. Lets say you
suddenly have an idea for a blog post.

	gtd capture "Blogpost about frobulated mcguffins"
	
Later, you triage your inbox, and assign this task to a bucket for
pending posts:

	gtd inbox search "frobulated" into posts
	
Now you want to actually write the post:

	gtd from posts choose into current_post
	gtd from current_post datum post mkdir
	gtd from current_post datum post/post.md edit
	
This will bring up the posts contents in your `"${EDITOR}"`.
	
*Key Concept*: Graph nodes may contain *data*. *Data* is
plural. *Datum* is the singular form of *data*.

*Key Concept*: Each *datum* is identified by a *key*. As with *bucket
names*, *data keys* are arbitrary strings. More correctly, they are
*subpaths* under the node's own directory.

*Key Concept*: There are two *special* data we have been using all along:
`contents`, which is used for *labels*, and `state` which is
determines the behavior of various *query filters*.

Continuing the example, let's say while researching this post, you
found the *perfect* illustration, and the artist has given you
permission to use it. A copy now resides in your downloads folder:

	gtd from current_post datum post cp ~/Downloads/mcguffin.svg
	
This will copy `mcguffin.svg` alongside your `post.md` file.

	pushd "$(gtd from current_post datum post path)"
	
This will navigate directly to the `post` subdirectory within your
database. When you are finished, you can return to where you started
with `popd`.

### Watching the Database for Changes {#live-queries}

GtdGraph supports *live queries*. These are automatically re-evaluated
whenever the database updates.

	gtd follow inbox summarize &
	gtd capture "I added something to the database"
	gtd undo
	
Notice the query is reprinted each time. This is particularly useful
in conjunction with the `dot` query consumer:

*key concepts* Live queries get re-run wach time the database changes.
	
Live queries are the exception to rule of "at most one `gtd` process
operating on the database" at a time. This is is because they are
synchronized to occur after a successful database commit, ensuring
they always have a consistent view of the database.

At the moment, only one live query is supported at any given time. So
the per-database currenncy rule is:

- at most one live query, plus
- at most one additional command

As this is confusing and complicated to explain, I aim to improve this
situation in future releases.

### Database Visualization

While GtdGraph is primarily textual, you may prefer to examine a
visual representation of your database from time to time. The `dot`
*query consumer* converts the *input set* into the *dot* language
understood by graphviz:

	gtd dot
	
If you have graphviz installed, can view this directly:
	
	gtd dot | dot -Tx11

The `dot` *query consumer* can be combined with *filters*, as with
`summarize`. For example:

	gtd search "Kitchen Remodel" subtasks dot | dot -Tx11
	
This will limit the output to subtasks of the "Kitchen Remodel"
project.

I prefer [`xdot.py`](link:tbd) for visualizations:

	gtd search "Kitchen Remodel" subtasks dot | xdot -

### Real-time Visualizations

If you have [my version of `xdot`](link:tbd), which supports streaming
input, you can use the `visualize` command instead.

	gtd inbox into live
	gtd visualize from live
	
This creates a *live query* which starts with the current contents of
the inbox. To see your next-actions instead. *Note*: The `visualize`
prefix implies the `dot` query consumer, and so the query may not
contain any query consumers.

Try changing one of the nodes:
	
	gtd inbox choose activate
	
You will see the color of the item change. You can change the set of
nodes visualized in one of two ways: either by replacing the bucket
contents...

	gtd is_next into live
	
...or by specifying a new query directly.

	gtd visualize is_next
	
The choice depends on:

- whether you want nodes which no longer satisfy the query to remain visible
- how patient you are waiting for the query to be processed.

Node colors:

- light grey: active nodes
- muted grey: inactive 
- green: persistent nodes
- hot pink: inbox nodes
- off-wite: deferred nodes

Edge Styles:

- solid: dependency
- dashed: context

## Conclusion

This is GtdGraph in a nutshell. We're barely scratching the surface of
what is possible, particularly when combined with shell programming.

I hope you will give GtdGraph a try. Please feel free to submit bug
reports, feedback, and feature requests via *GitHub Issues*.

# Appendix A: Query Language Reference # {#appendix-a}

The basic syntax: [ *producer* [args...] ]  [ (*filter*
[args...])... ] [ *consumer* [args ... ] ]

In plain language: each query begins with an optional *producer*,
followed by any number of *filters*, and ending with an optional
*consumer*. Some query commands consume options and / or required
arguments.

In general, *producers* and *filters* and read-only and idempotent
operations. Only *consumers* and non-query commands will modify the
database.

## Producers ##

| Command         | Description                                                   |
|-----------------|---------------------------------------------------------------|
| `-`             | consume node ids from stdin                                   |
| `all`           | select all nodes. implied if the query begins with a filter   |
| `from` *bucket* | select the node ids contained in  *bucket* (see also: `into`) |
| `inbox`         | alias for `all is_new`                                        |
| `last_captured` | output the id of the last captured node                       |
| `null`          | output an empty set                                           |
	

## Filters ##

| Command                                                      | Description                                                                        |
|--------------------------------------------------------------|------------------------------------------------------------------------------------|
| `adjacent` ( `dep` \| `context` ) (`outgoing` \| `incoming`) | output immediately adjacent nodes for each node in the input set                   |
| `assigned`                                                   | output all tasks assigned to each context in the input set, including subcontexts. |
| `children`                                                   | output immediate children of input set                                             |
| `choose` [ `-m` \| `-s`]                                     | interactively select one or many nodes                                             |
| `datum` *datum* `exists`                                     | keep only nodes for which the given datum is defined                               |
| `is_actionable`                                              | keep only nodes considered actionable (omits WAITING nodes)                        |
| `is_active`                                                  | keep only nodes considered active (includes status WAITING)                        |
| `is_complete`                                                | keep only nodes considered completed                                               |
| `is_context`                                                 | keep only nodes with at least one outgoing context edge.                           |
| `is_deferred`                                                | keep only nodes with state SOMEDAY                                                 |
| `is_new`                                                     | keep only nodes with status NEW                                                    |
| `is_next`                                                    | keep only nodes considered *next actions*                                          |
| `is_orphan`                                                  | keep only orphaned nodes                                                           |
| `is_persistent`                                              | keep only nodes with status PERSIST                                                |
| `is_project`                                                 | keep only nodes with at least one subtask and at least one supertask.              |
| `is_root`                                                    | keep only nodes which have no supertask.                                           |
| `is_unassigned`                                              | keep only nodes not assigned to any context                                        |
| `is_waiting`                                                 | keep only waiting in state WAITING                                                 |
| `is_someday`                                                 | keep only nodes with status SOMEDAY                                                |
| `parents`                                                    | output immediate parents of input set                                              |
| `projects`                                                   | output the supertassks of each node in the input set                               |
| `subtasks`                                                   | output all substasks (including transitive) of each node in the input set.         |
| `search`                                                     | keep nodes whose description matches *pattern*                                     |

## Consumers ##

Read-only Consumers:

| Command                                                  | Description                                                           |
|----------------------------------------------------------|-----------------------------------------------------------------------|
| `datum` *datum* `read`                                   | print the specified datum for each node in the input set.             |
| `datum` *datum* `path`                                   | print the path to the specified datum for each node in the input set. |
| `dot`                                                    | convert the subgraph covered by the input set into graphviz syntax    |
| `into` *flags* *bucket*                                  | update the named bucket, according to *flags*                         |
| `project`                                                | same as `tree dep outgoing`                                           |
| `summarize`                                              | print a short summary of each node in the input set.                  |
| `tree` (`dep` \| `context`) (`incoming` \| `outgoing`)   | produces the *tree expansion* of each node in the *input set*         |
| `indent`                                                 | formats the output as an indented list. only used with `tree`         |

Where *flags* is: `--union` \|`--subtract` \| `--intersect` \| `--noempty`

Updating Consumers:

| Command                                         | Description                                                                   |
|-------------------------------------------------|-------------------------------------------------------------------------------|
| `capture`                                       | captures a new thought. if `cur` is nonempty, new node becomes subtask of cur |
| `activate`                                      | mark tasks as TODO                                                            |
| `complete`                                      | mark tasks as COMPLETED                                                       |
| `datum` *datum* `mkdir`                         | create the specified datum directory                                          |
| `datum` *datum* `cp` [ *flags*...] [ *path*...] | copy given paths into datum directory                                         |
| `defer`                                         | mark tasks as SOMEDAY                                                         |
| `drop`                                          | mark tasks as DROPPED                                                         |
| `edit` [ `--sequential` ]                       | invoke `${EDITOR}` on each node, simultaneously or sequentially.              |
| `goto`                                          | choose a single node from the input to become the new current node            |
| `persist`                                       | mark tasks as PERSIST                                                         |
| `triage` [ bucket... ]                          | interactively distribute tasks into buckets.                                  |

# Appendix B: Recovering from Database Corruption

GtdGraph is a work in progress and may contain bugs which corrupt the
database. However, since GtdGraph uses `git` for history management,
it generally possible to recover a corrupted database. GtdGraph
intentially does not supress the output of `git` commands it executes,
as it provides valuable feedback.

`gtd undo` is your first line of defense. If a command fails or has
some other undesirable effect, it is often sufficient to run `git
undo`, and then simply repeat the offending command, altering as
appropriate.

If a command exits prematurely, leaving the working tree dirty, you
can manually commit any changes via 
	
	gtd database_commit <message>
	
If this is not enough, then you can directly modify the git repository
via:
	
	gtd database_git ...
	
This is a wrapper command, which sets the git directory and working
tree as appropriate. Any arguments are forwarded directly to
`git`. Knowledge of the `git` version control system is
required. Consult the [Documentation](https://git-scm.com/) for more.

# Appendix C: Scripting API

The commands documented in this manual are implemented in terms of a
lower-level *scripting API*. New features and extensions to GtdGraph
may also make use of this API. Additionally, it possible, though
cumbersome, to use the scripting API directly from the command line.

The scripting API consists of all functions defined in `gtd.sh` which
do not begin with `__`. The scripting API is documented directly
within the source code. See [`gtd.sh`](gtd.sh).

Knowledge of `bash` is strongly recommended before attempting direct
use of the scripting API; however, interested users are encouraged to
read the source code.

The [Hacking Guide](HACKING.md) documents GtdGraph's conceptual
design, and will help orient you to `gtd.sh`'s source code.
