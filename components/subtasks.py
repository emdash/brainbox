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
import os

def swap(lines, a, b):
  (lines[a], lines[b]) = (lines[b], lines[a])
  save(lines)

def up(lines, row):
  swap(lines, row, (row - 1) % len(lines))
  save(lines)

def down(lines, row):
  swap(lines, row, (row + 1) % len(lines))
  save(lines)

def separate(lines, row):
  # don't insert a separator on the first line.
  if row != 0:
    lines.insert(row, '')
  save(lines)

def delete(lines, row):
  del lines[row]
  save(lines)

def remove(lines, ids):
  for id in ids:
    try:
      lines.remove(id)
    except ValueError:
      print("{id} is not a subtask", file=sys.stderr)
  save(lines)

def save(lines):
  # instead of writing an empty file, delete a blank file.
  if not lines:
    os.unlink(sys.argv[1])
    return

  with open(sys.argv[1], "w") as output:
    blank = False

    # don't allow separators at the beginning or end of the file
    if lines[0] == '':
      del lines[0]
      if not lines:
        os.unlink(sys.argv[1])
        return

    if lines[-1] == '':
      del lines[-1]
      if not lines:
        os.unlink(sys.argv[1])
        return

    # print output, merging consecutive blank lines into a single line.
    for line in lines:
      if line == '':
        if not blank:
          print(line.strip(), file=output)
          blank = True
      else:
        blank = False
        print(line.strip(), file=output)

def main():
  # read the file into a list lists
  print(sys.argv, file=sys.stderr)
  lines = list(map(str.strip, open(sys.argv[1], "r")))

  if not lines:
    return

  match sys.argv[2:]:
    case ["up",     row]:  up(lines, int(row))
    case ["down",   row]:  down(lines, int(row))
    case ["delete", row]:  delete(lines, int(row))
    case ["split",  row]:  separate(lines, int(row))
    case ["remove", *ids]: remove(lines, ids)
    case ["get",    row]:  print(lines[int(row)])
    case invalid: raise ValueError("Invalid command:", invalid)

if __name__ == "__main__":
  main()
