#!/usr/bin/env python

"""Module which edits with the `subtasks` datum.

At its core, the idea is that subtasks of a project one-per-line. The
`graph` module will construct a subgraph which chains these nodes in
sequence.

Unlike the high-level graph, where edges are stored in a directory,
which therefore acts like an unordered set, subtasks are ordered.

A simple subtasks file would look like:

```
xxxx-xxxx-xxxx-xxxx
yyyy-yyyy-yyyy-yyyy
zzzz-zzzz-zzzz-zzzz
aaaa-aaaa-aaaa-aaaa
```

That would give us a graph like:
  <project> -> a -> z -> y -> x

Sometimes, however, we want to express that subtasks can happen in
parallel. This is signaled with a blank line that separates tasks
into parallel groups.

```
xxxx-xxxx-xxxx-xxxx

yyyy-yyyy-yyyy-yyyy
zzzz-zzzz-zzzz-zzzz
aaaa-aaaa-aaaa-aaaa

bbbb-bbbb-bbbb-bbbb
```

...which yields a graph like:

<project> -> x
<project> -> y -> z -> a
<project> -> b

If you want a graph like:

<project> -> x -> { y, z, a } -> b, then you should make y, z, a
subtasks of x, rather than project.
"""


import sys

def swap(a, b):
  (lines[a], lines[b]) = (lines[b], lines[a])

def up(row):
    swap(row, (row - 1) % len(lines))

def down(row):
    swap(row, (row + 1) % len(lines))

def separate(row):
  # don't insert a separator on the first line.
  if row != 0:
    lines.insert(row, '')

# read the file into a list lists
print(sys.argv, file=sys.stderr)
lines = list(map(str.strip, open(sys.argv[1], "r")))

match sys.argv[2:]:
  case ["up",     row]: up(int(row))
  case ["down",   row]: down(int(row))
  case ["delete", row]: del lines[int(row)]
  case ["split",  row]: separate(int(row))
  case invalid: raise ValueError("Invalid command:", invalid)

with open(sys.argv[1], "w") as output:
  blank = False

  # don't allow separators at the beginning or end of the file
  if lines[0] == '':
    del lines[0]
  if lines[-1] == '':
    del lines[-1]

  # print output, merging consecutive blank lines into a single line.
  for line in lines:
    if line == '':
      if not blank:
        print(line.strip(), file=output)
        blank = True
    else:
      blank = False
      print(line.strip(), file=output)
