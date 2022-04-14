# GtdGraph [Working Title]

A productivity tool that is:

- opinionated
- GTD-oriented
- CLI-based
- ADHD-friendly
- offline only (relies only on local filesystem)

I have a long-time fascination with "productivity tools". Recently, I
discovered `taskwarrior`. I liked a lot of things about it, but after
playing with it, I discovered it did not do the one thing I wanted:
automatic generation of "Next Actions". So, finally bit the bullet and
started on my own tool.

I have been meaning to expand my knowledge of shell programming, so
this tool is largely written in bash.

## Distinguishing Features

### Automatic Next Actions, Projects, Contexts, and Someday/Maybe

Unlike other systems, which force you to explicitly designate
"projects" and "next actions", in GtdGraph, this level of reporting is
completely automatic.

You only have to explicitly track the relationship between your tasks
and contexts, and GtdGraph figures out the rest using the magic of
[graph theory](https://en.wikipedia.org/wiki/Graph_theory).

### Self-contained, independent Databases

The database is just nested subdirectories.

Unlike taskwarrior, which uses a per-user databse by default, GtdGraph
looks relative to the current working directory (like `git`).

You can store whatever files you like directly within the database.

### Context Linking and Subsetting

Contexts can be linked, defining flexible subsets of tasks.

For example:
- "Errands"        includes "Grocery Store" "Hardware Store"
- "Grocery Store"  includes "Safeway" "Albertsons" "Costco"
- "Hardware Store" includes "Home Depot" "Ace"
- "Home Town"      includes "South Side" "North Side"
- "South Side"     includes "Safeway" "Home Depot"
- "North Side"     includes "Albertsons" "Costco" "Ace"

GtdGraph can easily handle the equivalent of "list next actions for
any grocery store on the north side of my home town".

### High level GTD Workflows

Seamlessly shift between the following workflows:

#### Capture

Quickly insert a new item in to the task system, before you forget about it.

#### Review

Easily filter entries by context, task, project, state, GTD category,
or some combination.

#### Triage and Project Planning

Review items according to various criteria, and refine them:

- examine and visualize project structure
- add metadata
- edit task contents
- assign tasks to contexts
- assign tasks to project
- break up complex tasks into manageable subtasks

#### Execute

Generate interactive todo lists, and check off items quickly.

### Time Tracking and Time Management Feedback

Automatically track the time taken to complete tasks, and generate
meaningful reports.

## Status, and V1.0 Roadmap

Right now it's eary days. This is the TODO list for v1.0

- [X] Database v1.0
  - [X] Basic graph algorithms
  - [X] Filtering functions
  - [X] Tasks
  - [X] Contexts
  - [ ] Task State
    - [X] NEW
	- [X] TODO
	- [X] COMPLETE
	- [X] WAITING
	- [X] SOMEDAY
	- [ ] DELAYED
	- [ ] REPEATING
  - [X] cycle detection
	- [X] separate for dependencies and contexts.
- [ ] Task Management UI
  - [X] Capture new item
  - [X] List all tasks
  - [ ] Filter tasks by context
  - [ ] Filter tasks by project
  - [X] List next actions
  - [ ] Someday / Maybe
  - [ ] Move files under task dir
  - [ ] Copy files under task dir
  - [ ] pushd into task directory
- [ ] Visualization API
  - [ ] Visualize entire DB
  - [ ] Visualize subgraph rooted at given node or set of nodes.
  - [ ] --context: include only context edges
  - [ ] --dep: include only dependency edges
  - [ ] visualize last operation
	- [ ] blink test
- [ ] History Management UI
  - [ ] back up db before destructive operations
  - [ ] revert state if command fails
  - [ ] undo
  - [ ] redo
- [ ] Visual UI
  - [ ] interactively select single task
  - [ ] interactively select multiple tasks
  - [ ] interactive task explorer
- [ ] Shellcheck all the things.

## Dependencies (debian packages)

- uuid
- fzf
- dialog

### Dev-Only

- shellcheck
