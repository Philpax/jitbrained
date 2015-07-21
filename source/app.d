import std.stdio;
import std.array;
import std.conv;
import std.file;
import std.algorithm;

import idjit;

BasicBlock compileBF(string input, bool optimize)
{
    BasicBlock block;

    enum Opcode
    {
        Add,
        Subtract,
        Forward,
        Backward,
        Output,
        Input,
        LeftBracket,
        RightBracket
    }

    struct Instruction
    {
        Opcode opcode;
        int value;
    }

    uint labelIndex = 0;
    uint[] labelStack;
    Instruction[] ir;

    void addFoldableInstruction(Opcode opcode)
    {
        if (ir.length && ir[$-1].opcode == opcode && optimize)
            ir[$-1].value++;
        else
            ir ~= Instruction(opcode, 1);
    }

    // Build up IR
    foreach (c; input)
    {
        // *ptr++
        if (c == '+')
            addFoldableInstruction(Opcode.Add);
        // *ptr--
        else if (c == '-')
            addFoldableInstruction(Opcode.Subtract);
        // ptr++
        else if (c == '>')
            addFoldableInstruction(Opcode.Forward);
        // ptr--
        else if (c == '<')
            addFoldableInstruction(Opcode.Backward);
        // putchar(*ptr)
        else if (c == '.')
            ir ~= Instruction(Opcode.Output, 0);
        // *ptr = getchar()
        else if (c == ',')
            ir ~= Instruction(Opcode.Input, 0);
        // while (*ptr) {
        else if (c == '[')
        {
            ir ~= Instruction(Opcode.LeftBracket, labelIndex);

            // Push back the current index to the label stack
            labelStack ~= labelIndex;
            ++labelIndex;
        }
        // }
        else if (c == ']')
        {
            // Grab the last label off the stack, and use it
            ir ~= Instruction(Opcode.RightBracket, labelStack[$-1]);
            labelStack.length--;
        }
    }

    // Dump out IR
    ir.each!writeln();

    // Build machine code
    with (block) with (Register) with (OperandType)
    {
        // Load in array at EBX, as the D ABI guarantees it won't be 
        // trampled by function calls
        mov(EBX, _(EBP, 8));

        foreach (instruction; ir)
        {
            if (instruction.opcode == Opcode.Add)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    inc(_(Byte, EBX));
                else
                    add(_(Byte, EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Subtract)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    dec(_(Byte, EBX));
                else
                    sub(_(Byte, EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Forward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    inc(EBX);
                else if (instruction.value.fitsIn!byte)
                    add(EBX, instruction.value);
                else
                    add(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Backward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    dec(EBX);
                else if (instruction.value.fitsIn!byte)
                    sub(EBX, instruction.value);
                else
                    sub(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Output)
            {
                mov(EAX, _(Byte, EBX));
                call(&putchar);
            }
            else if (instruction.opcode == Opcode.Input)
            {
                call(&getchar);
                mov(_(Byte, EBX), EAX);
            }
            else if (instruction.opcode == Opcode.LeftBracket)
            {
                // Generate label
                auto labelString = instruction.value.to!string();

                cmp(_(Byte, EBX), 0);
                je("r" ~ labelString);
                label("l" ~ labelString);
            }
            else if (instruction.opcode == Opcode.RightBracket)
            {
                // Grab the last label off the stack, and use it
                auto labelString = instruction.value.to!string();

                cmp(_(Byte, EBX), 0);
                jne("l" ~ labelString);
                label("r" ~ labelString);
            }
        }
    }

    return block;
}

void main(string[] args)
{
    if (args.length < 2)
    {
        writeln("jitbrained filepath");
        return;
    }

    bool optimize = !args.canFind("--no-optimize");
    auto testString = args[1].readText();

    BasicBlock preludeBlock, endBlock;

    with (preludeBlock) with (Register)
    {
        if (!optimize)
        {
            push(EBP);
            mov(EBP, ESP);
        }
    }

    with (endBlock) with (Register)
    {
        if (!optimize)
            pop(EBP);

        ret;
    }

    auto assembly = Assembly(preludeBlock, testString.compileBF(optimize), endBlock);
    assembly.finalize();
    writeln("Byte count: ", assembly.buffer.length);
    writeln("-------");

    ubyte[30_000] state;
    assembly(state.ptr);
}