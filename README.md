# Brainbox

A productivity tool that is:

- GTD-oriented
- Command Line Driven
- Opinionated

I have a long-time fascination with "productivity tools" and the
[GTD](https://en.wikipedia.org/wiki/Getting_Things_Done) philosophy.

Some time ago, I discovered
[`taskwarrior`](https://taskwarrior.org/). I like a lot of things
about it, does not do the one thing I wanted most: automatic
maintenance of "Next Actions" via a graph of projects.

To get a feel for how it works, please read the [manual](manual.md),
which is written in a tutorial style.

## v2 Database Schema *Warning*

I don't think anyone but me is using this tool, but on the off-chance
that someone is, DO NOT UPGRADE to this version with an old database!

Create a fresh database for V2, and migrate your tasks either manually
or write some custom shell to do it, or if you really need help, open
an issue and I will spend some time on migration scripts..

The commit tagged `v0.3` is the last official version supporting the
original DB schema.

In addition, the `v2` schema is still evolving. I am trying to fix
some design mistakes. `v3.0` will be the next stable schema.

## Distinguishing Features

### Automatic Next Action Tracking

If you've ever tried to observe GTD discipline, one thing you probably
found tedious was maintaining lists of *Next Actions*, *Projects*,
*Contexts*, etc. With Brainbox this is automatic!

A task can link to subtasks, in serial or parallel, and dependencies
can be shared by multiple tasks.

The *agenda* view automatically filters out blocked tasks. As you
unblock tasks, they will automatically appear in the agenda view.

### Opinionated, GTD-oriented command set

#### *Capture* and *Inbox*

Quickly insert a new item in to the task system, before you forget
about it.

Quickly review and triage your inbox.

#### Query

Easily review and filter entries by any combination of:

- context
- project
- task label
- task state
- task category (project, next action, and others)

### Context Linking and Subsetting

Whereas most prodctivity tools treat contexts as labels, Brainbox,
contexts have graph structure.

For example, you might have the following:

| Context          | Subcontexts                      |
| ---------------- | -------------------------------- |
| "Errands"        | "Grocery Store" "Hardware Store" |
| "Grocery Store"  | "Safeway" "Albertsons" "Costco"  |
| "Hardware Store" | "Home Depot" "Ace"               |
| "Home Town"      | "South Side" "North Side"        |
| "South Side"     | "Safeway" "Home Depot"           |
| "North Side"     | "Albertsons" "Costco" "Ace"      |

Given the above, Brainbox can answer questions like:

- what am I ready to do today?
- what do I want from any grocery store?
- what else can I do while I'm on the north side of town?

Because tasks can be linked in multiple ways, you can create multiple,
overlapping context nextworks to handle different scenarios, like:

- being at home
- being at work
  - working from home
  - working in the office
- work travel, vacation, visiting family etc.

### zero-install, if desired

Brainbox is a shell script which can be run directly from the project
source directory, or simply add a couple lines to your shell config to
achieve a user or system-wide installation.

At the time of this writing, Brainbox has not been packaged by any
distribution.

#### Dependencies

Brainbox relies on a small number of runtime dependencies:

- python3, for some targeted optimizations
- fzf, or a compatible alternative, for some interactive search
- git, for history managment
- graphviz for graph visualization
- [my fork of xdot](http://github.com/emdash/xdot.py) for interactive
  visualization.
  - I have submitted a PR which is still awaiting review.
- for graph visualization, a terminal supporting images (I use `foot`)

#### Dev Dependencies

- shellcheck

### Self-contained databases

The "database" is just nested subdirectories. You can store whatever
data you wish directly within your database alongside your task
entries. The database can be freely copied, compressed, uploaded, etc.

#### Status, and V2.0 Roadmap ####

This is the TODO list for v2.0

- Code Quality
  - [ ] Pass shell check lints
  - [ ] Every function has a unit test
  - [X] Every function has doc comments
  - [ ] Stretch goal: documentation generated from doc comments
- Database v2.0
  - [X] Basic graph algorithms
  - [X] Filtering functions
  - [X] Tasks
  - [X] Contexts
  - [X] Simple Task States
  - [X] Time-Based Task State
  - [ ] cycle detection
	- [ ] separate for dependencies and contexts.
- Task Management
  - [X] Capture new item
  - [X] List all tasks
  - [X] List new tasks
  - [X] List someday tasks
  - [X] Filter next actions
  - [X] Filter tasks by context
  - [X] Filter tasks by project
  - [X] Defer task
  - [X] Drop task
  - [X] Complete task
  - [X] Delete selected tasks
    - [X] Also deletes edges
    - [ ] Also delete subtasks
  - [X] Delete selected edges
  - [X] Task Data (need tests untested)
    - [X] Copy files under task dir
- History Management
  - [X] undo
  - [X] redo
  - [ ] revert if command fails
    - [ ] in particular, if adding edges would produce a cycle
- Visualizations and Reports
  - [X] format project as a tree
  - [X] dotfile conversion of entire db
  - [X] Visualize subgraph rooted at given node or set of nodes.
  - [X] dot file export
    - [X] Basic export
	- [X] visually distinguish between context and dependency edges
	- [X] visually distinguish node state and GTD classification
  - [ ] Gantt Charts
  - [X] "Completion Calendars"
- Console UX
  - [X] Completion scripts for bash
  - [X] Menu-driven Triage mode
  - [X] Project Planify mode
  - [X] interactively select single task
  - [X] interactively select multiple tasks

## V3.0 and beyond

- rewrite TUI using a dedicated TUI framework
  - web UI?
- rewrite core components in strongly-typed language
- opinionated DB construction
- facilities for user customizations
- direct support for syncing across multiple devices
- direct support for integration with external services / tools
  - weather plugin
  - google calendar, etc
