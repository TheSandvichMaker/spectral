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

try_get_member :: (data: *$T, member: Type_Info_Struct_Member, $type: Type) -> *type
{
    ti := type_info(T);
    assert(ti.type == .STRUCT);

    if member.type == type_info(type)
    {
        base := cast(*u8) data;
        return cast(*type) (base + member.offset_in_bytes);
    }

    return null;
}

transmute :: inline (value: $T, $target_type: Type) -> target_type
{
    return << (cast(*target_type) *value);
}
