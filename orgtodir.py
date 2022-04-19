#!/usr/bin/env python3

import sys
import os

def gen_ids():
    next = 0
    while True:
        yield next
        next += 1

def valid_state(s):
    return s in {
        "TODO",
        "QUES",
        "WAIT",
        "SHOP",
        "OOS",
        "DONE",
        "CANCELLED",
        "BOUGHT",
        "REMEMBER"
    }

def next_char():
    if len(line) and line[0] != '\n':
        return line[0]
    else:
        raise StopIteration

def accept():
    global line
    line = line[1:]

def reject(chars):
    global line
    line = chars + line

def skip_whitespace():
    spaces = ""
    while next_char().isspace():
        spaces += next_char()
        accept()
    return spaces

def count_stars():
    count = 0
    while next_char() == "*":
        count += 1
        accept()
    skip_whitespace()
    return count

def get_state():
    state = ""
    while next_char().isupper():
        state += next_char()
        accept()

    if valid_state(state):
        skip_whitespace()
        return state
    else:
        reject(state)
        return None

def get_gloss():
    gloss = ""

    try:
        while True:
            if next_char() == ':':
                possible_tag = next_char()
                accept()
                if next_char().isspace():
                    gloss += possible_tag + next_char()
                    possible_tag = ""
                    accept()
                else:
                    reject(possible_tag)
                    return gloss
            else:
                gloss += next_char()
                accept()
    except StopIteration:
        # we hit end of input before encountering a ':'
        return gloss

def get_tags():
    tags = []
    tag = ""

    skip_whitespace()

    try:
        while True:
            if next_char() == ':':
                if tag:
                    tags.append(tag)
                tag = ""
                accept()
            else:
                tag += next_char()
                accept()
    except StopIteration:
        return tags

def process_line():
    global line

    try:
        line = sys.stdin.readline()
        if not line: exit(0)
    
        if next_char() == "#":
            return ("comment", "")
        else:
            line_depth = count_stars()
            if line_depth == 0:
                return ("content", line)
            else:
                state = get_state()
                gloss = get_gloss()
                tags = get_tags()
                return ("heading", (line_depth, state, gloss, tags))
    except StopIteration:
        return ("blank", None)

def make_node(next_id, state, gloss, tags):
    os.mkdir(str(next_id))
    os.chdir(str(next_id))
    contents = open("contents", "w")
    contents.write(gloss)
    open("state","w").write(str(state))
    open("tags", "w").write(" ".join(tags))

def process_lines():
    global line
    depth = 0
    stack = []
    ids = gen_ids()

    os.system("rm -rf org_to_dir")
    os.mkdir("org_to_dir")
    os.chdir("org_to_dir")

    while True:
        (ty, info) = process_line()
        if   ty == "comment": pass
        elif ty == "content": open("contents", "a").write(info)
        elif ty == "heading":
            line_depth, state, gloss, tags = info
            if   line_depth >  depth:
                stack.append((depth, os.getcwd()))
                depth = line_depth
            elif line_depth < depth:
                depth, dir = stack.pop()
                os.chdir(dir)
            make_node(ids.__next__(), state, gloss, tags)
        else: pass
                    
        
line = sys.stdin.readline()
stack = []
process_lines()
