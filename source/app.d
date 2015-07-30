import std.stdio;
import std.array;
import std.conv;
import std.file;
import std.algorithm;
import std.range;
import std.getopt;
import std.exception;

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
        mov(EBX, dwordPtr(EBP, 8));

        foreach (instruction; ir)
        {
            if (instruction.opcode == Opcode.Add)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    inc(bytePtr(EBX));
                else
                    add(bytePtr(EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Subtract)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    dec(bytePtr(EBX));
                else
                    sub(bytePtr(EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Forward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    inc(EBX);
                else if (instruction.value < 6)
                    instruction.value.iota.each!(a => inc(EBX));
                else
                    add(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Backward)
            {
                // Avoid emitting a large immediate where possible
                if (instruction.value == 1)
                    dec(EBX);
                else if (instruction.value < 6)
                    instruction.value.iota.each!(a => dec(EBX));
                else
                    sub(EBX, instruction.value);
            }
            else if (instruction.opcode == Opcode.Output)
            {
                mov(EAX, bytePtr(EBX));
                call(&putchar);
            }
            else if (instruction.opcode == Opcode.Input)
            {
                call(&getchar);
                mov(bytePtr(EBX), EAX);
            }
            else if (instruction.opcode == Opcode.LeftBracket)
            {
                // Generate label
                auto labelString = instruction.value.to!string();

                cmp(bytePtr(EBX), 0);
                je("r" ~ labelString);
                label("l" ~ labelString);
            }
            else if (instruction.opcode == Opcode.RightBracket)
            {
                // Grab the last label off the stack, and use it
                auto labelString = instruction.value.to!string();

                cmp(bytePtr(EBX), 0);
                jne("l" ~ labelString);
                label("r" ~ labelString);
            }
        }
    }

    block.ret();

    return block;
}

// Reference interpreter; does no optimization
void interpret(string input, byte[] state)
{
    size_t cell = 0;
    size_t[size_t] jumps;

    size_t[] jumpStack;

    foreach (index, c; input.enumerate())
    {
        if (c == '[')
        {
            jumpStack ~= index;
        }
        else if (c == ']')
        {
            auto matchingIndex = jumpStack[$-1];
            jumpStack.length--;

            jumps[matchingIndex] = index;
            jumps[index] = matchingIndex;
        }
    }

    for (size_t ip = 0; ip < input.length; ++ip)
    {
        switch (input[ip])
        {
        case '+':
            state[cell]++;
            break;
        case '-':
            state[cell]--;
            break;
        case '>':
            cell++;
            break;
        case '<':
            cell--;
            break;
        case '[':
            if (state[cell] == 0)
                ip = jumps[ip];
            break;
        case ']':
            if (state[cell] != 0)
                ip = jumps[ip];
            break;
        case '.':
            putchar(state[cell]);
            break;
        case ',':
            state[cell] = cast(byte)getchar();
            break;
        default:
            break;
        }
    }
}

void main(string[] args)
{
    enum Mode
    {
        compile,
        interpret
    }

    Mode mode = Mode.compile;
    bool optimize = true;

    args.getopt(
        "mode", "Control whether to compile or interpret.", &mode,
        "optimize", "Control whether to optimize the generated machine code.", &optimize);

    enforce(args.length > 1, "Expected a filename.");
    auto testString = args[1].readText();

    byte[30_000] state;
    if (mode == Mode.compile)
    {
        auto assembly = Assembly(testString.compileBF(optimize));
        assembly.finalize();
        writeln("Byte count: ", assembly.buffer.length);
        writeln("-------");

        assembly(state.ptr);
    }
    else if (mode == Mode.interpret)
    {
        testString.interpret(state);
    }
}