module ddmd.ctfe.ctfe_bc;

import ddmd.expression;
import ddmd.declaration : FuncDeclaration, VarDeclaration, Declaration,
    SymbolDeclaration;
import ddmd.dsymbol;
import ddmd.dstruct;
import ddmd.init;
import ddmd.mtype;
import ddmd.statement;
import ddmd.visitor;
import ddmd.arraytypes : Expressions;

/**
 * Written By Stefan Koch in 2016
 */

import std.conv : to;

struct BCBlockJump
{
    BCAddr at;
    bool toBegin;
}

struct UnresolvedGoto
{
    void* ident;
    BCBlockJump[ubyte.max] jumps;
    uint jumpCount = 1;
}

struct SwitchFixupEntry
{
    BCAddr atIp;
    alias atIp this;
    /// 0 means jump after the swich
    /// -1 means jump to the defaultStmt
    /// positve numbers denote which case to jump to
    int fixupFor;
}

struct BoolExprFixupEntry
{
    BCAddr unconditional;
    CndJmpBegin conditional;

    this(BCAddr unconditional) pure
    {
        this.unconditional = unconditional;
    }

    this(CndJmpBegin conditional) pure
    {
        this.conditional = conditional;
    }
}

struct UnrolledLoopState
{
    BCAddr[255] continueFixups;
    uint continueFixupCount;

    BCAddr[255] breakFixups;
    uint breakFixupCount;
}

struct SwitchState
{
    SwitchFixupEntry[255] switchFixupTable;
    uint switchFixupTableCount;

    BCLabel[255] beginCaseStatements;
    uint beginCaseStatementsCount;
}

Expression evaluateFunction(FuncDeclaration fd, Expressions* args, Expression thisExp)
{
    Expression[] _args;
    /*if (thisExp)
    {
        debug (ctfe)
            assert(0, "Implicit State via _this_ is not supported right now");
        return null;
    }*/

    if (args)
        foreach (a; *args)
        {
            _args ~= a;
        }

    return evaluateFunction(fd, _args ? _args : [], thisExp);
}

import ddmd.ctfe.bc_common;
enum cacheBC = 1;
enum UseLLVMBackend = 0;
enum UsePrinterBackend = 0;
enum UseCBackend = 0;

static if (UseLLVMBackend)
{
    import ddmd.ctfe.bc_llvm_backend;

    alias BCGenT = LLVM_BCGen;
}
else static if (UseCBackend)
{
    import ddmd.ctfe.bc_c_backend;

    alias BCGenT = C_BCGen;
}
else static if (UsePrinterBackend)
{
    import ddmd.ctfe.bc_printer_backend;

    alias BCGenT = Print_BCGen;
}
else
{
    import ddmd.ctfe.bc;

    alias BCGenT = BCGen;
}
__gshared SharedCtfeState!BCGenT _sharedCtfeState;
__gshared SharedCtfeState!BCGenT* sharedCtfeState = &_sharedCtfeState;

ulong evaluateUlong(Expression e)
{
    return e.toUInteger;
}

Expression evaluateFunction(FuncDeclaration fd, Expression[] args, Expression _this = null)
{
    __gshared static arg_bcv = new BCV!(BCGenT)(null, null);

    import std.stdio;

    static if (cacheBC && is(typeof(_sharedCtfeState.functionCount)) && is(BCGenT == BCGen))
    {
        if (auto fnIdx = _sharedCtfeState.getFunctionIndex(fd))
        {
            auto fn = _sharedCtfeState.functions[fnIdx - 1];
            arg_bcv.arguments.length = fn.nArgs;
            BCValue[] bc_args;
            bc_args.length = fn.nArgs;
            arg_bcv.beginArguments();
            foreach(i, arg;args)
            {
                bc_args[i] = arg_bcv.genExpr(arg);
            }
            arg_bcv.endArguments();

            auto retval = interpret_(fn.byteCode, bc_args,
                &_sharedCtfeState.heap, _sharedCtfeState.functions.ptr);

            return toExpression(retval, (cast(TypeFunction)fd.type).nextOf, &_sharedCtfeState.heap);
        }
    }
 
    //__gshared static BCV!BCGenT bcv;
    static uint recursionLevel; 
    debug (ctfe)
        writeln("recursionLevel: ", recursionLevel);
    //writeln("Evaluating function: ", fd.toString);
    import ddmd.identifier;
    import std.datetime : StopWatch;

    StopWatch hiw;
    hiw.start();
    _sharedCtfeState.initHeap();
    hiw.stop();
    writeln("Initalizing heap took " ~ hiw.peek.usecs.to!string ~ " usecs");

    StopWatch csw;
    StopWatch isw;
 
    writeln("trying ", fd.toString);
    //if (bcv is null)
    //{
    isw.start();
    scope BCV!BCGenT bcv = new BCV!BCGenT(fd, null); 
    //bcv.clear();
    bcv.Initialize();
    isw.stop();
    csw.start();
    //}
    bcv.visit(fd);
    csw.stop;
    writeln("Creating and Initialzing bcGen took ", isw.peek.usecs.to!string, " usecs");
    writeln("Generting bc for ", fd.ident.toString, " took ", csw.peek.usecs.to!string,
        " usecs");
 
    debug (ctfe)
    {
        import std.stdio;
        import std.algorithm;

        bcv.vars.keys.each!(k => (cast(VarDeclaration) k).print);
        bcv.vars.writeln;
        writeln("Initializing bcGen took " ~ isw.peek.usecs.to!string ~ "usecs");
        writeln("Generting bc took " ~ csw.peek.usecs.to!string ~ "usecs");

        writeln(" stackUsage = ", (bcv.sp - 4).to!string ~ " byte");
        writeln(" TemporaryCount = ", (bcv.temporaryCount).to!string);
    }

    if (!bcv.IGaveUp)
    {
        import std.algorithm;
        import std.range;
        import std.datetime : StopWatch;
        import std.stdio;

        StopWatch sw;
        sw.start();
        bcv.beginArguments();
        BCValue[] bc_args;
        bc_args.length = args.length;
        bcv.beginArguments();
        foreach(i, arg;args)
        {
            bc_args[i] = bcv.genExpr(arg);
        }
        bcv.endArguments();
        if (bcv.IGaveUp)
        {
            writeln("Ctfe died on argument processing");
            return null;
        }
        writeln("BC complied: ", fd.ident.toString);
        bcv.endArguments();
        bcv.Finalize();
        
        static if (UseLLVMBackend)
        {
            bcv.gen.print();

            auto retval = bcv.gen.interpret(bc_args, &_sharedCtfeState.heap);
        }
        else static if (UseCBackend)
        {
            auto retval = BCValue.init;
            writeln(bcv.functionalize);
            return null;
        }
        else static if (UsePrinterBackend)
        {
            auto retval = BCValue.init;
            writeln(bcv.result);
            return null;
        }
        else
        {
            debug (ctfe)
            {
                import std.stdio;

                writeln("I have ", _sharedCtfeState.functionCount, " functions!");
                bcv.gen.byteCodeArray[0 .. bcv.ip].printInstructions.writeln();

            }
            auto retval = interpret_(bcv.byteCodeArray[0 .. bcv.ip], bc_args,
                &_sharedCtfeState.heap, _sharedCtfeState.functions.ptr);
        }
        sw.stop();
        import std.stdio;

        auto ft = cast(TypeFunction) fd.type;
        assert(ft.nextOf);

        writeln("Executing bc took " ~ sw.peek.usecs.to!string ~ " us");
        {
            StopWatch esw;
            esw.start();
            if (auto exp = toExpression(retval, ft.nextOf, &_sharedCtfeState.heap))
            {
                esw.stop();
                writeln("Converting to AST Expression took " ~ esw.peek.usecs.to!string ~ "us");
                return exp;
            }
            else
            {
                return null;
            }
        }
    }
    else
    {
        static if (UsePrinterBackend)
        {
            auto retval = BCValue.init;
            writeln(bcv.result);
            return null;
        }
        writeln("Gavup!");
        return null;

    }

}
/*
 * params(e) The Expression to test.
 * Retruns 1 if the expression is __ctfe, returns -1 if the expression is !__ctfe, 0 for anything else;
 */
private int is__ctfe(const Expression _e)
{
    import ddmd.tokens : TOK;
    import ddmd.id : Id;

    int retval = 1;
    Expression e = cast(Expression) _e;

switch_head:
    switch (e.op)
    {
    case TOK.TOKvar:
        {
            if ((cast(VarExp) e).var.ident == Id.ctfe)
                return retval;
            else
                goto default;
        }

    case TOK.TOKnot:
        {
            e = (cast(NotExp) e).e1;
            retval = (retval == -1 ? 1 : -1);
            goto switch_head;
        }

    case TOK.TOKidentifier:
        {
            if ((cast(IdentifierExp) e).ident == Id.ctfe)
                return retval;
            goto default;
        }

    default:
        {
            return 0;
        }

    }
}

string toString(T)(T value) if (is(T : Statement) || is(T : Declaration)
        || is(T : Expression) || is(T : Dsymbol) || is(T : Type))
{
    import std.string : fromStringz;

    const(char)* cPtr = value.toChars();

    static if (is(typeof(T.loc)))
    {
        const(char)* lPtr = value.loc.toChars();
        string result = cPtr.fromStringz.idup ~ "\t" ~ lPtr.fromStringz.idup;
    }
    else
    {
        string result = cPtr.fromStringz.idup;
    }

    return result;
}

struct BCSlice
{
    BCType elementType;
}

struct BCPointer
{
    BCType elementType;
    uint indirectionCount;
}

struct BCArray
{
    BCType elementType;

    uint length;

    const(uint) arraySize() const
    {
        return length * basicTypeSize(elementType);
    }

    const(uint) arraySize(const SharedCtfeState!BCGenT* sharedState) const
    {
        return sharedState.size(elementType) * length;
    }
}

struct BCStruct
{
    BCType[ubyte.max] memberTypes;
    uint memberTypeCount;

    uint size;

    void addField(SharedCtfeState!BCGenT* state, const BCType bct)
    {
        memberTypes[memberTypeCount++] = bct;
        size += state.size(bct);
    }

    const int offset(const int idx)
    {
        int _offset;
        if (idx == -1)
            return -1;

        assert(idx < memberTypeCount);

        foreach (t; memberTypes[0 .. idx])
        {
            _offset += align4(sharedCtfeState.size(t));
        }

        return _offset;
    }

}

struct SharedCtfeState(BCGenT)
{
    uint _threadLock;
    BCHeap heap;
    uint[ushort.max] Stack; // a Stack of 64K*4 is the Hard Limit;    //Type 0 beeing the terminator for chainedTypes
    StructDeclaration[ubyte.max * 4] structDeclPointers;
    TypeSArray[ubyte.max * 4] sArrayTypePointers;
    TypeDArray[ubyte.max * 4] dArrayTypePointers;
    TypePointer[ubyte.max * 4] pointerTypePointers;
    BCTypeVisitor btv; 

    BCStruct[ubyte.max * 4] structs;
    uint structCount;
    BCArray[ubyte.max * 4] arrays;
    uint arrayCount;
    BCSlice[ubyte.max * 4] slices;
    uint sliceCount;
    BCPointer[ubyte.max * 4] pointers;
    uint pointerCount;
    RetainedError[ubyte.max * 4] errors;
    uint errorCount;
    

    void initHeap(uint maxHeapSize = 2 ^^ 24)
    {
        import ddmd.root.rmem;
        void *mem = allocmemory(maxHeapSize * uint.sizeof);
        heap._heap = (cast(uint*)mem)[0 .. maxHeapSize];
        heap.heapMax = (maxHeapSize) - 32;
    }

    void initTypeVisitor()
    {
        btv = new BCTypeVisitor();
    }

    static if (is(BCFunction))
    {
        static assert(is(typeof(BCFunction.funcDecl) == void*));
        BCFunction[ubyte.max * 4] functions;
        uint functionCount = 1;
    }
    else
    {
        pragma(msg, BCGenT, " does not support BCFunctions");
    }

    bool addStructInProgress;

    import ddmd.tokens : Loc;

    BCValue addError(Loc loc, string msg)
    {
        errors[errorCount++] = RetainedError(loc, msg);
        auto retval = BCValue(Imm32(errorCount));
        retval.vType = BCValueType.Error;
        return retval;
    }

    int getArrayIndex(TypeSArray tsa)
    {
        foreach (i, sArrayTypePtr; sArrayTypePointers[0 .. arrayCount])
        {
            if (tsa == sArrayTypePtr)
            {
                return cast(uint) i + 1;
            }
        }
        // if we get here the type was not found and has to be registerd.
        auto elemType = btv.toBCType(tsa.nextOf);
        auto arraySize = evaluateUlong(tsa.dim);
        assert(arraySize < uint.max);
        arrays[++arrayCount] = BCArray(elemType, cast(uint) arraySize);
        return arrayCount;
    }

    int getFunctionIndex(FuncDeclaration fd)
    {
        static if (is(typeof(functions)))
        {
            foreach (i, bcFunc; functions[0 .. functionCount])
            {
                if (bcFunc.funcDecl == cast(void*) fd)
                {
                    return cast(uint) i + 1;
                }
            }
        }
        // if we get here the type was not found and has to be registerd.

        return 0;
    }

    int getStructIndex(StructDeclaration sd)
    {
        if (sd is null)
            return 0;

        foreach (i, structDeclPtr; structDeclPointers[0 .. structCount])
        {
            if (structDeclPtr == sd)
            {
                return cast(uint) i + 1;
            }
        }

        //register structType
        auto oldStructCount = structCount;
        btv.visit(sd);
        assert(oldStructCount < structCount);
        return structCount;
    }

    int getPointerIndex(TypePointer pt)
    {
        if (pt is null)
            return 0;

        foreach (i, pointerTypePtr; pointerTypePointers[0 .. pointerCount])
        {
            if (pointerTypePtr == pt)
            {
                return cast(uint) i + 1;
            }
        }

        //register pointerType
        auto oldPointerCount = pointerCount;
        btv.visit(pt);
        assert(oldPointerCount < pointerCount);
        return pointerCount;
    }

    int getSliceIndex(TypeDArray tda)
    {
        if (!tda)
            return 0;

        foreach (i, slice; dArrayTypePointers[0 .. sliceCount])
        {
            if (slice == tda)
            {
                return cast(uint) i + 1;
            }
        }
        //register structType
        auto elemType = btv.toBCType(tda.nextOf);
        if (slices.length - 1 > sliceCount)
        {
            dArrayTypePointers[sliceCount] = tda;
            slices[sliceCount++] = BCSlice(elemType);
            return sliceCount;
        }
        else
        {
            //debug (ctfe)
            assert(0, "SliceTypeArray overflowed");
        }
    }

    //NOTE beginStruct and endStruct are not threadsafe at this point.

    BCStruct* beginStruct(StructDeclaration sd)
    {
        structDeclPointers[structCount] = sd;
        return &structs[structCount];
    }

    const(BCType) endStruct(BCStruct* s)
    {
        return BCType(BCTypeEnum.Struct, structCount++);
    }
    /*
    string getTypeString(BCType type)
    {

    }
    */
    const(uint) size(const BCType type) const
    {
        static __gshared sizeRecursionCount = 1;
        sizeRecursionCount++;
        import std.stdio;

        if (sizeRecursionCount > 3000)
        {
            writeln("Calling Size for (", type.type.to!string, ", ",
                type.typeIndex.to!string, ")");
            //writeln(getTypeString(bct));
            return 0;
        }

        scope (exit)
        {
            sizeRecursionCount--;
        }
        if (isBasicBCType(type))
        {
            return align4(basicTypeSize(type));
        }

        switch (type.type)
        {
        case BCTypeEnum.Struct:
            {
                uint _size;
                assert(type.typeIndex <= structCount);
                BCStruct _struct = structs[type.typeIndex - 1];

                foreach (i, memberType; _struct.memberTypes[0 .. _struct.memberTypeCount])
                {
                    if (memberType == type) // bail out on recursion.
                        return 0;

                    _size += align4(
                        isBasicBCType(memberType) ? basicTypeSize(memberType) : this.size(
                        memberType));
                }

                return _size;

            }

        case BCType.Array:
            {
                assert(type.typeIndex <= arrayCount);
                BCArray _array = arrays[type.typeIndex];
                debug (ctfe)
                {
                    import std.stdio;

                    writeln("ArrayElementSize :", size(_array.elementType));
                }
                return size(_array.elementType) * _array.length;
            }

        default:
            {
                debug (ctfe)
                    assert(0, "cannot get size for BCType." ~ to!string(type.type));
                return 0;
            }

        }
    }
}

struct RetainedError // Name is still undecided
{
    import ddmd.tokens : Loc;

    Loc loc;
    string msg;
}

Expression toExpression(const BCValue value, Type expressionType,
    const BCHeap* heapPtr = &_sharedCtfeState.heap)
{
    import ddmd.parse : Loc;

    Expression result;

    if (value.vType == BCValueType.Error)
    {
        assert(value.type == i32Type);
        assert(value.imm32, "Errors are 1 based indexes");
        import ddmd.ctfeexpr : CTFEExp;

        auto err = _sharedCtfeState.errors[value.imm32 - 1];
        import ddmd.errors;

        error(err.loc, err.msg.ptr);
        return CTFEExp.cantexp;
    }

    if (expressionType.isString)
    {
        import ddmd.lexer : Loc;

        auto offset = value.heapAddr.addr;

        debug (ctfe)
        {
            import std.stdio;

            writeln("offset : ", offset, "len : ", heapPtr._heap[offset]);
            writeln(heapPtr.heapSize,
                (cast(char*)(heapPtr._heap.ptr + offset + 1))[0 .. heapPtr._heap[offset]]);

        }

        auto length = heapPtr._heap.ptr[offset];
        //TODO consider to use allocmemory directly instead of going through druntime.

        auto resultString = (cast(void*)(heapPtr._heap.ptr + offset + 1))[0 .. length].dup;
        result = new StringExp(Loc(), resultString.ptr, length);
        (cast(StringExp)result).ownedByCtfe = OWNEDctfe;

        //HACK to avoid TypePainting!
        result.type = expressionType;

    }
    else
        switch (expressionType.ty)
    {
    case Tstruct:
        {
            auto sd = (cast(TypeStruct) expressionType).sym;
            auto si = _sharedCtfeState.getStructIndex(sd);
            assert(si);
            BCStruct _struct = _sharedCtfeState.structs[si - 1];
            Expressions* elmExprs = new Expressions();
            uint offset = 0;
            foreach (idx, member; _struct.memberTypes[0 .. _struct.memberTypeCount])
            {
                Expression elm = new IntegerExp(*(heapPtr._heap.ptr + value.heapAddr.addr + offset));
                elm.type = sd.fields[idx].type;
                elmExprs.insert(idx, elm);
                offset += align4(_sharedCtfeState.size(member));
            }
            result = new StructLiteralExp(Loc(), sd, elmExprs);
            (cast(StructLiteralExp)result).ownedByCtfe = OWNEDctfe;
            result.type = expressionType;
        }
        break;
    case Tarray:
        {
            auto tda = cast(TypeDArray) expressionType;
            
            auto baseType = _sharedCtfeState.btv.toBCType(tda.nextOf);
            auto elmLength = align4(_sharedCtfeState.size(baseType));
            auto arrayLength = heapPtr._heap[value.heapAddr.addr];
            debug (ctfe)
            {
                import std.stdio;

                writeln("value ", value.toString);
            }
            debug (ctfe)
            {
                import std.stdio;

                foreach (idx; 0 .. heapPtr.heapSize)
                {
                    // writefln("%d %x", idx, heapPtr._heap[idx]);
                }
            }

            Expressions* elmExprs = new Expressions();

            uint offset = 4;
            debug (ctfe)
            {
                import std.stdio;

                writeln("building Array of Length ", arrayLength);
            }
            foreach (idx; 0 .. arrayLength)
            {
                elmExprs.insert(idx,
                    toExpression(
                    BCValue(Imm32(*(heapPtr._heap.ptr + value.heapAddr.addr + offset))),
                    tda.nextOf));
                offset += elmLength;
            }

            result = new ArrayLiteralExp(Loc(), elmExprs);
            (cast(ArrayLiteralExp)result).ownedByCtfe = OWNEDctfe;
            result.type = expressionType;
        }
        break;
    case Tsarray:
        {
            auto tsa = cast(TypeSArray) expressionType;
            assert(heapPtr._heap[value.heapAddr.addr] == evaluateUlong(tsa.dim),
                "static arrayLength mismatch: " ~ to!string(heapPtr._heap[value.heapAddr.addr]) ~ " != " ~ to!string(
                evaluateUlong(tsa.dim)));
            goto default;
        }
        break;
    case Tbool:
        {
            assert(value.imm32 == 0 || value.imm32 == 1, "Not a valid bool");
            result = new IntegerExp(value.imm32);
        }
        break;
    case Tint32, Tuns32, Tint16, Tuns16, Tint8, Tuns8:
        {
            result = new IntegerExp(value.imm32);
        }
        break;
    case Tint64, Tuns64:
        {
            // result = new IntegerExp(value.imm64);
            // for now bail out on 64bit values
        }
        break;
    case Tpointer:
        {
            result = new PtrExp(Loc.init, new IntegerExp(value.imm32));
        }
        break;
    default:
        {
            debug (ctfe)
                assert(0, "Cannot convert to " ~ expressionType.toString!Type ~ " yet.");
        }
    }

    return result;
}

extern (C++) final class BCTypeVisitor : Visitor 
{
    alias visit = super.visit;

    static const(BCType) toBCType(Type t) /*pure*/
    {
        assert(t !is null);
        TypeBasic bt = t.isTypeBasic;
        if (bt)
        {
            switch (bt.ty)
            {
            case ENUMTY.Tbool:
                //return BCType(BCTypeEnum.i1);
                return BCType(BCTypeEnum.i32);
            case ENUMTY.Tchar:
            case ENUMTY.Tdchar:
                return BCType(BCTypeEnum.Char);
            case ENUMTY.Tint8:
            case ENUMTY.Tuns8:
                //return BCType(BCTypeEnum.i8);
            case ENUMTY.Tint16:
            case ENUMTY.Tuns16:
                //return BCType(BCTypeEnum.i16);
            case ENUMTY.Tint32:
            case ENUMTY.Tuns32:
                return BCType(BCTypeEnum.i32);
            case ENUMTY.Tint64:
            case ENUMTY.Tuns64:
                return BCType(BCTypeEnum.i64);
            default:
                return BCType.init;
            }
        }
        else
        {
            if (t.isString)
            {
                return BCType(BCTypeEnum.String);
            }
            else if (t.ty == Tstruct)
            {
                auto sd = (cast(TypeStruct) t).sym;
                return BCType(BCTypeEnum.Struct, _sharedCtfeState.getStructIndex(sd));
            }
            else if (t.ty == Tarray)
            {
                auto tarr = (cast(TypeDArray) t);
                return BCType(BCTypeEnum.Slice, _sharedCtfeState.getSliceIndex(tarr));
            }
            else if (t.ty == Tenum)
            {
                return toBCType(t.toBasetype);
            }
            else if (t.ty == Tsarray)
            {
                auto tsa = cast(TypeSArray) t;
                return BCType(BCTypeEnum.Array, _sharedCtfeState.getArrayIndex(tsa));
            }
            else if (t.ty == Tpointer)
            {
                if (t.nextOf.ty == Tint32 || t.nextOf.ty == Tuns32)
                    return BCType(BCTypeEnum.i32Ptr);
                //else if (auto pi =_sharedCtfeState.getPointerIndex(cast(TypePointer)t))
                //{
                //return BCType(BCTypeEnum.Ptr, pi);
                //}
            else
                {
                    uint indirectionCount = 1;
                    Type baseType = t.nextOf;
                    while (baseType.ty == Tpointer)
                    {
                        indirectionCount++;
                        baseType = baseType.nextOf;
                    }
                    _sharedCtfeState.pointerTypePointers[_sharedCtfeState.pointerCount] = 
                       cast(TypePointer)t;
                    _sharedCtfeState.pointers[_sharedCtfeState.pointerCount++] = BCPointer(
                        toBCType(baseType), indirectionCount);
                    return BCType(BCTypeEnum.Ptr, _sharedCtfeState.pointerCount);
                }
            }

            debug (ctfe)
                assert(0, "NBT Type unsupported " ~ (cast(Type)(t)).toString);

            return BCType.init;
        }
    }

    override void visit(StructDeclaration sd)
    {
        auto st = sharedCtfeState.beginStruct(sd);

        foreach (sMember; sd.fields)
        {
            st.addField(&_sharedCtfeState, toBCType(sMember.type));
        }

        sharedCtfeState.endStruct(st);
    }


}


extern (C++) final class BCV(BCGenT) : Visitor
{
    uint unresolvedGotoCount;
    uint breakFixupCount;
    uint continueFixupCount;
    uint fixupTableCount;

    BCGenT gen = void;
    alias gen this;

    // for now!
    BCValue[] arguments;
    BCType[] parameterTypes;

    typeof(this)* parent;

    uint processedArgs;
    bool processingArguments;
    bool insideArgumentProcessing;
    bool processingParameters;
    bool insideArrayLiteralExp;

    bool IGaveUp;

    UnrolledLoopState* unrolledLoopState;
    SwitchState* switchState = new SwitchState();
    SwitchFixupEntry* switchFixup;

    FuncDeclaration me;
    bool inReturnStatement;

    UnresolvedGoto[ubyte.max] unresolvedGotos = void;
    BCAddr[ubyte.max] breakFixups = void;
    BCAddr[ubyte.max] continueFixups = void;
    BoolExprFixupEntry[ubyte.max] fixupTable = void;

    alias visit = super.visit;

    const(BCType) toBCType(Type t)
    {
        auto bct = _sharedCtfeState.btv.toBCType(t);
        if(bct != BCType.init)
        {
            return bct;
        }
        else
        {
            IGaveUp = true;
	    debug (ctfe)
                assert(0, "Type unsupported " ~ (cast(Type)(t)).toString());
            else
                return BCType.init;
        }
    }

    import ddmd.tokens;

    BCBlock[void* ] labeledBlocks;
    bool ignoreVoid;
    BCValue[void* ] vars;

    //BCValue _this;
    Expression _this;

    BCBlock* currentBlock;
    BCValue currentIndexed;


    BCValue retval;
    BCValue assignTo;

    bool discardValue = false;

    void doFixup(uint oldFixupTableCount, BCLabel* ifTrue, BCLabel* ifFalse)
    {
        foreach (fixup; fixupTable[oldFixupTableCount .. fixupTableCount])
        {
            if (fixup.conditional.ifTrue)
            {
                endCndJmp(fixup.conditional, ifTrue ? *ifTrue : genLabel());
            }
            else
            {
                endCndJmp(fixup.conditional, ifFalse ? *ifFalse : genLabel());
            }

            --fixupTableCount;
        }
    }

public:

    this(FuncDeclaration fd, Expression _this, typeof(this)* parent = null)
    {
        me = fd;
        this.parent = parent;
        if (_this)
            this._this = _this;
    }

    void beginParameters()
    {
        processingParameters = true;
    }

    void endParameters()
    {
        processingParameters = false;
    }

    void beginArguments()
    {
        processingArguments = true;
        insideArgumentProcessing = true;
    }

    void endArguments()
    {
        processedArgs = 0;
        processingArguments = false;
        insideArgumentProcessing = false;
    }

    BCValue getVariable(VarDeclaration vd)
    {
        if (auto value = (cast(void*) vd) in vars)
        {
            return *value;
        }
        else
        {
            return BCValue.init;
        }
    }
    /*
	BCValue pushOntoHeap(BCValue v)
	{
		assert(isBasicBCType(toBCType(v)), "For now only basicBCTypes are supported");

	}
*/
    BCValue genExpr(Expression expr)
    {

        debug (ctfe)
        {
            import std.stdio;
        }
        auto oldRetval = retval;

        if (processingArguments)
        {
            debug (ctfe)
            {
                import std.stdio;

                //    writeln("Arguments ", arguments);
            }
            if (processedArgs != arguments.length)
            {

                processingArguments = false;
                assignTo = arguments[processedArgs++];
                assert(expr);
                expr.accept(this);
                processingArguments = true;

            }
            else
            {
                IGaveUp = true;
                assert(0, "passed too many arguments");

            }
        }
        else
        {

            if (expr)
                expr.accept(this);
        }
        debug (ctfe)
        {
            writeln("expr: ", expr.toString, " == ", retval);
        }
        //        assert(!discardValue || retval.vType != BCValueType.Unknown);
        BCValue ret = retval;
        retval = oldRetval;

        //        if (processingArguments) {
        //            arguments ~= retval;
        //            assert(arguments.length <= parameterTypes.length, "passed to many arguments");
        //        }

        return ret;
    }

    override void visit(FuncDeclaration fd)
    {
        import ddmd.identifier;

        //HACK this filters out functions which I know produce incorrect results
        //this is only so I can see where else are problems.

        if (fd.ident == Identifier.idPool("isRooted")
                || fd.ident == Identifier.idPool("__lambda2")
                || fd.ident == Identifier.idPool("isSameLength")
                || fd.ident == Identifier.idPool("wrapperParameters")
                || fd.ident == Identifier.idPool("defaultMatrix")
                || fd.ident == Identifier.idPool("bug4910") // this one is strange
                || fd.ident == Identifier.idPool("extSeparatorPos")
                || fd.ident == Identifier.idPool("args")
                || fd.ident == Identifier.idPool("check"))
        {
            IGaveUp = true;
            debug (ctfe)
            {
                import std.stdio;

                writeln("Bailout on known function");
            }
            return;
        }

        static if (is(typeof(_sharedCtfeState.functionCount)))
        {
            if (auto i = _sharedCtfeState.getFunctionIndex(fd))
            {
                     auto bc = _sharedCtfeState.functions[i - 1].byteCode;
                      this.byteCodeArray[0 .. bc.length] = bc;
                       this.ip = cast(uint) bc.length;
                       this.arguments.length = _sharedCtfeState.functions[i - 1].nArgs;
                       return;
            }
        }

        if (auto fbody = fd.fbody.isCompoundStatement)
        {
            beginParameters();
            if (fd.parameters)
                foreach (i, p; *(fd.parameters))
                {
                    debug (ctfe)
                    {
                        import std.stdio;

                        writeln("parameter [", i, "] : ", p.toString);
                    }
                    p.accept(this);
                }
            endParameters();
            debug (ctfe)
            {
                import std.stdio;

                writeln("ParameterType : ", parameterTypes);
            }
            import std.stdio;

            beginFunction();
            visit(fbody);
            endFunction();
            if (IGaveUp)
            {
                debug (ctfe)
                {
                    static if (UsePrinterBackend)
                        writeln(result);
                    else static if (UseCBackend)
                        writeln(code);
                    else static if (UseLLVMBackend)
                    {
                    }
                    else
                        writeln(printInstructions(byteCodeArray[0 .. ip]));
                    writeln("Gave up!");
                }
                return;
            }

            static if (is(typeof(_sharedCtfeState.functions)))
            {

                debug (ctfe)
                {
                    writeln("FnCnt: ", _sharedCtfeState.functionCount);
                }
                static if (is(BCGen))
                {
                    _sharedCtfeState.functions[_sharedCtfeState.functionCount++] = BCFunction(cast(void*) fd,
                        BCFunctionTypeEnum.Bytecode,
                        _sharedCtfeState.functionCount, byteCodeArray[0 .. ip].dup, cast(uint) parameterTypes.length);
                }
                else
                {
                    _sharedCtfeState.functions[_sharedCtfeState.functionCount++] = BCFunction(cast(void*) fd,
                        BCFunctionTypeEnum.Bytecode, _sharedCtfeState.functionCount);
                }
            }
            else
            {
                //static assert(0, "No functions for old man");
            }
        }
    }

    override void visit(BinExp e)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("Called visit(BinExp) %s ... \n\tdiscardReturnValue %d",
                e.toString, discardValue);
            writefln("(BinExp).Op: %s", e.op.to!string);

        }
        bool wasAssignTo;
        if (assignTo)
        {
            wasAssignTo = true;
            retval = assignTo;
            assignTo = BCValue.init;
        }
        else
        {
            retval = genTemporary(toBCType(e.type));
        }
        switch (e.op)
        {

        case TOK.TOKplusplus:
            {
                const oldDiscardValue = discardValue;
                discardValue = false;
                auto expr = genExpr(e.e1);
                if (!canWorkWithType(expr.type))
                {
                    IGaveUp = true;
                    debug (ctfe)
                        assert(0, "only i32 is supported not " ~ to!string(expr.type.type));
                    return;
                }
                assert(expr.vType != BCValueType.Immediate,
                    "++ does not make sense as on an Immediate Value");

                discardValue = oldDiscardValue;
                Set(retval, expr);

                Add3(expr, expr, BCValue(Imm32(1)));

            }
            break;
        case TOK.TOKminusminus:
            {
                const oldDiscardValue = discardValue;
                discardValue = false;
                auto expr = genExpr(e.e1);
                if (!canWorkWithType(expr.type))
                {
                    IGaveUp = true;
                    debug (ctfe)
                        assert(0, "only i32 is supported not " ~ to!string(expr.type.type));
                    return;
                }
                assert(expr.vType != BCValueType.Immediate,
                    "-- does not make sense as on an Immediate Value");

                discardValue = oldDiscardValue;
                Set(retval, expr);

                Sub3(expr, expr, BCValue(Imm32(1)));
            }
            break;
        case TOK.TOKequal, TOK.TOKnotequal:
            {
                if (e.e1.type.isString && e.e1.type.isString)
                {
                    auto lhs = genExpr(e.e1);
                    auto rhs = genExpr(e.e2);
                    static if (is(typeof(StringEq3) == function)
                            && is(typeof(StringEq3(BCValue.init, BCValue.init,
                            BCValue.init)) == void))
                    {
                        StringEq3(retval, lhs, rhs);
                    }
                    else
                    {
                        import ddmd.ctfe.bc_macro : StringEq3Macro;

                        StringEq3Macro(&gen, retval, lhs, rhs);
                    }

                }
                else
                {
                    goto case TOK.TOKadd;
                }
            }
            break;
        case TOK.TOKquestion:
            {
                auto ce = cast(CondExp) e;
                auto cond = genExpr(ce.econd);
                debug (ctfe)
                    assert(cond);
                    else if (!cond)
                    {
                        IGaveUp = true;
                        return;
                    }

                auto cj = beginCndJmp(cond ? cond.i32 : cond, false);
                auto lhsEval = genLabel();
                auto lhs = genExpr(e.e1);
                // FIXME this is a hack we should not call Set this way
                Set(retval.i32, lhs.i32);
                auto toend = beginJmp();
                auto rhsEval = genLabel();
                auto rhs = genExpr(e.e2);
                // FIXME this is a hack we should not call Set this way
                Set(retval.i32, rhs.i32);
                endCndJmp(cj, rhsEval);
                endJmp(toend, genLabel());
            }
            break;
        case TOK.TOKcat:
            {
                auto lhs = genExpr(e.e1);
                auto rhs = genExpr(e.e2);
                if (canWorkWithType(lhs.type) && canWorkWithType(rhs.type)
                        && basicTypeSize(lhs.type) == basicTypeSize(rhs.type))
                {
                    Cat(retval, lhs, rhs, basicTypeSize(lhs.type));
                }
                else
                {
                    IGaveUp = true;
                    debug (ctfe)
                        assert(0, "We cannot cat " ~ e.e1.toString ~ " and " ~ e.e2.toString);
                }
            }
            break;

        case TOK.TOKadd, TOK.TOKmin, TOK.TOKmul, TOK.TOKdiv, TOK.TOKmod,
                TOK.TOKand, TOK.TOKor, TOK.TOKshr, TOK.TOKshl:
                auto lhs = genExpr(e.e1);
            auto rhs = genExpr(e.e2);
            if (canHandleBinExpTypes(lhs.type.type, rhs.type.type))
            {
                const oldDiscardValue = discardValue;
                discardValue = false;
                /*debug (ctfe)
                        assert(!oldDiscardValue, "A lone BinExp discarding the value is strange");
                    */
                switch (cast(int) e.op)
                {
                case TOK.TOKequal:
                    {
                        Eq3(retval, lhs, rhs);
                    }
                    break;

                case TOK.TOKnotequal:
                    {
                        Neq3(retval, lhs, rhs);
                    }
                    break;
                case TOK.TOKmod:
                    {
                        Mod3(retval, lhs, rhs);
                    }
                    break;

                case TOK.TOKadd:
                    {
                        Add3(retval, lhs, rhs);
                    }
                    break;
                case TOK.TOKmin:
                    {
                        Sub3(retval, lhs, rhs);
                    }
                    break;
                case TOK.TOKmul:
                    {
                        Mul3(retval, lhs, rhs);
                    }
                    break;
                case TOK.TOKdiv:
                    {
                        Div3(retval, lhs, rhs);
                    }
                    break;

                case TOK.TOKand:
                    {
                        And3(retval, lhs, rhs);
                    }
                    break;

                case TOK.TOKshr:
                    {
                        Lt3(BCValue.init, rhs, BCValue(Imm32(basicTypeSize(lhs.type) * 8)));
                        AssertError(BCValue.init,
                            _sharedCtfeState.addError(e.loc, "shift out of bounds"));
                        Rsh3(retval, lhs, rhs);
                    }
                    break;

                case TOK.TOKshl:
                    {

                        Lt3(BCValue.init, rhs, BCValue(Imm32(basicTypeSize(lhs.type) * 8)));
                        AssertError(BCValue.init,
                            _sharedCtfeState.addError(e.loc, "shift out of bounds"));
                        Lsh3(retval, lhs, rhs);
                    }
                    break;
                default:
                    {
                        IGaveUp = true;
                        debug (ctfe)
                            assert(0, "Binary Expression " ~ to!string(e.op) ~ " unsupported");
                        return;
                    }
                }
                discardValue = oldDiscardValue;
            }

            else
            {
                IGaveUp = true;
                debug (ctfe)
                {
                    assert(0, "Only binary operations on i32s are supported");
                }
                return;
            }

            break;

        case TOK.TOKoror:
        case TOK.TOKandand:
            {
                IGaveUp = true;
                debug (ctfe)
                {
                    assert(0, "|| and && are unsupported at the moment");
                }
                const oldFixupTableCount = fixupTableCount;
                return;
                auto lhs = genExpr(e.e1);
                doFixup(oldFixupTableCount, null, null);
                fixupTable[fixupTableCount++] = BoolExprFixupEntry(beginCndJmp(lhs,
                    true));

                //auto rhs =
            }

            break;
        default:
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "BinExp.Op " ~ to!string(e.op) ~ " not handeled");
            }
        }

    }

    override void visit(SymOffExp se)
    {
        debug (ctfe)
            assert(toBCType(se.type).type == BCTypeEnum.i32Ptr, "only int* is supported for now");
        IGaveUp = true;
        auto v = getVariable(cast(VarDeclaration) se.var);
        //retval = BCValue(v.stackAddr
        import std.stdio;

        writeln("Se.var.genExpr == ", v);
    }

    override void visit(IndexExp ie)
    {

        debug (ctfe)
        {
            import std.stdio;

            writefln("IndexExp %s ... \n\tdiscardReturnValue %d", ie.toString, discardValue);
            writefln("ie.type : %s ", ie.type.toString);
        }

        auto indexed = genExpr(ie.e1);
        auto length = getLength(indexed);

        currentIndexed = indexed;
        debug (ctfe)
        {
            import std.stdio;

            writeln(indexed.type.type.to!string);
        }
        if (!(indexed.type.type == BCTypeEnum.String
                || indexed.type.type == BCTypeEnum.Array || indexed.type.type == BCTypeEnum.Slice))
        {
            debug (ctfe)
                assert(0,
                    "Unexpected IndexedType: " ~ to!string(indexed.type.type) ~ " ie: " ~ ie
                    .toString);
            IGaveUp = true;
            return;
        }

        bool isString = indexed.type.type == BCTypeEnum.String;
        //FIXME check if Slice.ElementType == Char
        //and set isString to true;
        auto idx = genExpr(ie.e2).i32; // HACK
        Gt3(BCValue.init, length, idx);
        AssertError(BCValue.init, _sharedCtfeState.addError(ie.loc, "ArrayIndex out of bounds"));
        BCArray* arrayType;
        BCSlice* sliceType;

        if (indexed.type.type == BCTypeEnum.Array)
        {
            auto _arrayType = (
                !isString ? &_sharedCtfeState.arrays[indexed.type.typeIndex - 1] : null);

            debug (ctfe)
            {
                import std.stdio;

                if (_arrayType)
                    writeln("arrayType: ", *_arrayType);

                arrayType = _arrayType;
            }
        }
        else if (indexed.type.type == BCTypeEnum.Slice)
        {
            sliceType = &_sharedCtfeState.slices[indexed.type.typeIndex - 1];
            debug (ctfe)
            {
                import std.stdio;

                writeln(_sharedCtfeState.slices[0 .. 4]);
                if (sliceType)
                    writeln("sliceType ", *sliceType);

            }

        }
        auto ptr = genTemporary(BCType(BCTypeEnum.i32));
        //We set the ptr already to the beginning of the array;
        scope (exit)
        {
            //removeTemporary(ptr);
        }
        auto elmType = arrayType ? arrayType.elementType : (
            sliceType ? sliceType.elementType : BCType(BCTypeEnum.Char));
        auto oldRetval = retval;
        retval = assignTo ? assignTo : genTemporary(elmType);
        //        if (elmType.type == BCTypeEnum.i32)
        {
            debug (ctfe)
            {
                writeln("elmType: ", elmType.type);
            }

            // We add one to go over the length;

            auto offset = genTemporary(BCType(BCTypeEnum.i32));

            if (!isString)
            {
                Add3(ptr, indexed.i32, bcFour);
                int elmSize = sharedCtfeState.size(elmType);
                assert(cast(int) elmSize > -1);
                //elmSize = (elmSize / 4 > 0 ? elmSize / 4 : 1);
                Mul3(offset, idx, BCValue(Imm32(elmSize)));
                Add3(ptr, ptr, offset);
                Load32(retval, ptr);
            }
            else
            {
                //TODO assert that idx is not out of bounds;
                //auto inBounds = genTemporary(BCType(BCTypeEnum.i1));
                //auto arrayLength = genTemporary(BCType(BCTypeEnum.i32));
                //Load32(arrayLength, indexed.i32);
                //Lt3(inBounds,  idx, arrayLength);
                Add3(ptr, indexed.i32, bcOne);

                auto modv = genTemporary(BCType(BCTypeEnum.i32));
                Mod3(modv, idx, bcFour);
                Div3(offset, idx, bcFour);
                Add3(ptr, ptr, offset);

                Load32(retval, ptr);
                //TODO use UTF8 intrinsic!
                Byte3(retval, retval, modv);
                //removeTemporary(modv);
                //removeTemporary(tmpElm);

            }
            /*
        else
        {
            IGaveUp = true;
            debug (ctfe)
                assert(0, "Type of IndexExp unsupported " ~ ie.e1.type.toString);
        }*/
        }
    }

    BCBlock genBlock(Statement stmt, bool setCurrent = false, bool infiniteLoop = false, bool incrementContinue = false)
    {
        BCBlock result;
        auto oldBlock = currentBlock;
        const oldbreakFixupCount = breakFixupCount;

        if (setCurrent)
        {
            currentBlock = &result;
        }
        result.begin = genLabel();
        stmt.accept(this);
        result.end = genLabel();

        // Now let's fixup thoose breaks
        if (setCurrent)
        {
            if (!infiniteLoop)
            {
                foreach (Jmp; breakFixups[oldbreakFixupCount .. breakFixupCount])
                {
                    endJmp(Jmp, result.end);
                }
                breakFixupCount = oldbreakFixupCount;
            }
            currentBlock = oldBlock;
        }

        return result;
    }

    override void visit(ForStatement fs)
    {
        //FIXME
        // There might be a problem with continueing for loops
        // I think we should execute the increment step when we continue
        // However that will not be done with the current system

        debug (ctfe)
        {
            import std.stdio;

            writefln("ForStatement %s", fs.toString);
        }

        if (fs._init)
        {
            (fs._init.accept(this));
        }

        if (fs.condition !is null && fs._body !is null)
        {
            if (fs.condition.isBool(true))
            {
                infiniteLoop(fs._body, fs.increment);
                return;
            }

            BCLabel condEval = genLabel();

            BCValue cond = genExpr(fs.condition);
            debug (ctfe)
                assert(cond, "No cond generated");
        else if (!cond)
                {
                    IGaveUp = true;
                    return;
                }

            auto condJmp = beginCndJmp(cond);

            auto _body = genBlock(fs._body, true);
            if (fs.increment)
            {
                fs.increment.accept(this);
                _body.end = genLabel();
            }
            genJump(condEval);
            auto afterJmp = genLabel();
            endCndJmp(condJmp, afterJmp);
        }
        else if (fs.condition !is null  /* && fs._body is null*/ )
        {
            BCLabel condEval = genLabel();
            BCValue condExpr = genExpr(fs.condition);
            auto condJmp = beginCndJmp(condExpr);
            if (fs.increment)
            {
                fs.increment.accept(this);
            }
            genJump(condEval);
            endCndJmp(condJmp, genLabel());
        }
        else
        { // fs.condition is null && fs._body !is null
            infiniteLoop(fs._body, fs.increment);
        }

    }

    override void visit(Expression e)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("Expression %s", e.toString);

        }
        IGaveUp = true;
        debug (ctfe)
            assert(0, "Cannot handleExpression: " ~ e.toString);
    }

    override void visit(NullExp ne)
    {
        retval = BCValue.init;
        retval.vType = BCValueType.Immediate;
        retval.type.type = BCTypeEnum.Null;
        //debug (ctfe)
        //    assert(0, "I don't really know what to do on a NullExp");
    }

    override void visit(HaltExp he)
    {
        retval = BCValue.init;
        debug (ctfe)
            assert(0, "I don't really handle assert(0)");
    }

    override void visit(SliceExp se)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("SliceExp %s", se.toString);
            writefln("se.e1 %s", se.e1.toString);

            //assert(0, "Cannot handleExpression");
        }

        if (!se.lwr && !se.upr)
        {
            // "If there is no lwr and upr bound forward"
            retval = genExpr(se.e1);
        }
        else
        {
            IGaveUp = true;
            debug (ctfe)
                assert(0, "We don't handle [xx .. yy] for now");
        }
    }

    override void visit(DotVarExp dve)
    {
        if (dve.e1.type.ty == Tstruct && (cast(TypeStruct) dve.e1.type).sym)
        {
            auto structDeclPtr = (cast(TypeStruct) dve.e1.type).sym;
            auto structTypeIndex = _sharedCtfeState.getStructIndex(structDeclPtr);
            if (structTypeIndex)
            {
                BCStruct _struct = _sharedCtfeState.structs[structTypeIndex - 1];
                import ddmd.ctfeexpr : findFieldIndexByName;

                auto vd = dve.var.isVarDeclaration;
                assert(vd);
                auto fIndex = findFieldIndexByName(structDeclPtr, vd);
                if (fIndex == -1)
                {
                    debug (ctfe)
                        assert(0, "Field cannot be found " ~ dve.toString);
                    IGaveUp = true;
                    return;
                }
                int offset = _struct.offset(fIndex);
                assert(offset != -1);

                debug (ctfe)
                {
                    import std.stdio;

                    writeln("getting field ", fIndex, "from ",
                        structDeclPtr.toString, " BCStruct ", _struct);
                }
                retval = (assignTo && assignTo.vType == BCValueType.StackValue) ? assignTo : genTemporary(
                    BCType(BCTypeEnum.i32));

                auto lhs = genExpr(dve.e1);
                assert(lhs.type == BCTypeEnum.Struct);

                if (!(lhs.vType == BCValueType.StackValue
                        || lhs.vType == BCValueType.Parameter || lhs.vType == BCValueType.Temporary))
                {
                    debug (ctfe)
                    {
                        assert(0, "Unexpected: " ~ to!string(lhs.vType));
                    }
                    IGaveUp = true;
                    return;
                }

                auto ptr = genTemporary(BCType(BCTypeEnum.i32));
                Add3(ptr, lhs.i32, BCValue(Imm32(offset)));
                Load32(retval.i32, ptr);

                debug (ctfe)
                {
                    import std.stdio;

                    writeln("dve.var : ", dve.var.toString);
                    writeln(dve.var.isVarDeclaration.offset);
                }
            }
        }
        else
        {
            debug (ctfe)
                assert(0, "Can only take members of a struct for now");
            IGaveUp = true;
        }

    }

    override void visit(ArrayLiteralExp ale)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ArrayLiteralExp %s insideArrayLiteralExp %d",
                ale.toString, insideArrayLiteralExp);
        }

        retval = assignTo ? assignTo : genTemporary(toBCType(ale.type));

        auto oldInsideArrayLiteralExp = insideArrayLiteralExp;
        insideArrayLiteralExp = true;

        auto elmType = toBCType(ale.type.nextOf);
        if (elmType.type != BCTypeEnum.i32 && elmType.type != BCTypeEnum.Struct)
        {
            IGaveUp = true;
            debug (ctfe)
            {
                assert(0,
                    "can only deal with int[] and uint[]  or Structs atm. given:" ~ to!string(
                    elmType.type));
            }
        }
        auto arrayLength = cast(uint) ale.elements.dim;
        //_sharedCtfeState.getArrayIndex(ale.type);
        auto arrayType = BCArray(elmType, arrayLength);
        debug (ctfe)
        {
            writeln("Adding array of Type:  ", arrayType);
        }

        _sharedCtfeState.arrays[_sharedCtfeState.arrayCount++] = arrayType;
        if (!oldInsideArrayLiteralExp)
            retval = assignTo ? assignTo.i32 : genTemporary(BCType(BCTypeEnum.i32));

        HeapAddr arrayAddr = HeapAddr(_sharedCtfeState.heap.heapSize);
        _sharedCtfeState.heap._heap[_sharedCtfeState.heap.heapSize] = arrayLength;
        _sharedCtfeState.heap.heapSize += uint.sizeof;

        auto heapAdd = align4(_sharedCtfeState.size(elmType));

        foreach (elem; *ale.elements)
        {
            auto elexpr = genExpr(elem);
            if (elexpr.type.type == BCTypeEnum.i32 && elexpr.vType == BCValueType.Immediate)
            {
                _sharedCtfeState.heap._heap[_sharedCtfeState.heap.heapSize] = elexpr.imm32;
                _sharedCtfeState.heap.heapSize += heapAdd;
            }
            else
            {
                debug (ctfe)
                    assert(0, "ArrayElement is not an Immediate but an " ~ to!string(elexpr.vType));
                IGaveUp = true;
            }
        }
        //        if (!oldInsideArrayLiteralExp)

        retval = BCValue(Imm32(arrayAddr.addr));
        debug (ctfe)
        {
            import std.stdio;

            writeln("ArrayLiteralRetVal = ", retval.imm32);
        }
        auto insideArrayLiteralExp = oldInsideArrayLiteralExp;
    }

    override void visit(StructLiteralExp sle)
    {

        debug (ctfe)
        {
            import std.stdio;

            writefln("StructLiteralExp %s insideArrayLiteralExp %d",
                sle.toString, insideArrayLiteralExp);
        }

        auto sd = sle.sd;
        auto idx = _sharedCtfeState.getStructIndex(sd);
        debug (ctfe)
            assert(idx);
            else if (!idx)
            {
                IGaveUp = true;
                return;
            }
        BCStruct _struct = _sharedCtfeState.structs[idx - 1];

        foreach (ty; _struct.memberTypes[0 .. _struct.memberTypeCount])
        {
            if (ty.type != BCTypeEnum.i32)
            {
                debug (ctfe)
                    assert(0,
                        "can only deal with ints and uints atm. not: (" ~ to!string(ty.type) ~ ", " ~ to!string(
                        ty.typeIndex) ~ ")");
                IGaveUp = true;
                return;
            }
        }
        auto heap = _sharedCtfeState.heap;
        auto size = align4(_sharedCtfeState.size(BCType(BCTypeEnum.Struct, idx)));

        retval = assignTo ? assignTo.i32 : genTemporary(BCType(BCTypeEnum.i32));
        if (!insideArgumentProcessing)
            Alloc(retval, BCValue(Imm32(size)));
        else
        {
            retval = BCValue(HeapAddr(heap.heapSize));
            heap.heapSize += size;
        }

        uint offset = 0;
        BCValue fieldAddr = genTemporary(i32Type);
        foreach (elem; *sle.elements)
        {
            auto elexpr = genExpr(elem);
            debug (ctfe)
            {
                writeln("elExpr: ", elexpr.toString, " elem ", elem.toString);
            }
            if (elexpr.type != BCTypeEnum.i32
                    && (elexpr.vType != BCValueType.Immediate
                    || elexpr.vType != BCValueType.StackValue))
            {
                debug (ctfe)
                    assert(0,
                        "StructLiteralExp-Element " ~ elexpr.type.type.to!string
                        ~ " is currently not handeled");
                IGaveUp = true;
                return;
            }
            if (!insideArgumentProcessing)
            {
                Add3(fieldAddr, retval.i32, BCValue(Imm32(offset)));
                Store32(fieldAddr, elexpr);
            }
            else
            {
                assert(elexpr.vType == BCValueType.Immediate, "Arguments have to be immediates");
                heap._heap[retval.heapAddr + offset] = elexpr.imm32;
            }
            offset += align4(_sharedCtfeState.size(elexpr.type));

        }
        //if (!processingArguments) Set(retval.i32, result.i32);
        debug (ctfe)
        {
            writeln("Done with struct ... revtval: ", retval);
        }
        //retval = result.i32;
    }

    override void visit(DollarExp de)
    {
        if (currentIndexed.type == BCTypeEnum.Array
                || currentIndexed.type == BCTypeEnum.Array
                || currentIndexed.type == BCTypeEnum.String)
        {
            retval = getLength(currentIndexed);
            assert(retval);
        }
        else
        {
            debug (ctfe)
            {
                assert(0, "We could not find an indexed variable for " ~ de.toString);
            }
            IGaveUp = true;
            return;
        }
    }

    override void visit(AddrExp ae)
    {
        retval = genExpr(ae.e1);
        //Alloc()
        //assert(0, "Dieng on Addr ?");
    }

    override void visit(ThisExp te)
    {
        import std.stdio;

        debug (ctfe)
        {
            writeln("ThisExp", te.toString);
            writeln("te.var:", te.var ? te.var.toString : "null");

        }
        retval = genExpr(_this);
    }

    override void visit(ComExp ce)
    {
        Not(retval, genExpr(ce.e1));
    }

    override void visit(PtrExp pe)
    {

        retval = genExpr(pe.e1);
        {
            import std.stdio;

            writeln(retval);
        }

    }

    override void visit(NewExp ne)
    {
        auto ptr = genTemporary(i32Type);
        auto size = genTemporary(i32Type);
        Set(size, BCValue(Imm32(basicTypeSize(toBCType(ne.newtype)))));

        Alloc(ptr, size);
        retval = ptr;
        {
            import std.stdio;

            writeln(retval);
        }

    }

    override void visit(ArrayLengthExp ale)
    {
        auto array = genExpr(ale.e1);
        if (array.type.type == BCTypeEnum.String || array.type.type == BCTypeEnum.Slice)
        {
            retval = getLength(array, assignTo);
        }
        else
        {
            debug (ctfe)
                assert(0, "We only handle StringLengths for now att: " ~ to!string(array.type.type));
            IGaveUp = true;
        }
        //Set(, array);
        //emitPrt(retval);
        /*
        uint_32 length
        uint_32 [length/4+1] chars;
         */
    }

    BCValue getLength(BCValue arr, BCValue target = BCValue.init)
    {
        if (arr)
        {
            // HACK we cast the target to i32 in order to make it work
            // this will propbably never fail in practice but still
            auto length = target ? target.i32 : genTemporary(BCType(BCTypeEnum.i32));
            Load32(length, arr.i32);
            return length;
        }
        else
        {
            debug (ctfe)
                assert(0, "cannot get length without a valid arr");
            IGaveUp = true;
            return BCValue.init;
        }
    }

    override void visit(VarExp ve)
    {
        auto vd = ve.var.isVarDeclaration;
        auto symd = ve.var.isSymbolDeclaration;

        debug (ctfe)
        {
            import std.stdio;

            writefln("VarExp %s discardValue %d", ve.toString, discardValue);
            if (vd && (cast(void*) vd) in vars)
                writeln("ve.var sp : ", ((cast(void*) vd) in vars).stackAddr);
        }

        if (vd)
        {
            import ddmd.id;

            if (vd.ident == Id.dollar)
            {
                retval = getLength(currentIndexed);
                return;
            }

            auto sv = getVariable(vd);
            debug (ctfe)
                assert(sv, "Variable " ~ ve.toString ~ " not in StackFrame");

            if (!ignoreVoid && sv.vType == BCValueType.VoidValue)
            {
                IGaveUp = true;
                ve.error("Trying to read form an uninitialized Variable");
                return;
            }

            if (sv == BCValue.init)
            {
                IGaveUp = true;
                return;
            }
            retval = sv;
        }
        else if (symd)
        {
            auto sds = cast(SymbolDeclaration) symd;
            assert(sds);
            auto sd = sds.dsym;
            Expressions iexps;

            foreach (ie; *sd.members)
            {
                //iexps.push(new Expression();
            }
            auto sl = new StructLiteralExp(sds.loc, sd, &iexps);
            retval = genExpr(sl);
            //assert(0, "SymbolDeclarations are not supported for now" ~ .type.size.to!string);
            //auto vs = symd in syms;

        }
        else
        {
            assert(0, "VarExpType unkown");
        }

        debug (ctfe)
        {
            import std.stdio;

            writeln("VarExp finished");
        }
    }

    override void visit(DeclarationExp de)
    {
        auto oldRetval = retval;
        auto vd = de.declaration.isVarDeclaration();
        auto as = de.declaration.isAliasDeclaration();
        if (as)
        {
            debug (ctfe)
                assert(0, "Alias Declaration " ~ toString(as) ~ " is unsupported");
        }
        if (!vd)
        {
            debug (ctfe)
                assert(vd, "DeclarationExps are expected to be VariableDeclarations");

            IGaveUp = true;
            return;
        }
        visit(vd);
        auto var = retval;
        debug (ctfe)
        {
            import std.stdio;

            writefln("DeclarationExp %s discardValue %d", de.toString, discardValue);
            writefln("DeclarationExp.declaration: %x", cast(void*) de.declaration.isVarDeclaration);
        }
        if (vd._init)
        {
            if (vd._init.isVoidInitializer)
            {
                var.vType = BCValueType.VoidValue;
                setVariable(vd, var);
            }
            else if (auto ci = vd.getConstInitializer)
            {

                auto _init = genExpr(ci);
                if (_init.vType == BCValueType.Immediate && _init.type == BCType(BCTypeEnum.i32))
                {
                    Set(var.i32, retval);
                }

            }
            retval = var;
        }
    }

    override void visit(VarDeclaration vd)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("VarDeclaration %s discardValue %d", vd.toString, discardValue);
        }

        BCValue var;
        BCType type = toBCType(vd.type);
        if (processingParameters)
        {
            var = genParameter(type);
            arguments ~= var;
            parameterTypes ~= type;
        }
        else
        {

            var = BCValue(currSp(), type);
            incSp();
        }

        setVariable(vd, var);
        retval = var;

    }

    void setVariable(VarDeclaration vd, BCValue var)
    {
        vars[cast(void*) vd] = var;
    }

    static bool canHandleBinExpTypes(const BCTypeEnum lhs, const BCTypeEnum rhs) pure
    {
        return (lhs == BCTypeEnum.i32 || lhs == BCTypeEnum.i32Ptr)
            && rhs == BCTypeEnum.i32 || lhs == BCTypeEnum.i64
            && (rhs == BCTypeEnum.i64 || rhs == BCTypeEnum.i32);
    }

    override void visit(BinAssignExp e)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("BinAssignExp %s discardValue %d", e.toString, discardValue);
        }
        const oldDiscardValue = discardValue;
        auto oldAssignTo = assignTo;
        assignTo = BCValue.init;
        auto oldRetval = retval;
        discardValue = false;
        auto lhs = genExpr(e.e1);
        discardValue = false;
        auto rhs = genExpr(e.e2);

        //FIXE we should not get into that situation!
        if (!lhs || !rhs)
        {
            IGaveUp = true;
            debug (ctfe)
                assert(0, "We could not gen lhs or rhs");
            return;
        }

        switch (e.op)
        {

        case TOK.TOKaddass:
            {
                Add3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;
        case TOK.TOKminass:
            {
                Sub3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;

        case TOK.TOKorass:
            {
                Or3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;
        case TOK.TOKandass:
            {
                And3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;
        case TOK.TOKxorass:
            {
                Xor3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;
        case TOK.TOKmulass:
            {
                Mul3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;
        case TOK.TOKdivass:
            {
                Div3(lhs, lhs, rhs);
                retval = lhs;
            }
            break;

        case TOK.TOKcatass:
            {
                IGaveUp = true;
                if (lhs.type.type == BCTypeEnum.String && rhs.type.type == BCTypeEnum.String)
                {
                    assert(lhs.vType == BCValueType.StackValue,
                        "Only StringConcats on StackValues are supported for now");

                    /*
                 * TODO scope(exit) { removeTempoary .... }
                 */

                    static if (UsePrinterBackend)
                    {
                    }
                    else
                    {
                        //StringCat(lhs, lhs, rhs);
                    }
                }
                else
                {
                    if (rhs.type.type != BCTypeEnum.i32)
                    {
                        IGaveUp = true;
                        debug (ctfe)
                            assert(0, "rhs must not be i32 for now");
                        return;
                    }
                    if (lhs.type.type == BCTypeEnum.Slice)
                    {
                        auto sliceType = _sharedCtfeState.slices[lhs.type.typeIndex];
                        retval = assignTo ? assignTo : genTemporary(sliceType.elementType);
                        Cat(retval, lhs, rhs, _sharedCtfeState.size(sliceType.elementType));
                    }
                    else
                    {
                        IGaveUp = true;
                        debug (ctfe)
                            assert(0, "Can only concat on slices");
                        return;
                    }
                }
                debug (ctfe)
                {
                    import std.stdio;

                    //writeln("encountered ~=  lhs: ", lhs, "\nrhs: ",rhs, this.byteCodeArray[0 .. ip].printInstructions);
                }
            }
            break;
        default:
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "Unsupported for now");
            }
        }
        //assert(discardValue);

        retval = oldDiscardValue ? oldRetval : retval;
        discardValue = oldDiscardValue;
        assignTo = oldAssignTo;
    }

    override void visit(IntegerExp ie)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("IntegerExpression %s", ie.toString);
        }

        auto bct = toBCType(ie.type);

        // HACK regardless of the literal type we register it as 32bit if it's smaller then int.max;
        if (ie.value > int.max)
        {
            retval = BCValue(Imm64(ie.value));
        }
        else
        {
            retval = BCValue(Imm32(cast(uint) ie.value));
        }
        //auto value = evaluateUlong(ie);
        //retval = value <= int.max ? BCValue(Imm32(cast(uint) value)) : BCValue(Imm64(value));
        assert(retval.vType == BCValueType.Immediate);
    }

    override void visit(RealExp re)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("RealExp %s", re.toString);
        }

        IGaveUp = true;
    }

    override void visit(ComplexExp ce)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ComplexExp %s", ce.toString);
        }

        IGaveUp = true;
    }

    override void visit(StringExp se)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("StringExp %s", se.toString);
        }

        if (se.sz < 1 || se.string[se.len] != 0)
        {
            debug (ctfe)
                assert(0, "only zero terminated char strings are supported for now");
            IGaveUp = true;
            return;
            //assert(se.string[se.len] == '\0', "string should be 0-terminated");
        }
        auto stringAddr = _sharedCtfeState.heap.pushString(se.string, cast(uint) se.len);
        auto stringAddrValue = BCValue(Imm32(stringAddr.addr));
        if (insideArgumentProcessing)
        {
            retval = stringAddrValue;
            return;
        }

        if (assignTo)
        {
            retval = assignTo;
        }
        else
        {
            retval = genTemporary(BCType(BCTypeEnum.String));
        }
        Set(retval.i32, stringAddrValue);
        retval = stringAddrValue;
        debug (ctfe)
        {
            writefln("String %s, is in %d, first uint is %d",
                cast(char[]) se.string[0 .. se.len], stringAddr.addr,
                _sharedCtfeState.heap._heap[stringAddr.addr]);
        }

    }

    override void visit(CmpExp ce)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("CmpExp %s discardValue %d", ce.toString, discardValue);
        }
        auto oldAssignTo = assignTo ? assignTo : genTemporary(i32Type);
        assignTo = BCValue.init;
        auto lhs = genExpr(ce.e1);
        auto rhs = genExpr(ce.e2);
        if (canWorkWithType(lhs.type) && canWorkWithType(rhs.type))
        {
            switch (ce.op)
            {
            case TOK.TOKlt:
                {
                    Lt3(oldAssignTo, lhs, rhs);
                    retval = oldAssignTo;
                }
                break;

            case TOK.TOKgt:
                {
                    Gt3(oldAssignTo, lhs, rhs);
                    retval = oldAssignTo;
                }
                break;

            default:
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "Unsupported Operation " ~ to!string(ce.op));
            }
        }
        else
        {
            debug (ctfe)
                assert(0,
                    "cannot work with thoose types lhs: " ~ to!string(lhs.type.type) ~ " rhs: " ~ to!string(
                    rhs.type.type));
            IGaveUp = true;
        }
    }

    static bool canWorkWithType(const BCType bct) pure
    {
        return (bct.type == BCTypeEnum.i32 || bct.type == BCTypeEnum.i64
            || bct.type == BCTypeEnum.i32Ptr);
    }

    override void visit(ConstructExp ce)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ConstructExp: %s", ce.toString);
            writefln("ConstructExp.e1: %s", ce.e1.toString);
            writefln("ConstructExp.e2: %s", ce.e2.toString);
        }
        else if (!ce.e1.type.equivalent(ce.e2.type) && !ce.type.baseElemOf.equivalent(ce.e2.type))
        {
            IGaveUp = true;
            debug (ctfe)
                assert(0, "Appearntly the types are not equivalent");
            return;
        }

        auto lhs = genExpr(ce.e1);
        auto rhs = genExpr(ce.e2);
        // exit if we could not gen lhs
        //FIXME that should never happen
        if (!lhs || lhs.type.type == BCType.Undef)
        {
            IGaveUp = true;
            debug (ctfe)
                assert(0, "could not get " ~ ce.e1.toString);
            return;
        }
        // do we deal with an int ?
        if (lhs.type.type == BCTypeEnum.i32)
        {

        }
        else if (lhs.type.type == BCTypeEnum.String
                || lhs.type.type == BCTypeEnum.Slice || lhs.type.type.Array)
        {

        }
        else if (lhs.type.type == BCTypeEnum.Char || lhs.type.type == BCTypeEnum.i8)
        {

        }
        else if (lhs.type.type == BCTypeEnum.i32Ptr)
        {

        }
        else if (lhs.type.type == BCTypeEnum.i64)
        {
            Set(lhs, rhs);
        }
        else // we are dealing with a struct (hopefully)
        {
            assert(lhs.type.type == BCTypeEnum.Struct, to!string(lhs.type.type));

        }

        // exit if we could not gen rhs
        //FIXME that should never happen
        if (!rhs)
        {
            IGaveUp = true;
            return;
        }
        Set(lhs.i32, rhs.i32);
        retval = lhs;
    }

    override void visit(AssignExp ae)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("AssignExp: %s", ae.toString);
        }
        auto oldRetval = retval;
        auto oldAssignTo = assignTo;
        const oldDiscardValue = discardValue;
        discardValue = false;
        debug (ctfe)
        {
            import std.stdio;

            writeln("ae.e1.op ", to!string(ae.e1.op));
        }

        if (ae.e1.op == TOKdotvar)
        {
            // Assignment to a struct member
            // Needs to be handled diffrently
            auto dve = cast(DotVarExp) ae.e1;
            auto _struct = dve.e1;
            if (_struct.type.ty != Tstruct)
            {
                debug (ctfe)
                    assert(0, "only structs are supported for now");
                IGaveUp = true;
                return;
            }
            auto structDeclPtr = ((cast(TypeStruct) dve.e1.type).sym);
            auto structTypeIndex = _sharedCtfeState.getStructIndex(structDeclPtr);
            if (!structTypeIndex)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "could not get StructType");
                return;
            }
            BCStruct bcStructType = _sharedCtfeState.structs[structTypeIndex - 1];
            auto vd = dve.var.isVarDeclaration();
            assert(vd);

            import ddmd.ctfeexpr : findFieldIndexByName;

            auto fIndex = findFieldIndexByName(structDeclPtr, vd);
            assert(fIndex != -1, "field " ~ vd.toString ~ "could not be found in" ~ dve.e1.toString);
            if (bcStructType.memberTypes[fIndex].type != BCTypeEnum.i32)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "only i32 structMembers are supported for now");
                return;
            }
            auto rhs = genExpr(ae.e2);
            if (!rhs)
            {
                //Not sure if this is really correct :)
                rhs = BCValue(Imm32(0));
            }
            if (rhs.type.type != BCTypeEnum.i32)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "only i32 are supported for now. not:" ~ rhs.type.type.to!string);
                return;
            }

            auto lhs = genExpr(_struct);

            auto ptr = genTemporary(BCType(BCTypeEnum.i32));

            Add3(ptr, lhs.i32, BCValue(Imm32(bcStructType.offset(fIndex))));
            Store32(ptr, rhs);
            retval = rhs;
        }
        else if (ae.e1.op == TOKarraylength)
        {
            auto ale = cast(ArrayLengthExp) ae.e1;

            // We are assigning to an arrayLength
            // This means possibly allocation and copying
            auto arrayPtr = genExpr(ale.e1);
            if (!arrayPtr)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "I don't have an array to load the length from :(");
                return;
            }
            BCValue oldLength = genTemporary(i32Type);
            BCValue newLength = genExpr(ae.e2);
            auto effectiveSize = genTemporary(i32Type);
            auto elemType = toBCType(ale.e1.type);
            auto elemSize = align4(basicTypeSize(elemType));
            Mul3(effectiveSize, newLength, BCValue(Imm32(elemSize)));
            Add3(effectiveSize, effectiveSize, bcFour);

            typeof(beginJmp()) jmp;
            auto arrayExsitsJmp = beginCndJmp(arrayPtr.i32);
            typeof(beginCndJmp()) jmp1;
            typeof(beginCndJmp()) jmp2;
            {
                Load32(oldLength, arrayPtr);
                Le3(BCValue.init, oldLength, newLength);
                jmp1 = beginCndJmp(BCValue.init, true);
                {
                    auto newArrayPtr = genTemporary(i32Type);
                    Alloc(newArrayPtr, effectiveSize);
                    Store32(newArrayPtr, newLength);

                    auto copyPtr = genTemporary(i32Type);

                    Add3(copyPtr, newArrayPtr, bcFour);
                    Add3(arrayPtr.i32, arrayPtr.i32, bcFour);
                    // copy old Array
                    auto tmpElem = genTemporary(i32Type);
                    auto LcopyLoop = genLabel();
                    jmp2 = beginCndJmp(oldLength);
                    {
                        Sub3(oldLength, oldLength, bcOne);
                        foreach (_; 0 .. elemSize / 4)
                        {
                            Load32(tmpElem, arrayPtr.i32);
                            Store32(copyPtr, tmpElem);
                            Add3(arrayPtr.i32, arrayPtr.i32, bcFour);
                            Add3(copyPtr, copyPtr, bcFour);
                        }
                        genJump(LcopyLoop);
                    }
                    endCndJmp(jmp2, genLabel());

                    Set(arrayPtr.i32, newArrayPtr);
                    jmp = beginJmp();
                }
            }
            auto LarrayDoesNotExsist = genLabel();
            endCndJmp(arrayExsitsJmp, LarrayDoesNotExsist);
            {
                auto newArrayPtr = genTemporary(i32Type);
                Alloc(newArrayPtr, effectiveSize);
                Store32(newArrayPtr, newLength);
                Set(arrayPtr.i32, newArrayPtr);
            }
            auto Lend = genLabel();
            endCndJmp(jmp1, Lend);
            endJmp(jmp, Lend);
        }
        else if (ae.e1.op == TOKindex)
        {
            auto ie = cast(IndexExp) ae.e1;
            auto indexed = genExpr(ie.e1);
            if (!indexed)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "could not fetch indexed_var in " ~ ae.toString);
                return;
            }
            auto index = genExpr(ie.e2);
            if (!index)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "could not fetch index in " ~ ae.toString);
                return;
            }

            auto length = getLength(indexed);
            Gt3(BCValue.init, length, index);
            AssertError(BCValue.init, _sharedCtfeState.addError(ae.loc,
                "ArrayIndex out of bounds"));
            auto effectiveAddr = genTemporary(i32Type);
            auto elemType = toBCType(ie.e1.type.nextOf);
            auto elemSize = align4(_sharedCtfeState.size(elemType));
            Mul3(effectiveAddr, index, BCValue(Imm32(elemSize)));
            Add3(effectiveAddr, effectiveAddr, indexed.i32);
            Add3(effectiveAddr, effectiveAddr, bcFour);
            if (elemSize != 4)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "only 32 bit array loads are supported right now");
            }
            auto rhs = genExpr(ae.e2);
            Store32(effectiveAddr, rhs.i32);
        }
        else
        {
            ignoreVoid = true;
            auto lhs = genExpr(ae.e1);
            if (lhs.vType == BCValueType.VoidValue)
            {
                if (ae.e2.op == TOKvar)
                {
                    auto ve = cast(VarExp) ae.e2;
                    if (auto vd = ve.var.isVarDeclaration)
                    {
                        lhs.vType = BCValueType.StackValue;
                        setVariable(vd, lhs);
                    }
                }
            }

            assignTo = lhs;
            ignoreVoid = false;
            auto rhs = genExpr(ae.e2);

            debug (ctfe)
            {
                writeln("lhs :", lhs);
                writeln("rhs :", rhs);
            }
            if (lhs.vType == BCValueType.Unknown || rhs.vType == BCValueType.Unknown)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "rhs or lhs do not exist " ~ ae.toString);
                return;
            }
            if ((lhs.type.type == BCTypeEnum.i32
                    || lhs.type.type == BCTypeEnum.i32Ptr) && rhs.type.type == BCTypeEnum.i32)
            {
                Set(lhs, rhs);
            }
            else
            {
                if (rhs.type.type == BCTypeEnum.Char || lhs.type.type == BCTypeEnum.Char)
                {
                    Set(lhs.i32, rhs.i32);
                }
                else if (rhs.type.type == BCTypeEnum.String || lhs.type.type == BCTypeEnum.String)
                {
                    Set(lhs.i32, rhs.i32);
                }
                else if (rhs.type.type == BCTypeEnum.Slice || lhs.type.type == BCTypeEnum.Slice)
                {
                    Set(lhs.i32, rhs.i32);
                }
                else
                {
                    debug (ctfe)
                        assert(0, "I cannot work with toose types");
                    IGaveUp = true;
                }
            }
        }
        retval = oldDiscardValue ? oldRetval : retval;
        assignTo = oldAssignTo;
        discardValue = oldDiscardValue;

    }

    override void visit(SwitchErrorStatement _)
    {
        //assert(0, "encounterd SwitchErrorStatement" ~ toString(_));
    }

    override void visit(NegExp ne)
    {
        IGaveUp = true;
        debug (ctfe)
            assert(0, "NegExp (unary minus) expression not supported right now");
    }

    override void visit(NotExp ne)
    {
        import ddmd.id;

        if (ne.e1.op == TOKidentifier && (cast(IdentifierExp) ne.e1).ident == Id.ctfe)
        {
            retval = BCValue(Imm32(0));
        }
        else
        {
            retval = assignTo ? assignTo : genTemporary(i32Type);
            Eq3(retval, genExpr(ne.e1), bcZero);
        }

    }

    override void visit(UnrolledLoopStatement uls)
    {
        auto _uls = UnrolledLoopState();
        unrolledLoopState = &_uls;
        uint end = cast(uint) uls.statements.dim - 1;

        foreach (stmt; *uls.statements)
        {
            auto block = genBlock(stmt);

            if (end--)
            {
                foreach (fixup; _uls.continueFixups[0 .. _uls.continueFixupCount])
                {
                    //HACK the will leave a nop in the bcgen
                    //but it will break llvm or other potential backends;
                    if (fixup.addr != block.end.addr)
                        endJmp(fixup, block.end);
                }
                _uls.continueFixupCount = 0;
            }
            else
            {
                //FIXME Be aware that a break fixup has to be checked aginst the ip
                //TODO investigate why
                foreach (fixup; _uls.breakFixups[0 .. _uls.breakFixupCount])
                {
                    //HACK the will leave a nop in the bcgen
                    //but it will break llvm or other potential backends;
                    if (fixup.addr != block.begin.addr)
                        endJmp(fixup, block.begin);
                }
                _uls.breakFixupCount = 0;
            }
        }

        unrolledLoopState = null;
    }

    override void visit(ImportStatement _is)
    {
        // can be skipped
        return;
    }

    override void visit(AssertExp ae)
    {
        auto lhs = genExpr(ae.e1);
        if (lhs.type.type == BCTypeEnum.i32)
        {
            AssertError(lhs, _sharedCtfeState.addError(ae.loc,
                ae.msg ? ae.msg.toString : "Assert Failed"));
        }
        else
        {
            debug (ctfe)
                assert(0, "Non Integral expression in assert");
            IGaveUp = true;
            return;
        }
    }

    override void visit(SwitchStatement ss)
    {
        SwitchState* oldSwitchState = switchState;
        switchState = new SwitchState();
        scope (exit)
        {
            switchState = oldSwitchState;
        }

        with (switchState)
        {
            //This Transforms swtich in a series of if else construts.
            debug (ctfe)
            {
                import std.stdio;

                writefln("SwitchStatement %s", ss.toString);
            }

            auto lhs = genExpr(ss.condition);
            if (!lhs)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "swtiching on undefined value " ~ ss.toString);
                return;
            }
            if (lhs.type.type == BCTypeEnum.String || lhs.type.type == BCTypeEnum.Slice)
            {
                IGaveUp = true;
                debug (ctfe)
                    assert(0, "StringSwitches unsupported for now " ~ ss.toString);
                return;
            }
            if (ss.cases.dim > beginCaseStatements.length)
                assert(0, "We will not have enough array space to store all cases for gotos");

            foreach (i, caseStmt; *(ss.cases))
            {
                switchFixup = &switchFixupTable[switchFixupTableCount];
                caseStmt.index = cast(int) i;
                // apperantly I have to set the index myself;

                auto rhs = genExpr(caseStmt.exp);
                Eq3(BCValue.init, lhs, rhs);
                auto jump = beginCndJmp();
                if (caseStmt.statement)
                {
                    import ddmd.statement : BE;

                    bool blockReturns = !!(caseStmt.statement.blockExit(me, false) & BEany);
                    auto caseBlock = genBlock(caseStmt.statement);
                    beginCaseStatements[beginCaseStatementsCount++] = caseBlock.begin;
                    //If the block returns regardless there is no need for a fixup
                    if (!blockReturns)
                    {
                        switchFixupTable[switchFixupTableCount++] = beginJmp();
                        switchFixup = &switchFixupTable[switchFixupTableCount];
                    }
                }
                endCndJmp(jump, genLabel());
            }
            if (ss.sdefault)
            {
                auto defaultBlock = genBlock(ss.sdefault.statement);

                foreach (ac_jmp; switchFixupTable[0 .. switchFixupTableCount])
                {
                    if (ac_jmp.fixupFor == 0)
                        endJmp(ac_jmp, defaultBlock.end);
                    else if (ac_jmp.fixupFor == -1)
                        endJmp(ac_jmp, defaultBlock.begin);
                    else
                        endJmp(ac_jmp, beginCaseStatements[ac_jmp.fixupFor - 1]);
                }
            }
            else
            {
                auto afterSwitch = genLabel();

                foreach (ac_jmp; switchFixupTable[0 .. switchFixupTableCount])
                {
                    if (ac_jmp.fixupFor == 0)
                        endJmp(ac_jmp, afterSwitch);
                    else if (ac_jmp.fixupFor != -1)
                        endJmp(ac_jmp, beginCaseStatements[ac_jmp.fixupFor - 1]);
                    else
                        assert(0, "Without a default Statement there cannot be a jump to default");
                }

            }

            switchFixupTableCount = 0;
            switchFixup = null;
            //after we are done let's set thoose indexes back to zero
            //who knowns what will happen if we don't ?
            foreach (cs; *(ss.cases))
            {
                cs.index = 0;
            }
        }
    }

    override void visit(GotoCaseStatement gcs)
    {
        //FIXME this is horrible broken, the index might not represent the right statement
        // because our number can diffent from dmd's one
        // dmd seems to sort the cases, we dont.

        with (switchState)
        {
            *switchFixup = SwitchFixupEntry(beginJmp(), gcs.cs.index + 1);
            switchFixupTableCount++;
        }
    }

    override void visit(GotoDefaultStatement gd)
    {
        with (switchState)
        {
            *switchFixup = SwitchFixupEntry(beginJmp(), -1);
            switchFixupTableCount++;
        }
    }
    /// if jmp.toBegin is true jump to the begging of the block, otherwise jump to the end
    void addUnresolvedGoto(void* ident, BCBlockJump jmp)
    {
        foreach (i, ref unresolvedGoto; unresolvedGotos[0 .. unresolvedGotoCount])
        {
            if (unresolvedGoto.ident == ident)
            {
                unresolvedGoto.jumps[unresolvedGoto.jumpCount++] = jmp;
                return;
            }
        }

        unresolvedGotos[unresolvedGotoCount].ident = ident;
        unresolvedGotos[unresolvedGotoCount++].jumps[0] = jmp;

    }

    override void visit(GotoStatement gs)
    {
        auto ident = cast(void*) gs.ident;

        if (auto labeledBlock = ident in labeledBlocks)
        {
            genJump(labeledBlock.begin);
        }
        else
        {
            addUnresolvedGoto(ident, BCBlockJump(beginJmp(), true));
        }
    }

    override void visit(LabelStatement ls)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("LabelStatement %s", ls.toString);
        }
        debug (ctfe)
            assert(cast(void*) ls.ident !in labeledBlocks,
                "We already enounterd a LabelStatement with this identifier");

        if (cast(void*) ls.ident in labeledBlocks)
        {
            IGaveUp = true;
            return;
        }
        auto block = labeledBlocks[cast(void*) ls.ident] = genBlock(ls.statement);

        foreach (i, const ref unresolvedGoto; unresolvedGotos[0 .. unresolvedGotoCount])
        {
            if (unresolvedGoto.ident == cast(void*) ls.ident)
            {
                foreach (jmp; unresolvedGoto.jumps[0 .. unresolvedGoto.jumpCount])
                    jmp.toBegin ? endJmp(jmp.at, block.begin) : endJmp(jmp.at, block.end);

                // write the last one into here and decrease the count
                unresolvedGotos[i] = unresolvedGotos[unresolvedGotoCount--];
                break;
            }
        }
    }

    override void visit(ContinueStatement cs)
    {
        if (cs.ident)
        {
            if (auto target = cast(void*) cs.ident in labeledBlocks)
            {
                genJump(target.begin);
            }
            else
            {
                addUnresolvedGoto(cast(void*) cs.ident, BCBlockJump(beginJmp(), true));
            }
        }
        else if (unrolledLoopState)
        {
            IGaveUp = true;
            return;
            unrolledLoopState.continueFixups[unrolledLoopState.continueFixupCount++] = beginJmp();
        }
        else
        {
            assert(currentBlock, "ContinueStatement has no block to continue from" ~ cs.toString);
            genJump(currentBlock.begin);
        }
    }

    override void visit(BreakStatement bs)
    {
        if (bs.ident)
        {
            if (auto target = cast(void*) bs.ident in labeledBlocks)
            {
                genJump(target.end);
            }
            else
            {
                addUnresolvedGoto(cast(void*) bs.ident, BCBlockJump(beginJmp(), false));
            }

        }
        else if (switchFixup)
        {
            with (switchState)
            {
                *switchFixup = SwitchFixupEntry(beginJmp(), 0);
                switchFixupTableCount++;
            }
        }
        else if (unrolledLoopState)
        {
            debug (ctfe)
            {
                import std.stdio;

                writeln("breakFixupCount: ", breakFixupCount);
            }
            unrolledLoopState.breakFixups[unrolledLoopState.breakFixupCount++] = beginJmp();

        }
        else
        {
            breakFixups[breakFixupCount++] = beginJmp();
        }

    }

    override void visit(CallExp ce)
    {
        debug (ctfe)
        {
            assert(0, "We don't handle CallExp yet " ~ ce.toString);
        }
        else
        {
            IGaveUp = true;
            return;
        }

    }

    override void visit(ReturnStatement rs)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ReturnStatement %s", rs.toString);
        }
        assert(!inReturnStatement);
        assert(!discardValue, "A returnStatement cannot be in discarding Mode");
        if (rs.exp !is null)
        {
            auto retval = genExpr(rs.exp);
            if (retval.type == BCTypeEnum.i32 || retval.type == BCTypeEnum.Slice
                    || retval.type == BCTypeEnum.Array || retval.type == BCTypeEnum.String)
                Ret(retval.i32);
            else
            {
                debug (ctfe)
                {
                    assert(0,
                        "could not handle returnStatement with BCType " ~ to!string(
                        retval.type.type));
                }
                IGaveUp = true;
                return;
            }
        }
        else
        {
            Ret(BCValue(Imm32(0)));
        }
    }

    override void visit(CastExp ce)
    {
        //FIXME make this handle casts properly
        //e.g. calling opCast do truncation and so on
        retval = genExpr(ce.e1);
        retval.type = toBCType(ce.type);
    }

    void infiniteLoop(Statement _body, Expression increment = null)
    {
        auto oldBreakFixupCount = breakFixupCount;
        auto block = genBlock(_body, true, true);
        if (increment)
            increment.accept(this);
        genJump(block.begin);
        auto after_jmp = genLabel();
        foreach (Jmp; breakFixups[oldBreakFixupCount .. breakFixupCount])
        {
            endJmp(Jmp, after_jmp);
        }
    }

    override void visit(ExpStatement es)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ExpStatement %s", es.toString);
        }
        immutable oldDiscardValue = discardValue;
        discardValue = true;
        if (es.exp)
            genExpr(es.exp);
        discardValue = oldDiscardValue;
    }

    override void visit(DoStatement ds)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("DoStatement %s", ds.toString);
        }
        if (ds.condition.isBool(true))
        {
            infiniteLoop(ds._body);
        }
        else if (ds.condition.isBool(false))
        {
            genBlock(ds._body, true, false);
        }
        else
        {
            auto doBlock = genBlock(ds._body, true, false);

            auto cond = genExpr(ds.condition);
            debug (ctfe)
                assert(cond);
        else if (!cond)
                {
                    IGaveUp = true;
                    return;
                }

            auto cj = beginCndJmp(cond, true);
            endCndJmp(cj, doBlock.begin);
        }
    }

    override void visit(WithStatement ws)
    {

        debug (ctfe)
        {
            import std.stdio;

            writefln("WithStatement %s", ws.toString);

            assert(0, "We don't handle WithStatements");
        }
        IGaveUp = true;

    }

    override void visit(Statement s)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("Statement %s", s.toString);
        }
        IGaveUp = true;
        debug (ctfe)
            assert(0, "Statement unsupported " ~ s.toString);
    }

    override void visit(IfStatement fs)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("IfStatement %s", fs.toString);
        }

        if (fs.condition.is__ctfe == 1 || fs.condition.isBool(true))
        {
            if (fs.ifbody)
                genBlock(fs.ifbody);
            return;
        }
        else if (fs.condition.is__ctfe == -1 || fs.condition.isBool(false))
        {
            if (fs.elsebody)
                genBlock(fs.elsebody);
            return;
        }

        uint oldFixupTableCount = fixupTableCount;
        auto cond = genExpr(fs.condition);
        debug (ctfe)
            assert(cond);
            else if (!cond)
            {
                IGaveUp = true;
                return;
            }

        auto cj = beginCndJmp(cond);

        BCBlock ifbody = fs.ifbody ? genBlock(fs.ifbody) : BCBlock.init;
        auto to_end = beginJmp();
        auto elseLabel = genLabel();
        BCBlock elsebody = fs.elsebody ? genBlock(fs.elsebody) : BCBlock.init;
        endJmp(to_end, genLabel());
        endCndJmp(cj, elseLabel);

        doFixup(oldFixupTableCount, ifbody ? &ifbody.begin : null,
            elsebody ? &elsebody.begin : null);
        assert(oldFixupTableCount == fixupTableCount);

    }

    override void visit(ScopeStatement ss)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("ScopeStatement %s", ss.toString);
        }
        ss.statement.accept(this);
    }

    override void visit(CompoundStatement cs)
    {
        debug (ctfe)
        {
            import std.stdio;

            writefln("CompundStatement %s", cs.toString);
        }
        if (cs.statements !is null)
        {
            foreach (stmt; *(cs.statements))
            {
                if (stmt !is null)
                {
                    stmt.accept(this);
                }
                else
                {
                    IGaveUp = true;
                    return;
                }
            }
        }
        else
        {
            //TODO figure out if this is an invalid case.
            //IGaveUp = true;
            return;
        }
    }
}
