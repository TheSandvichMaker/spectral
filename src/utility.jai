//
// asserts
//

always :: inline (arg: bool, message := "", args: .. Any, loc := #caller_location) -> bool
{
    assert(arg, message, args, loc);
    return arg;
}

never :: inline (arg: bool, message := "", args: .. Any, loc := #caller_location) -> bool
{
    assert(!arg, message, args, loc);
    return arg;
}

//
// metaprogramming
//

member_data :: (base: *$T, member: Type_Info_Struct_Member) -> *void
{
    return (cast(*u8)base + member.offset_in_bytes);
}

try_get_member :: (data: *$T, member: Type_Info_Struct_Member, $type: Type) -> *type
{
    ti := type_info(T);
    assert(ti.type == .STRUCT);

    if member.type == type_info(type)
    {
        return member_data(data, member);
    }

    return null;
}

get_member :: (data: *$T, member: Type_Info_Struct_Member, $type: Type) -> *type
{
    ti := type_info(T);
    assert(ti.type == .STRUCT);

    return cast(*type) member_data(data, member);
}

enum_count :: ($T: Type) -> s64
{
    ti := type_info(T);
    assert(ti.type == .ENUM);

    return ti.values.count;
}

enum_values :: inline ($t: Type) -> []t
{
    return enum_values_as_enum(t);
}

transmute :: inline (value: $T, $target_type: Type) -> target_type
{
    return << (cast(*target_type) *value);
}

c_align_of :: (ti: *Type_Info) -> s64
{
    result: s64 = 1;

    if ti.type ==
    {
        case .STRUCT;
            ti_struct := cast(*Type_Info_Struct)ti;
            for member: ti_struct.members
            {
                result = max(result, c_align_of(member.type));
            }

        case;
            result = ti.runtime_size;
    }

    return result;
}

c_align_of :: inline ($T: Type) -> s64
{
    result := #run c_align_of(type_info(T));
    return result;
}

//
// initialization
//

Initialize :: (value: *$T)
{
    ini :: initializer_of(T);

    #if ini  inline  ini(value);
    else     zero_struct(value);
}

Initialize :: (value: []$T)
{
    ini :: initializer_of(T);

    #if ini
    {
        for *it: value
        {
            inline ini(it);
        }
    }
    else
    {
        zero_memory(size_of(T)*value.count, value.data);
    }
}

Initialize_Dynamic :: (memory: *void, ti: *Type_Info)
{
    if ti.type == .STRUCT
    {
        ti_struct := cast(*Type_Info_Struct)ti;
        if ti_struct.initializer  ti_struct.initializer(memory);
        else                      zero_memory(ti.runtime_size, memory);
    }
    else
    {
        zero_memory(ti.runtime_size, memory);
    }
}

//
// memory routines
//

set_memory :: (count_: int, memory_: *void, value_: u8) #expand
{
    // Because this is a macro right now, if we don't put these arguments into some variables,
    // the compiler will complain you can't pin a constant if one of the arguments was a constant
    count  := count_;
    memory := memory_;
    value  := value_;

    #asm
    {
        memory === di;
        value  === a;
        count  === c;
        rep_stos.b memory, value, count;
    }
}

zero_memory :: (count: int, memory: *void) #expand
{
    set_memory(count, memory, 0);
}

zero_array :: (array: []$T) #expand
{
    set_memory(array.count, array.data, 0);
}

zero_struct :: (value: *$T) #expand
{
    zero_memory(size_of(T), value);
}

copy_memory :: (count_: int, source_: *void, destination_: *void) #expand // <-- note making this a macro stops the bytecode inliner from inlining anywhere this is used right now
{
    // @Speed: This is not necessarily very fast?  https://twitter.com/rygorous/status/985727873880223744
    // "Don't use __movsb to copy a small number of bytes, even a hand-written loop copying byte by byte will be faster; 
    //  REP MOVS* have significant setup overhead. (They start to be interesting around a kilobyte or so, or if either source/destination isn't in L1.)"

    // or maybe it's fine https://github.com/microsoft/mimalloc/issues/201
    // seems to be merged into mimalloc https://github.com/microsoft/mimalloc/blob/f2712f4a8f038a7fb4df2790f4c3b7e3ed9e219b/include/mimalloc-internal.h#L1012

    // but I guess if you're reallocing hopefully you have a decent amount of bytes to begin with

    // of course, good old https://hero.handmade.network/forums/code-discussion/t/157-memory_bandwidth_+_implementing_memcpy

    // Because this is a macro right now, if we don't put these arguments into some variables,
    // the compiler will complain you can't pin a constant if one of the arguments was a constant
    count       := count_;
    source      := source_;
    destination := destination_;

    #asm
    {
        source      === si;
        destination === di;
        count       === c;
        rep_movs.b destination, source, count;
    }
}

//
// linked list manipulation
//

append_queue :: (first: **$T, last: **T, node: *T)
{
    if first
    {
        (<<last).next = node;
        node = (<<last);
    }
    else
    {
        (<<first) = node;
        (<<last ) = node;
    }
}
