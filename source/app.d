import std.stdio;
import std.array;
import std.conv;

import idjit;

BasicBlock compileNaiveBF(string input)
{
    BasicBlock block;
    uint labelIndex = 0;
    uint[] labelStack;

    with (block) with (Register) with (OperandType)
    {
        // Load in array at EBX, as the D ABI guarantees it won't be 
        // trampled by function calls
        mov(EBX, _(EBP, 8));

        foreach (c; input)
        {
            // *ptr++
            if (c == '+')
            {
                add(_(Byte, EBX), 1);
            }
            // *ptr--
            else if (c == '-')
            {
                sub(_(Byte, EBX), 1);
            }
            // ptr++
            else if (c == '>')
            {
                inc(EBX);
            }
            // ptr--
            else if (c == '<')
            {
                dec(EBX);
            }
            // putchar(*ptr)
            else if (c == '.')
            {
                mov(EAX, _(Byte, EBX));
                call(&putchar);
            }
            // *ptr = getchar()
            else if (c == ',')
            {
                call(&getchar);
                mov(_(Byte, EBX), EAX);
            }
            // while (*ptr) {
            else if (c == '[')
            {
                // Generate label
                auto labelString = labelIndex.to!string();

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                je("r" ~ labelString);
                label("l" ~ labelString);

                // Push back the current index to the label stack
                labelStack ~= labelIndex;
                ++labelIndex;
            }
            // }
            else if (c == ']')
            {
                // Grab the last label off the stack, and use it
                auto labelString = labelStack[$-1].to!string();
                labelStack.length--;

                mov(EAX, _(Byte, EBX));
                cmp(EAX, 0);
                jne("l" ~ labelString);
                label("r" ~ labelString);
            }
        }
    }

    return block;
}

void main(string[] args)
{
    BasicBlock preludeBlock, endBlock;

    with (preludeBlock) with (Register)
    {
        push(EBP);
        mov(EBP, ESP);
    }

    with (endBlock) with (Register)
    {
        pop(EBP);
        ret;
    }

    // Hello world (https://en.wikipedia.org/wiki/Brainfuck#Hello_World.21)
    /*
    immutable testString = 
        `++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]` ~
        `>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.`;
    */
    // Reverse (http://rosettacode.org/wiki/Reverse_a_string#Brainf.2A.2A.2A)
    immutable testString = 
        `,----- ----- [+++++ +++++ > , ----- -----]` ~
        `<[.<]` ~
        `+++++ +++++ +++ . --- .`;

    auto assembly = Assembly(preludeBlock, testString.compileNaiveBF(), endBlock);
    assembly.finalize();
    writeln("Byte count: ", assembly.buffer.length);

    ubyte[30_000] state;
    assembly(state.ptr);
}