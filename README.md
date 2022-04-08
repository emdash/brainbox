# GtdGraph [Working Title]

An opinionated, GTD-oriented, CLI-based, task manager.

There seem to be as many implementations of GTD as there are
afficionados of GTD. So here's my contribution to the space.

This one is inspired by task warrior, but takes a graph-theoretic
approach.

## Major Features

### Automatic Detection of Next Actions and Projects

Unlike other systems, which force you to explicitly designate
"projects" and "next actions", in GtdGraph, this level of filtering is
completely automatic.

#### How it Works.

Your tasks form a graph, whether or not you represent them as such. A
task may depend on other tasks. A task with dependencies is a
*project* in GTD parlance, while a task with no dependencies is a
*next action*.

A *next action* is corresponds to a "sink node" in graph theoretic
terms.

#### Rationale
 
A task with dependencies is by definition blocked, and therefore isn't
actionable. It should not appear in the "next actions" list.

If I see a task in my next actions list and realize that it had some
dependency I haven't captured yet, all I have to do is add a
dependency -- to either a new or existing task. Boom, it's no longer a
next action.

While many tasks only belong to one supertask, I find just as often
they belong to multiple. Moreover, even if my workload is largely
tree-shaped, I still want a quick way to see only the leaves of a
given subtree.

If you see a task in your next actions which actually has a
dependency, you can easily:
- link an existing task as a dependency, or
- create a new task dependency
- keep recursively subdividing and linking until your next
  actions list is an accurate reflection of your true workload.

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

Seamlessly shift between the following modalities:

#### Capture

Quickly insert a new item in to the task system, before you forget about it.

#### Triage

Efficiently review your inbox for recently captured items.

Add time estimates, deadlines, tags.
Refine task description.
Move task into appropriate subproject.
Promote task to subproject.

#### Plan

Efficiently review a project, or set of projects. Add new tasks,
subdivide existing tasks, record progress on tasks. Adjust contexts.

Add notes, link other context.

#### Execute

Generates todo lists from sequences of actions, grouped by context queries.
Easily check off items:
- done
- drop
- defer
- promote to subproject
  - item will show up in next project review
- Your next actions are automatically computed from the graph structure
- You can easily subdivide an unactionalble task
- You can easily make a task depend on 

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
