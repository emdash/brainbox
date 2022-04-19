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

class Scanner:

    def __init__(self, line):
        self.line = line

    def next_char(self):
        if len(self.line) and self.line[0] != '\n':
            return self.line[0]
        else:
            raise StopIteration
    
    def accept(self):
        self.line = self.line[1:]

    def accept_line(self):
        ret = self.line.strip()
        self.line = ""
        return ret
    
    def reject(self, chars):
        self.line = chars + self.line
    
    def skip_whitespace(self):
        spaces = ""
        while self.next_char().isspace():
            spaces += self.next_char()
            self.accept()
        return spaces
    
    def count_stars(self):
        count = 0
        while self.next_char() == "*":
            count += 1
            self.accept()
        self.skip_whitespace()
        return count
    
    def get_state(self):
        state = ""
        while self.next_char().isupper():
            state += self.next_char()
            self.accept()
    
        if valid_state(state):
            self.skip_whitespace()
            return state
        else:
            self.reject(state)
            return "INFO"
    
    def get_gloss(self):
        gloss = ""
    
        try:
            while True:
                if self.next_char() == ':':
                    possible_tag = self.next_char()
                    self.accept()
                    if self.next_char().isspace():
                        gloss += possible_tag + self.next_char()
                        possible_tag = ""
                        self.accept()
                    else:
                        self.reject(possible_tag)
                        return gloss
                else:
                    gloss += self.next_char()
                    self.accept()
        except StopIteration:
            # we hit end of input before encountering a ':'
            return gloss
    
    def get_tags(self):
        tags = []
        tag = ""
        
        try:
            self.skip_whitespace()
            while True:
                if self.next_char() == ':':
                    if tag:
                        tags.append(tag.strip("@"))
                    tag = ""
                    self.accept()
                else:
                    tag += self.next_char()
                    self.accept()
        except StopIteration:
            return tags
    
    def process_line(self):
        try:
            if self.next_char() == "#":
                return ("comment", "")
            else:
                line_depth = self.count_stars()
                if line_depth == 0:
                    return ("content", self.accept_line())
                else:
                    state = self.get_state()
                    gloss = self.get_gloss().strip()
                    tags = self.get_tags()
                    return ("heading", (line_depth, state, gloss, tags))
        except StopIteration:
            return ("content", "")

def process_lines():
    path = "."
    stack = []
    ids = gen_ids()
    tattle = open("tattle.org", "w")
    headings = set([])

    os.system("rm -rf org_to_dir")
    os.mkdir("org_to_dir")
    os.chdir("org_to_dir")

    for line in sys.stdin:
        (ty, info) = Scanner(line).process_line()
        print(ty, info)

        if ty == "comment":
            pass
        elif ty == "content":
            open("contents", "a").write(info)
        elif ty == "heading":
            tattle.write(line)
            next_id = ids.__next__()
            line_depth, state, gloss, tags = info
            # save gloss for sanity checking
            headings.add(gloss)

            # adjust stack according to line depth this means that the
            # nesting depth won't necessarily be preserved, but the
            # structural relationship will.
            while line_depth < len(stack):
                stack.pop()
            stack.append(next_id)
            path = os.path.join(*(str(p) for p in stack))
            os.mkdir(path)

            assert not os.path.exists(os.path.join(path, "contents"))
            open(os.path.join(path, "contents"), "w").write(gloss + '\n')
            open(os.path.join(path, "state"),    "w").write(str(state) + '\n')
            if tags:
                open(os.path.join(path, "tags"),     "w").write("\n".join(tags) + '\n')
        else:
            raise ValueError(info)

    # perform a basic sanity check that we have created a directory
    # for every heading in the input.
    actual = actual_headings(os.getcwd(), set([]))
    if headings != actual:
        print("Number of missing headings:", len(headings) - len(actual))
        for line in headings - actual:
            print(line)

def actual_headings(path, actual):
    for subpath in (os.path.join(path, sp) for sp in os.listdir(path)):
        if os.path.isdir(subpath):
            contents = open(os.path.join(subpath, "contents"), "r").readline()
            actual.add(contents)
            actual_headings(os.path.join(path, subpath), actual)
    return actual


assert Scanner("*** TODO Foo bar baz :Bunsen:Rizzo:").process_line() == \
    ('heading', (3, 'TODO', 'Foo bar baz', ['Bunsen', 'Rizzo']))
assert Scanner("*** TODO Foo bar baz").process_line()                == \
    ('heading', (3, 'TODO', 'Foo bar baz', [])) 
assert Scanner("*** Foo bar baz :Bunsen:Rizzo:").process_line()      == \
    ('heading', (3, None, 'Foo bar baz', ['Bunsen', 'Rizzo']))
assert Scanner("*** Foo bar baz").process_line()                     == \
    ('heading', (3, None, 'Foo bar baz', []))   
assert Scanner("*** Foo bar baz :Bunsen:").process_line()            == \
    ('heading', (3, None, 'Foo bar baz', ['Bunsen']))
assert Scanner(":Bunsen:Rizzo:").get_tags()                          == \
    ['Bunsen', 'Rizzo']            
assert Scanner(":Bunsen:").get_tags()                                == \
    ['Bunsen']                                          
assert Scanner("").get_tags()                                        == \
    []

process_lines()
