# Design Notes

## Data Structure

### Directory-Oriented

- Like git.
- you must call `gtdg init` to initialize your task dir.
- There is no user-level dotfile.
- This allows you to have multiple, independent graph repositories
  with different settings for different purposes.

### Leverages the File System

The database is implemented as nested subdirectories.

You can store whatever files you like directly within this database,
including symlinks, if you don't care about being the database being
self-contained.

Nodes and edges are themselves subdirectories. Special file "contents"
contains free-form text (or your favorite markup language)

### Leverages Git

Uses git for
  - history
  - undo / redo
  - atomicity / rollback
  
### Graph Representation

Essentially, certain directories are interpreted as sets.

Nodes are identified by a UUID.

Edges are identified by a pair of UUIDs, separated by a colon.

There's a subdir for properties. Each property is itself a
named subdir, containing references for each node / edge in the set.

We represent edges as pair of UUIDs (separated by a ':' in the filename).

It should be immediately obvious that:
- tasks and projects are just nodes
- tasks can belong to multiple parent tasks
  - so we can do proper dependency tracking

What may not be obvious is that tags are also nodes:
- we distinguish the relationship between a tag and depdency by setting properties on edge between the nodes.
- if an edge belongs to the `dependency` set, then it is trated as a dependency.
- if an edge belongs to the `tags` set, then it is treated as a tag.
- an edge can belong to *both* sets, and therefore be treated as *both* both a tag and a dependency.

Tags can form a separate graph, so that we can perform complex filtering.
- tags are used to epress gtd contexts.
- edges between belonging the `subset` category allow expressing context subsets.
  - for example: SafeWay, Albertsons, GroceryOutlet, Costco can all belong to a GroceryStore category.
  - for example: Lowes, HomeDepot, Jerries, Ace can all belong to a HardwareStore category
  - perhaps Safeway is in the same part of your town as the Costco and HomeDepot, so you can group these together in a
    HomeTownWest category.
- the goal is efficient filtering by contexts at the point of use:
  - when I'm planning, I might assign a task to the "HardwareStore" category
  - when I'm out running errands, I want to know "what tasks can I do in this part of town", or "I happen to be near costco, what do I need that costco might have?"
  
We can tag edges with properties to provide hints as to their purpose.
- "type": "sibling"     -> specifies partial ordering on nodes, hint for tree formatting
- "type": "subproject"  -> expresses parent / child relationship, hint for tree formatting
- "deadline": 2022-6-1  -> useful for reminders / scheduling
- "recurring": (....)   -> automatically reschedule, hint for "completion calendar"
- "created-on"          |
- "estimated-time"      | 
- "completed-on"        |-> used for time tracking. 

## Views

We can show different representations of the graph. In particular:
- linearizations: depth first, breadth first, gant chart
- tree expansions, rooted at a particular node
- dot file visualizations

## Implementation

- mostly written in shell
- every operation touches the disk, so:
  - all operations are persitent and "atomic"
