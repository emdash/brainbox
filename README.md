# GtdGraph [Working Title]

An opinionated, GTD-oriented, CLI-based, task manager.

There seem to be as many implementations of GTD as there are
afficionados of GTD. So here's my contribution to the space.

This one is inspired by task warrior, but takes a graph-theoretic
approach.

## Motivation

I started this project mainly as a vehicle for improving my knowledge
of shell programming.

I have a passing interest in "productivity tools". Recently, I
discovered taskwarrior; so, I was inspired to write my own taskwarrior
clone that is based on my particular interpretation of the GTD system
plus a healthy dose of graph theory.

## Major Features

### Intelligent Filtering of Next Actions, Projects, and Contexts

Unlike other systems, which force you to explicitly designate
"projects" and "next actions", in GtdGraph, this level of reporting is
completely automatic.

You only have to explicitly track the relationship between your tasks
and contexts.

Your tasks form what in computer science is called a *graph*. Certain
concepts in GTD havea straight-forward expression in graph theoretic
terms. This tool designed to exploit this, so you can easily automate
your GTD discipline.

#### Task Dependency

For example: task A depends on task B. In graph theoretic terms, we
say that there is a "directed edge" (visually drawn as an arrow)
between "nodes" A and B.

#### Context Assignment

For example: task A is assigned to context C. In graph theoretic
terms, we say that there is "directed edge" from A to C.

#### Context Subsetting

For example: context "Safeway" is a subset of context "Grocery
Store". Every task assigned to "Safeway" is logically also assigned to
"Grocery Store". The same context "Safeway" is also a subset of the
geographic context "South Side", so every task assigned to "Safeway"
is also logically assigned to "South Side". Both "South Side" and
"Grocery Store" are subsets of "Errands".

In graph theoretic terms:
- "South Side"    -> "Safeway"
- "Grocery Store" -> "Safeway"
- "Errands"       -> "Grocery Store"
- "Errands"       -> "South Side"

We can easily filter tasks (and next actions) by context (and vice
versa), even indirectly.

#### Next Actions, Projects, and Project Roots

Next actions are simply task nodes with no dependencies. Projects are
simply task nodes with at least one dependency. A project root is a
task which is not a dependency of any other task -- which if your
database is well maintained, would ideally represent major life goals
or core values.

#### Justify Task

We can get a sense for *why* a task exists by examining what depends
on it.

This is like Next Actions, Projects, and Project Roots in reverse.

### Bringing it All together.

The common thing between all these notions is that they are all
representable in terms of graphs and basic operations on them:
- nodes
- edges
- path to root
- depth first traversal

We classify edges by the type of relationship they represent, which is
either a task dependency or a context relationship.

### Extremely Flexible Context Management

You can create interconnected context graphs. Tags can belong to
multiple containing contexts.

You can easily query for:
- what items do I want from Safeway?
- what items do I want from any grocery store?
- what stores do I want to visit in this part of town?
- what errands do I need run to finish this project?

Stretch Goal:
- location-based querying and context management.
- i.e. what tasks can be done near my current gps coordinates
- i.e. create a category for this set of named gps coordinates
- i.e. create a category for any points contained within this geographic boundary

### Automatic GTD Workflow

Seamlessly shift between the following ways of working.

#### Capture

Quickly insert a new item in to the task system, before you forget about it.

#### Triage

Review recently captured items, and refine them:

- add metadata
- edit task contents
- assign to contexts
- assign to parent task
- group into parents


#### Plan

Restricting output to tasks reachable from given project node:

- split up existing tasks into subtasks
- assign contexts to tasks
- examine recently completed 
- edit tsk metadata and notes

#### Execute

Generate a todo list from next actions filtered for given context.

Hot commands to handle the following common scenarios
- drop task                   (deletes it and all edges from the graph)
- delay task until date       (status: delayed(until: date))
- defer task indefinitely     (status: defered)
- blocked by existing task    (find; add dependency)
- blocked by new task         (capture; add dependency)
- complete task               (status: completed(on: date))
- archive task                (move completed tasks to archive area)

### Time Tracking

Automatically track the time taken to complete tasks.

A task "begins" the minute it's added to the system.  A task "ends"
when it's completed, or archived.  A task can begin and end multiple
times We can track the "cumulative time" spent (i.e. the total time
the task was considered active) or the "chronological time" spent,
i.e. the total time the task spent in the system from its creation.

Generate a report that shows how long a task actually took, relative
to your time estimates. This way you can get regular feedback about
your time estimation skills, and hopefully improve your estimates.


## Vs Task Warrior

This is trying to be more like taskwarrior, and perhaps code that
could be contributed to taskwarrior.

I don't know much about taskwarrior internals at this time.

Task warrior does some similar things, but it's ultimately a simpler
system.

Task warrior relies on a `.taskrc` file, so it can be run from any
directory.
- This might be the right design decision.
- I'm placing an emphasis on portability of the task data, and I so I
  want to avoide "hiding" user data in hidden files and directories.

## Vs org mode

org-mode is embedded in emacs, and is essentially set of macros,
which, once you've got sufficient practice with them, approximate a
proper implementation of GTD.

The good thing about this is you can learn it gradually.  The bad
thing about this is it *takes a while* to learn to use it.

Not everyone needs or wants to use emacs.

Also: you're writing a document. This means that you can:
- some operations you want to do are not atomic:
  - they are composed of multiple commands you execute in sequence
- accidentally corrupt your document without realizing it
- there's less of an obvious place to hook into version contorol
  - you are relying on emacs's ephemeral state for undo / redo, which
    you can lose at any moment.
- it is not self-contained
  - tends to rely on your .emacs:
  - you can use file-local variables to a degree,
    but it seems like some things can't be done this way.
  - what happens if two users want to use the same system?

I like taskwarrior's model a little better, since it's
event-oriented. There's a set of high-level commands wich provide an
obvious set of actions for undo/redo.

Taskwarrior is "priority" oriented. Basically it tries to weight your
tasks according to some arbitrary function, which you can tune. But
this approach seems wonky to me. It's a heuristic, and I'm not sure a
sound one. Admittedly, I haven't tried it.

GtdGraph is based on graph theory, which I feel is a more sound
approach, provided you have the discipline to record your task
dependencies. I feel that it's easier to express task dependencies
than to assign an arbitrary numeric "priority" to a task.
