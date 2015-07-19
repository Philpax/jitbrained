# jitbrained
A JIT interpreter for Brainfuck. 

## Features
* Does direct translation from Brainfuck to x86 assembly

## Potential Improvements
* Optimizing compiler. `++++` currently gets translated to 4x `add byte ptr [ecx], 1`; this could be replaced with `add byte ptr [ecx], 4`. Similar transformations can be made for the other BF instructions.
