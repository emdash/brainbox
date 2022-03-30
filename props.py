#! /usr/bin/env python3
#
# Really bare-bones json-based property dictionary. If this gets much
# more sophisticated, I probably need a different approach.
import json
import sys

verb = sys.argv[1]

def set_prop(key, value):
    data = json.load(sys.stdin)
    data[key] = value
    json.dump(data, sys.stdout)

def get_prop(key):
    print(json.load(sys.stdin)[key])

def empty():
    print('{}')

if    verb == "set":   set_prop(sys.argv[2], sys.argv[3])
elif  verb == "get":   get_prop(sys.argv[2])
elif  verb == "empty": empty()
else:
    print(f"unknown command: {verb}", file=sys.stderr)
    exit(1)
