#!/usr/bin/env python
# shitty script to convert a binary file to a Lua string.char(0xde, 0xad, 0xbe, 0xef, ...) statement

import sys

f = open(sys.argv[1], 'rb')
data = f.read()
print(len(data))
print('string.char(', end='')
for (i, b) in enumerate(data):
    print(hex(b), end='')
    if i != len(data) - 1:
        print(', ', end='')

print(')')
    
