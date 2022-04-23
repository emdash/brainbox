# GtdGraph [Working Title]

A productivity tool that is:

- GTD-oriented
- Command Line Driven
- Opinionated

I have a long-time fascination with "productivity tools" and the
[GTD](tbd:link) philosophy.

Recently, I discovered [`taskwarrior`](tbd:link). I like a lot of
things about it, does not do the one thing I wanted most:
automatic maintenance of "Next Actions". So, wrote my own tool, and now
I'm sharing it with the world.

To get a feel for how it works, please read the [manual](manual.md),
which is written in a tutorial style.

**TBD:** Screen capture of basic usage

## Distinguishing Features

### Automatic Task Categorization 

If you've ever tried to observe GTD discipline, one thing you probably
found tedious was maintaining lists of *Next Actions*, *Projects*,
*Contexts*, etc. With GtdGraph this is automatic!

Instead, GtGraph shifts the focus to the relationships between tasks,
inferring the rest through the magic of [graph
theory](https://en.wikipedia.org/wiki/Graph_theory).

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

Whereas most prodctivity tools treat contexts as labels, GtdGraph,
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

Given the above, GtdGraph can easily help you answer questions like:

- what am I ready to do today?
- what do I want from any grocery store?
- what can I do while I'm in the north side of my home town?

Because the same tasks can be linked in multiple ways, you can create
multiple, overlapping context nextworks to handle different scenarios,
like: 

- being at home
- being at work
  - working from home
  - working in the office
- work travel, vacation, visiting family etc.

### zero-install, if desired

GtdGraph is a shell script which can be run directly from the project
source directory, or simply add a couple lines to your shell config to
achieve a user or system-wide installation.

At the time of this writing, GtdGraph has not been packaged by any
distribution.

#### Dependencies (debian packages)

GtdGraph relies on a small number of dependencies which anyone
interested in a shell-based productivity *probably* already has
installed.

- python3, for some targeted "optimizations"
- uuid, for ID generation
- fzf, or a compatible alternative, for interactive search
- git, for history managment

#### Recommended

- optionally, graphviz (for visualizations)

#### Dev Dependencies

- shellcheck

### Self-contained databases

The "database" is just nested subdirectories. You can store whatever
data you wish directly within your database alongside your task
entries. The database can be freely copied, compressed, uploaded, etc.

#### Status, and V1.0 Roadmap ####

This is the TODO list for v1.0

- Code Quality
  - [ ] Pass shell check lints
  - [ ] Every function has a unit test
  - [ ] Every function has doc comments
  - [ ] Stretch goal: documentation generated from doc comments
- Database v1.0
  - [X] Basic graph algorithms
  - [X] Filtering functions
  - [X] Tasks
  - [X] Contexts
  - [X] Simple Task States
  - [ ] Time-Based Task State
	- [ ] DELAYED
	- [ ] REPEATS
  - [X] cycle detection
	- [X] separate for dependencies and contexts.
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
  - [ ] Delete selected tasks
    - [ ] Also deletes edges
  - [ ] Delete selected edges
  - [ ] Archive inactive subgraphs
  - [X] Task Data (need tests untested)
    - [X] Copy files under task dir
- History Management
  - [ ] edges no longer represented as empty directories.
	  - represent edges as plain files?
	  - add .keep file which is just empty placed under the edge dir?
	  - store a state file with a dummy state?
  - [ ] undo
  - [ ] redo
  - [ ] revert if command fails
    - [ ] in particular, if adding edges would produce a cycle
- Visualizations and Reports
  - [X] format project as a tree
  - [X] dotfile conversion of entire db
  - [X] Visualize subgraph rooted at given node or set of nodes.
  - [ ] dot file export
    - [X] Basic export
	- [ ] visually distinguish between context and dependency edges 
	- [ ] visually distinguish node state and GTD classification
  - [ ] Gantt Charts
  - [ ] "Completion Calendars"
- Console UX
  - [ ] Completion scripts for bash
  - [ ] Menu-driven Triage mode
  - [ ] Project Planify mode
  - [X] interactively select single task
  - [X] interactively select multiple tasks

## V2.0 and beyond

At minimum:

- terminal output should achieve similar level of polish to what tools
like TaskWarrior already deliver.
- richer set of visualizations and reporting out of the box

Depending on and user demand:

- May offer less opinionated feature set
- May offer more facilities for customiztion
- May focus on supporting a wider range of shells.
  - or pick a *specific* shell to embrace
- May focus on secure handling of untrusted data:
  - for safe integration with external tools
	- which likely requires moving to a SQL database
	- filesystem + git doesn't scale.
- May add a menu-driven or gui interface on top of the core command
  line tool
