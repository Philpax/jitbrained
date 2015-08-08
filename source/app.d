import std.stdio;
import std.array;
import std.conv;
import std.file;
import std.algorithm;
import std.range;
import std.getopt;
import std.exception;
import std.datetime;
import std.typecons;

import idjit;

void compile(string input, byte[] state, bool optimize, bool dumpIR, bool profile)
{
    Block block;

    enum Opcode
    {
        Add,
        Subtract,
        Forward,
        Backward,
        Output,
        Input,
        LeftBracket,
        RightBracket,

        // No BF equivalents
        Move,
        Move32
    }

    struct Instruction
    {
        Opcode opcode;
        int value;
    }

    uint labelIndex = 0;
    uint[] labelStack;
    Instruction[] ir;

    StopWatch compileTimer, executionTimer;
    compileTimer.start();

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

    if (optimize)
    {
        bool continueRunning = true;

        while (continueRunning)
        {
            bool madeChanges = false;

            // Apply peephole optimizations
            for (size_t i = 0; i < ir.length; ++i)
            {
                enum ZeroPattern = 
                    [Opcode.LeftBracket, Opcode.Subtract, Opcode.RightBracket];

                bool equalsOpcodePattern(const(Opcode[]) pattern)
                {
                    return 
                        i < ir.length - pattern.length && 
                        ir[i..i+pattern.length].equal!((a, b) => a.opcode == b)(pattern);
                }

                if (equalsOpcodePattern(ZeroPattern))
                {
                    ir[i].opcode = Opcode.Move;
                    ir[i].value = 0;
                    ir = ir.remove(i+1, i+2);

                    madeChanges = true;
                }

                enum FourByteLoadPattern =
                    [Opcode.Move, Opcode.Forward, Opcode.Move, 
                    Opcode.Forward, Opcode.Move, Opcode.Forward, Opcode.Move];

                if (equalsOpcodePattern(FourByteLoadPattern))
                {
                    auto slice = ir[i..i+FourByteLoadPattern.length];

                    if (slice.dropOne.stride(2).all!(a => a.value == 1) && 
                        slice.stride(2).all!(a => a.value.fitsIn!byte))
                    {
                        byte a = cast(byte)slice[0].value;
                        byte b = cast(byte)slice[2].value;
                        byte c = cast(byte)slice[4].value;
                        byte d = cast(byte)slice[6].value;
                        uint value = a << 24 | b << 16 | c << 8 | d;

                        ir[i].opcode = Opcode.Move32;
                        // Ensure no conversions take place
                        ir[i].value = *cast(int*)&value;

                        ir[i+1].opcode = Opcode.Forward;
                        ir[i+1].value = 3;

                        ir = ir.remove(tuple(i+2, i+FourByteLoadPattern.length));
                        madeChanges = true;
                    }
                }

                enum FoldableInstructions = 
                    [Opcode.Add, Opcode.Subtract, Opcode.Forward, Opcode.Backward];

                if (i < ir.length - 1 && 
                    ir[i].opcode == ir[i+1].opcode && 
                    FoldableInstructions.canFind(ir[i].opcode))
                {
                    ir[i].value += ir[i+1].value;
                    ir = ir.remove(i+1);
                    madeChanges = true;
                }
            }

            continueRunning = madeChanges;
        }
    }

    if (dumpIR)
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
            else if (instruction.opcode == Opcode.Move)
            {
                mov(bytePtr(EBX), cast(byte)instruction.value);
            }
            else if (instruction.opcode == Opcode.Move32)
            {
                mov(dwordPtr(EBX), instruction.value);
            }
            else
            {
                assert(false, "Invalid IR opcode!");
            }
        }
    }

    block.ret();

    auto assembly = Assembly(block);
    assembly.finalize();

    compileTimer.stop();

    executionTimer.start();
    assembly(state.ptr);
    executionTimer.stop();

    if (profile)
    {
        writeln("------- STATS -------");
        writeln("  Byte count: ", assembly.buffer.length);
        writeln("  Compile time: ", cast(Duration)compileTimer.peek);
        writeln("  Execution time: ", cast(Duration)executionTimer.peek);
        writeln("---------------------");
    }
}

// Reference interpreter; does no optimization
void interpret(string input, byte[] state, bool profile, bool stepDebug)
{
    size_t cell = 0;
    size_t[size_t] jumps;

    size_t[] jumpStack;

    StopWatch executionTimer;
    executionTimer.start();

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
            if (stepDebug)
                writefln("%s: state[%s] = %s", ip, cell, cast(int)state[cell]);
            break;
        case '-':
            state[cell]--;
            if (stepDebug)
                writefln("%s: state[%s] = %s", ip, cell, cast(int)state[cell]);
            break;
        case '>':
            cell++;
            if (stepDebug)
                writefln("%s: cell = %s", ip, cell);
            break;
        case '<':
            cell--;
            if (stepDebug)
                writefln("%s: cell = %s", ip, cell);
            break;
        case '[':
            if (state[cell] == 0)
            {
                if (stepDebug)
                    writefln("%s: if (state[%s] == 0) jmp %s", ip, cell, jumps[ip]+1);
                ip = jumps[ip];
            }
            break;
        case ']':
            if (state[cell] != 0)
            {
                if (stepDebug)
                    writefln("%s: if (state[%s] == 0) jmp %s", ip, cell, jumps[ip]+1);
                ip = jumps[ip];
            }
            break;
        case '.':
            putchar(state[cell]);
            if (stepDebug)
                writefln("%s: putchar(state[%s])", ip, cell);
            break;
        case ',':
            state[cell] = cast(byte)getchar();
            if (stepDebug)
                writefln("%s: state[%s] = getchar()", ip, cell);
            break;
        default:
            break;
        }
    }

    executionTimer.stop();

    if (profile)
    {
        writeln("------- STATS -------");
        writeln("  Execution time: ", cast(Duration)executionTimer.peek);
        writeln("---------------------");
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
    bool dumpIR = false;
    bool profile = false;
    bool stepDebug = false;

    args.getopt(
        "mode", "Control whether to compile or interpret.", &mode,
        "optimize", "Control whether to optimize the generated machine code.", &optimize,
        "dump-ir", "Control whether to dump the final IR.", &dumpIR,
        "step-debug", "Print out the value of the current cell at each interpretation step.", &stepDebug,
        "profile", "Control whether to provide statistics on timings and generated code.", &profile);

    enforce(args.length > 1, "Expected a filename.");
    auto testString = args[1].readText();

    byte[30_000] state;
    if (mode == Mode.compile)
        testString.compile(state, optimize, dumpIR, profile);
    else if (mode == Mode.interpret)
        testString.interpret(state, profile, stepDebug);
}