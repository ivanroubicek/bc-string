module bc.core.system.linux.dwarf;

version (D_BetterC) {}
else version (linux):

import bc.core.system.linux.elf : Image;
import core.exception : onOutOfMemoryErrorNoGC;
import core.internal.traits : dtorIsNothrow;
import core.stdc.stdio : snprintf;
import core.stdc.string : strlen;

// Selective copy from normally unavailable: https://github.com/dlang/druntime/blob/master/src/rt/backtrace/dwarf.d
// Also combined (and noted) with some only here used module parts

size_t getFirstFrame(const(void*)[] callstack, const char** frameList) nothrow @nogc
{
    import core.internal.execinfo : getMangledSymbolName;

    version (LDC) enum BaseExceptionFunctionName = "_d_throw_exception";
    else enum BaseExceptionFunctionName = "_d_throwdwarf";

    foreach (i; 0..callstack.length)
    {
        auto proc = getMangledSymbolName(frameList[i][0 .. strlen(frameList[i])]);
        if (proc == BaseExceptionFunctionName) return i+1;
    }
    return 0;
}

/// Our customized @nogc variant of https://github.com/dlang/druntime/blob/master/src/rt/backtrace/dwarf.d#L94
size_t dumpCallstack(S)(ref S sink, ref Image image, const(void*)[] callstack, const char** frameList,
    const(ubyte)[] debugLineSectionData) nothrow @nogc
{
    // find address -> file, line mapping using dwarf debug_line
    Array!Location locations;
    if (debugLineSectionData)
    {
        locations.length = callstack.length;
        foreach (size_t i; 0 .. callstack.length)
            locations[i].address = cast(size_t) callstack[i];

        resolveAddresses(debugLineSectionData, locations[], image.baseAddress);
    }

    size_t ret = 0;
    foreach (size_t i; 0 .. callstack.length)
    {
        char[1536] buffer = void;
        size_t bufferLength = 0;

        void appendToBuffer(Args...)(const(char)* format, Args args)
        {
            const count = snprintf(buffer.ptr + bufferLength, buffer.length - bufferLength, format, args);
            assert(count >= 0);
            bufferLength += count;
            if (bufferLength >= buffer.length)
                bufferLength = buffer.length - 1;
        }

        if (i) { sink.put('\n'); ret++; }

        if (locations.length > 0 && locations[i].line != -1)
        {
            bool includeSlash = locations[i].directory.length > 0 && locations[i].directory[$ - 1] != '/';
            if (locations[i].line)
            {
                string printFormat = includeSlash ? "%.*s/%.*s:%d " : "%.*s%.*s:%d ";
                appendToBuffer(
                    printFormat.ptr,
                    cast(int) locations[i].directory.length, locations[i].directory.ptr,
                    cast(int) locations[i].file.length, locations[i].file.ptr,
                    locations[i].line,
                );
            }
            else
            {
                string printFormat = includeSlash ? "%.*s/%.*s " : "%.*s%.*s ";
                appendToBuffer(
                    printFormat.ptr,
                    cast(int) locations[i].directory.length, locations[i].directory.ptr,
                    cast(int) locations[i].file.length, locations[i].file.ptr,
                );
            }
        }
        else
        {
            buffer[0 .. 5] = "??:? ";
            bufferLength = 5;
        }

        char[1024] symbolBuffer = void;
        auto symbol = getDemangledSymbol(frameList[i][0 .. strlen(frameList[i])], symbolBuffer);
        if (symbol.length > 0)
            appendToBuffer("%.*s ", cast(int) symbol.length, symbol.ptr);

        const addressLength = 20;
        const maxBufferLength = buffer.length - addressLength;
        if (bufferLength > maxBufferLength)
        {
            buffer[maxBufferLength-4 .. maxBufferLength] = "... ";
            bufferLength = maxBufferLength;
        }
        appendToBuffer("[0x%zx]", callstack[i]);

        auto output = buffer[0 .. bufferLength];
        sink.put(output);
        ret += bufferLength;
        if (symbol == "_Dmain") break;
    }

    return ret;
}

// Copy: https://github.com/dlang/druntime/blob/master/src/rt/backtrace/dwarf.d#L172
// the lifetime of the Location data is bound to the lifetime of debugLineSectionData
void resolveAddresses(const(ubyte)[] debugLineSectionData, Location[] locations, size_t baseAddress) @nogc nothrow
{
    debug(DwarfDebugMachine) import core.stdc.stdio;

    size_t numberOfLocationsFound = 0;

    const(ubyte)[] dbg = debugLineSectionData;
    while (dbg.length > 0)
    {
        debug(DwarfDebugMachine) printf("new debug program\n");
        const lp = readLineNumberProgram(dbg);

        LocationInfo lastLoc = LocationInfo(-1, -1);
        size_t lastAddress = 0x0;

        debug(DwarfDebugMachine) printf("program:\n");
        runStateMachine(lp,
            (size_t address, LocationInfo locInfo, bool isEndSequence)
            {
                // adjust to ASLR offset
                address += baseAddress;
                debug (DwarfDebugMachine)
                    printf("-- offsetting 0x%zx to 0x%zx\n", address - baseAddress, address);

                foreach (ref loc; locations)
                {
                    // If loc.line != -1, then it has been set previously.
                    // Some implementations (eg. dmd) write an address to
                    // the debug data multiple times, but so far I have found
                    // that the first occurrence to be the correct one.
                    if (loc.line != -1)
                        continue;

                    // Can be called with either `locInfo` or `lastLoc`
                    void update(const ref LocationInfo match)
                    {
                        const sourceFile = lp.sourceFiles[match.file - 1];
                        debug (DwarfDebugMachine)
                        {
                            printf("-- found for [0x%zx]:\n", loc.address);
                            printf("--   file: %.*s\n",
                                   cast(int) sourceFile.file.length, sourceFile.file.ptr);
                            printf("--   line: %d\n", match.line);
                        }
                        // DMD emits entries with FQN, but other implmentations
                        // (e.g. LDC) make use of directories
                        // See https://github.com/dlang/druntime/pull/2945
                        if (sourceFile.dirIndex != 0)
                            loc.directory = lp.includeDirectories[sourceFile.dirIndex - 1];

                        loc.file = sourceFile.file;
                        loc.line = match.line;
                        numberOfLocationsFound++;
                    }

                    // The state machine will not contain an entry for each
                    // address, as consecutive addresses with the same file/line
                    // are merged together to save on space, so we need to
                    // check if our address is within two addresses we get
                    // called with.
                    //
                    // Specs (DWARF v4, Section 6.2, PDF p.109) says:
                    // "We shrink it with two techniques. First, we delete from
                    // the matrix each row whose file, line, source column and
                    // discriminator information is identical with that of its
                    // predecessors.
                    if (loc.address == address)
                        update(locInfo);
                    else if (lastAddress &&
                             loc.address > lastAddress && loc.address < address)
                        update(lastLoc);
                }

                if (isEndSequence)
                {
                    lastAddress = 0;
                }
                else
                {
                    lastAddress = address;
                    lastLoc = locInfo;
                }

                return numberOfLocationsFound < locations.length;
            }
        );

        if (numberOfLocationsFound == locations.length) return;
    }
}

const(char)[] getDemangledSymbol(const(char)[] btSymbol, return ref char[1024] buffer) nothrow @nogc
{
    //import core.demangle; // isn't @nogc :(
    import bc.core.demangle : demangle;
    import core.internal.execinfo : getMangledSymbolName;

    const mangledName = getMangledSymbolName(btSymbol);
    return !mangledName.length ? buffer[0..0] : demangle(mangledName, buffer[]);
    // return mangledName;
}

struct LineNumberProgram
{
    ulong unitLength;
    ushort dwarfVersion;
    ulong headerLength;
    ubyte minimumInstructionLength;
    ubyte maximumOperationsPerInstruction;
    bool defaultIsStatement;
    byte lineBase;
    ubyte lineRange;
    ubyte opcodeBase;
    const(ubyte)[] standardOpcodeLengths;
    Array!(const(char)[]) includeDirectories;
    Array!SourceFile sourceFiles;
    const(ubyte)[] program;
}

struct SourceFile
{
    const(char)[] file;
    size_t dirIndex;
}

struct LocationInfo
{
    int file;
    int line;
}

LineNumberProgram readLineNumberProgram(ref const(ubyte)[] data) @nogc nothrow
{
    // import core.stdc.stdio : printf;
    // printf("!my readLineNumberProgram: ");
    // foreach (b; data[0..data.length > 256 ? 256 : $]) printf("%02X", b);
    // printf("\n");

    const originalData = data;

    LineNumberProgram lp;

    bool is64bitDwarf = false;
    lp.unitLength = data.read!uint();
    if (lp.unitLength == uint.max)
    {
        is64bitDwarf = true;
        lp.unitLength = data.read!ulong();
    }

    const dwarfVersionFieldOffset = cast(size_t) (data.ptr - originalData.ptr);
    lp.dwarfVersion = data.read!ushort();
    debug(DwarfDebugMachine) printf("DWARF version: %d\n", lp.dwarfVersion);
    assert(lp.dwarfVersion < 5, "DWARF v5+ not supported yet");

    lp.headerLength = (is64bitDwarf ? data.read!ulong() : data.read!uint());

    const minimumInstructionLengthFieldOffset = cast(size_t) (data.ptr - originalData.ptr);
    lp.minimumInstructionLength = data.read!ubyte();

    lp.maximumOperationsPerInstruction = (lp.dwarfVersion >= 4 ? data.read!ubyte() : 1);
    lp.defaultIsStatement = (data.read!ubyte() != 0);
    lp.lineBase = data.read!byte();
    lp.lineRange = data.read!ubyte();
    lp.opcodeBase = data.read!ubyte();

    lp.standardOpcodeLengths = data[0 .. lp.opcodeBase - 1];
    data = data[lp.opcodeBase - 1 .. $];

    // A sequence ends with a null-byte.
    static auto readSequence(alias ReadEntry)(ref const(ubyte)[] data)
    {
        alias ResultType = typeof(ReadEntry(data));

        static size_t count(const(ubyte)[] data)
        {
            size_t count = 0;
            while (data.length && data[0] != 0)
            {
                ReadEntry(data);
                ++count;
            }
            return count;
        }

        const numEntries = count(data);

        Array!ResultType result;
        result.length = numEntries;

        foreach (i; 0 .. numEntries)
            result[i] = ReadEntry(data);

        data = data[1 .. $]; // skip over sequence-terminating null

        return result;
    }

    static const(char)[] readIncludeDirectoryEntry(ref const(ubyte)[] data)
    {
        const length = strlen(cast(char*) data.ptr);
        auto result = cast(const(char)[]) data[0 .. length];
        debug(DwarfDebugMachine) printf("dir: %.*s\n", cast(int) length, result.ptr);
        data = data[length + 1 .. $];
        return result;
    }
    lp.includeDirectories = readSequence!readIncludeDirectoryEntry(data);

    static SourceFile readFileNameEntry(ref const(ubyte)[] data)
    {
        const length = strlen(cast(char*) data.ptr);
        auto file = cast(const(char)[]) data[0 .. length];
        debug(DwarfDebugMachine) printf("file: %.*s\n", cast(int) length, file.ptr);
        data = data[length + 1 .. $];

        auto dirIndex = cast(size_t) data.readULEB128();

        data.readULEB128(); // last mod
        data.readULEB128(); // file len

        return SourceFile(
            file,
            dirIndex,
        );
    }
    lp.sourceFiles = readSequence!readFileNameEntry(data);

    const programStart = cast(size_t) (minimumInstructionLengthFieldOffset + lp.headerLength);
    const programEnd = cast(size_t) (dwarfVersionFieldOffset + lp.unitLength);
    lp.program = originalData[programStart .. programEnd];

    data = originalData[programEnd .. $];

    return lp;
}

T read(T)(ref const(ubyte)[] buffer) @nogc nothrow
{
    version (X86)         enum hasUnalignedLoads = true;
    else version (X86_64) enum hasUnalignedLoads = true;
    else                  enum hasUnalignedLoads = false;

    static if (hasUnalignedLoads || T.alignof == 1)
    {
        T result = *(cast(T*) buffer.ptr);
    }
    else
    {
        import core.stdc.string : memcpy;
        T result = void;
        memcpy(&result, buffer.ptr, T.sizeof);
    }

    buffer = buffer[T.sizeof .. $];
    return result;
}

ulong readULEB128(ref const(ubyte)[] buffer) @nogc nothrow
{
    ulong val = 0;
    uint shift = 0;

    while (true)
    {
        ubyte b = buffer.read!ubyte();

        val |= (b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
    }

    return val;
}

long readSLEB128(ref const(ubyte)[] buffer) @nogc nothrow
{
    long val = 0;
    uint shift = 0;
    int size = 8 << 3;
    ubyte b;

    while (true)
    {
        b = buffer.read!ubyte();
        val |= (b & 0x7f) << shift;
        shift += 7;
        if ((b & 0x80) == 0)
            break;
    }

    if (shift < size && (b & 0x40) != 0)
        val |= -(1 << shift);

    return val;
}

alias RunStateMachineCallback =
    bool delegate(size_t address, LocationInfo info, bool isEndSequence)
    @nogc nothrow;

enum StandardOpcode : ubyte
{
    extendedOp = 0,
    copy = 1,
    advancePC = 2,
    advanceLine = 3,
    setFile = 4,
    setColumn = 5,
    negateStatement = 6,
    setBasicBlock = 7,
    constAddPC = 8,
    fixedAdvancePC = 9,
    setPrologueEnd = 10,
    setEpilogueBegin = 11,
    setISA = 12,
}

enum ExtendedOpcode : ubyte
{
    endSequence = 1,
    setAddress = 2,
    defineFile = 3,
    setDiscriminator = 4,
}

struct StateMachine
{
    size_t address = 0;
    uint operationIndex = 0;
    uint fileIndex = 1;
    uint line = 1;
    uint column = 0;
    uint isa = 0;
    uint discriminator = 0;
    bool isStatement;
    bool isBasicBlock = false;
    bool isEndSequence = false;
    bool isPrologueEnd = false;
    bool isEpilogueBegin = false;
}

bool runStateMachine(ref const(LineNumberProgram) lp, scope RunStateMachineCallback callback) @nogc nothrow
{
    StateMachine machine;
    machine.isStatement = lp.defaultIsStatement;

    const(ubyte)[] program = lp.program;
    while (program.length > 0)
    {
        size_t advanceAddressAndOpIndex(size_t operationAdvance)
        {
            const addressIncrement = lp.minimumInstructionLength * ((machine.operationIndex + operationAdvance) / lp.maximumOperationsPerInstruction);
            machine.address += addressIncrement;
            machine.operationIndex = (machine.operationIndex + operationAdvance) % lp.maximumOperationsPerInstruction;
            return addressIncrement;
        }

        ubyte opcode = program.read!ubyte();
        if (opcode < lp.opcodeBase)
        {
            switch (opcode) with (StandardOpcode)
            {
                case extendedOp:
                    size_t len = cast(size_t) program.readULEB128();
                    ubyte eopcode = program.read!ubyte();

                    switch (eopcode) with (ExtendedOpcode)
                    {
                        case endSequence:
                            machine.isEndSequence = true;
                            debug(DwarfDebugMachine) printf("endSequence 0x%zx\n", machine.address);
                            if (!callback(machine.address, LocationInfo(machine.fileIndex, machine.line), true)) return true;
                            machine = StateMachine.init;
                            machine.isStatement = lp.defaultIsStatement;
                            break;

                        case setAddress:
                            size_t address = program.read!size_t();
                            debug(DwarfDebugMachine) printf("setAddress 0x%zx\n", address);
                            machine.address = address;
                            machine.operationIndex = 0;
                            break;

                        case defineFile: // TODO: add proper implementation
                            debug(DwarfDebugMachine) printf("defineFile\n");
                            program = program[len - 1 .. $];
                            break;

                        case setDiscriminator:
                            const discriminator = cast(uint) program.readULEB128();
                            debug(DwarfDebugMachine) printf("setDiscriminator %d\n", discriminator);
                            machine.discriminator = discriminator;
                            break;

                        default:
                            // unknown opcode
                            debug(DwarfDebugMachine) printf("unknown extended opcode %d\n", cast(int) eopcode);
                            program = program[len - 1 .. $];
                            break;
                    }

                    break;

                case copy:
                    debug(DwarfDebugMachine) printf("copy 0x%zx\n", machine.address);
                    if (!callback(machine.address, LocationInfo(machine.fileIndex, machine.line), false)) return true;
                    machine.isBasicBlock = false;
                    machine.isPrologueEnd = false;
                    machine.isEpilogueBegin = false;
                    machine.discriminator = 0;
                    break;

                case advancePC:
                    const operationAdvance = cast(size_t) readULEB128(program);
                    advanceAddressAndOpIndex(operationAdvance);
                    debug(DwarfDebugMachine) printf("advancePC %d to 0x%zx\n", cast(int) operationAdvance, machine.address);
                    break;

                case advanceLine:
                    long ad = readSLEB128(program);
                    machine.line += ad;
                    debug(DwarfDebugMachine) printf("advanceLine %d to %d\n", cast(int) ad, cast(int) machine.line);
                    break;

                case setFile:
                    uint index = cast(uint) readULEB128(program);
                    debug(DwarfDebugMachine) printf("setFile to %d\n", cast(int) index);
                    machine.fileIndex = index;
                    break;

                case setColumn:
                    uint col = cast(uint) readULEB128(program);
                    debug(DwarfDebugMachine) printf("setColumn %d\n", cast(int) col);
                    machine.column = col;
                    break;

                case negateStatement:
                    debug(DwarfDebugMachine) printf("negateStatement\n");
                    machine.isStatement = !machine.isStatement;
                    break;

                case setBasicBlock:
                    debug(DwarfDebugMachine) printf("setBasicBlock\n");
                    machine.isBasicBlock = true;
                    break;

                case constAddPC:
                    const operationAdvance = (255 - lp.opcodeBase) / lp.lineRange;
                    advanceAddressAndOpIndex(operationAdvance);
                    debug(DwarfDebugMachine) printf("constAddPC 0x%zx\n", machine.address);
                    break;

                case fixedAdvancePC:
                    const add = program.read!ushort();
                    machine.address += add;
                    machine.operationIndex = 0;
                    debug(DwarfDebugMachine) printf("fixedAdvancePC %d to 0x%zx\n", cast(int) add, machine.address);
                    break;

                case setPrologueEnd:
                    machine.isPrologueEnd = true;
                    debug(DwarfDebugMachine) printf("setPrologueEnd\n");
                    break;

                case setEpilogueBegin:
                    machine.isEpilogueBegin = true;
                    debug(DwarfDebugMachine) printf("setEpilogueBegin\n");
                    break;

                case setISA:
                    machine.isa = cast(uint) readULEB128(program);
                    debug(DwarfDebugMachine) printf("setISA %d\n", cast(int) machine.isa);
                    break;

                default:
                    debug(DwarfDebugMachine) printf("unknown opcode %d\n", cast(int) opcode);
                    return false;
            }
        }
        else
        {
            opcode -= lp.opcodeBase;
            const operationAdvance = opcode / lp.lineRange;
            const addressIncrement = advanceAddressAndOpIndex(operationAdvance);
            const lineIncrement = lp.lineBase + (opcode % lp.lineRange);
            machine.line += lineIncrement;

            debug (DwarfDebugMachine)
                printf("special %d %d to 0x%zx line %d\n", cast(int) addressIncrement,
                       cast(int) lineIncrement, machine.address, machine.line);

            if (!callback(machine.address, LocationInfo(machine.fileIndex, machine.line), false)) return true;

            machine.isBasicBlock = false;
            machine.isPrologueEnd = false;
            machine.isEpilogueBegin = false;
            machine.discriminator = 0;
        }
    }

    return true;
}

struct Location
{
    const(char)[] file = null;
    const(char)[] directory = null;
    int line = -1;
    size_t address;
}

// See: module rt.util.container.array;
struct Array(T)
{
nothrow:
    @disable this(this);

    ~this()
    {
        reset();
    }

    void reset()
    {
        length = 0;
    }

    @property size_t length() const
    {
        return _length;
    }

    @property void length(size_t nlength)
    {
        import core.checkedint : mulu;

        bool overflow = false;
        size_t reqsize = mulu(T.sizeof, nlength, overflow);
        if (!overflow)
        {
            if (nlength < _length)
                foreach (ref val; _ptr[nlength .. _length]) .destroy(val);
            _ptr = cast(T*).xrealloc(_ptr, reqsize);
            if (nlength > _length)
                foreach (ref val; _ptr[_length .. nlength]) .initialize(val);
            _length = nlength;
        }
        else
            onOutOfMemoryErrorNoGC();

    }

    @property bool empty() const
    {
        return !length;
    }

    @property ref inout(T) front() inout
    in { assert(!empty); }
    do
    {
        return _ptr[0];
    }

    @property ref inout(T) back() inout
    in { assert(!empty); }
    do
    {
        return _ptr[_length - 1];
    }

    ref inout(T) opIndex(size_t idx) inout
    in { assert(idx < length); }
    do
    {
        return _ptr[idx];
    }

    inout(T)[] opSlice() inout
    {
        return _ptr[0 .. _length];
    }

    inout(T)[] opSlice(size_t a, size_t b) inout
    in { assert(a < b && b <= length); }
    do
    {
        return _ptr[a .. b];
    }

    alias length opDollar;

    void insertBack()(auto ref T val)
    {
        import core.checkedint : addu;

        bool overflow = false;
        size_t newlength = addu(length, 1, overflow);
        if (!overflow)
        {
            length = newlength;
            back = val;
        }
        else
            onOutOfMemoryErrorNoGC();
    }

    void popBack()
    {
        length = length - 1;
    }

    void remove(size_t idx)
    in { assert(idx < length); }
    do
    {
        foreach (i; idx .. length - 1)
            _ptr[i] = _ptr[i+1];
        popBack();
    }

    void swap(ref Array other)
    {
        auto ptr = _ptr;
        _ptr = other._ptr;
        other._ptr = ptr;
        immutable len = _length;
        _length = other._length;
        other._length = len;
    }

    invariant
    {
        assert(!_ptr == !_length);
    }

private:
    T* _ptr;
    size_t _length;
}

import core.stdc.stdlib : malloc, realloc, free;

// See: rt.util.container.common
void* xrealloc(void* ptr, size_t sz) nothrow @nogc
{
    import core.exception;

    if (!sz) { .free(ptr); return null; }
    if (auto nptr = .realloc(ptr, sz)) return nptr;
    .free(ptr); onOutOfMemoryErrorNoGC();
    assert(0);
}

void destroy(T)(ref T t) if (is(T == struct) && dtorIsNothrow!T)
{
    scope (failure) assert(0); // nothrow hack
    object.destroy(t);
}

void destroy(T)(ref T t) if (!is(T == struct))
{
    t = T.init;
}

void initialize(T)(ref T t) if (is(T == struct))
{
    import core.stdc.string;
    static if (__traits(isPOD, T)) // implies !hasElaborateAssign!T && !hasElaborateDestructor!T
        t = T.init;
    else static if (__traits(isZeroInit, T))
        memset(&t, 0, T.sizeof);
    else
        memcpy(&t, typeid(T).initializer().ptr, T.sizeof);
}

void initialize(T)(ref T t) if (!is(T == struct))
{
    t = T.init;
}
