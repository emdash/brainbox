#!/usr/bin/env python

import sys

def swap(a, b):
  (lines[a], lines[b]) = (lines[b], lines[a])

def up(i):
    swap(i, (i - 1) % len(lines))

def down(i):
    swap(i, (i + 1) % len(lines))

print(sys.argv, file=sys.stderr)
lines = list(open(sys.argv[1], "r"))

match sys.argv[2:]:
  case ["up", i]: up(int(i))
  case ["down", i]: down(int(i))
  case ["delete", i]: del lines[int(i)]

with open(sys.argv[1], "w") as output:
  for line in lines:
    print(line.strip(), file=output)
