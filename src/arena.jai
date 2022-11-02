Arena :: struct
{
    CAPACITY          :: 16 << 30; // 16 GiB
    COMMIT_CHUNK_SIZE :: 16 << 10; // 16 KiB
    DEFAULT_COMMIT_PRESERVE_THRESHOLD :: COMMIT_CHUNK_SIZE;

    owns_memory: bool; // tracks whether arena was initialized with init_with_buffer, or if it allocated memory itself

    committed : *u8;
    end       : *u8;
    at        : *u8;
    buffer    : *u8;
}

Arena_Marker :: #type,distinct *u8;

init_with_buffer :: (using arena: *Arena, init_buffer: []u8)
{
    assert(!buffer);
    buffer    = init_buffer.data;
    at        = buffer;
    end       = buffer + init_buffer.count;
    committed = end;

    owns_memory = false;
}

alloc :: (using arena: *Arena, size: int, align: int = 16) -> *void #must
{
    if !buffer
    {
        buffer    = VirtualAlloc(null, CAPACITY, MEM_RESERVE, PAGE_NOACCESS);
        at        = buffer;
        end       = buffer + CAPACITY;
        committed = buffer;

        owns_memory = true;
    }

    result := align_forward(at, align);
    if result + size < end
    {
        if result + size > committed
        {
            to_commit := align_forward(result + size - committed, COMMIT_CHUNK_SIZE);
            VirtualAlloc(committed, xx to_commit, MEM_COMMIT, PAGE_READWRITE);
            committed += to_commit;
        }

        at = result + size;
        return result;
    }
    else
    {
        return null;
    }
}

alloc :: (arena: *Arena, $T: Type, init := true) -> *T #must
{
    // TODO: align_of
    result := cast(*T)alloc(arena, size_of(T), 16);
    if init  Initialize(result);
    return result;
}

alloc_array :: (arena: *Arena, $T: Type, count: int, init := true) -> []T #must
{
    // TODO: align_of
    result: []T;
    result.data  = cast(*T)alloc(arena, count*size_of(T), 16);
    result.count = count;
    if init  Initialize(result);
    return result;
}

resize_array :: (arena: *Arena, array: []$T, new_count: s64, init := true) -> []T #must
{
    assert(array.data >= arena.buffer && old_memory < arena.at);

    size     := size_of(T)*new_count;
    old_size := size_of(T)*array.count;

    if size > old_size
    {
        top := cast(*u8)array.data + old_size;
        if top == arena.at
        {
            _ := alloc(arena, size - old_size);
            return array;
        }
        else
        {
            new_array := alloc_array(arena, new_count, init=false);
            memcpy(memory, array.data, old_size);
            for array.count..new_count-1
            {
                Initialize(*new_array.data[it]);
            }
            return new_array;
        }
    }
    else
    {
        return array;
    }
}

arena_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void
{
    arena := cast(*Arena)allocator_data;

    if #complete mode ==
    {
      case .ALLOCATE;
        return alloc(arena, size);

      case .RESIZE;
        assert(old_memory >= arena.buffer && old_memory < arena.at);

        if size > old_size
        {
            top := cast(*u8)old_memory + old_size;
            if top == arena.at
            {
                _ := alloc(arena, size - old_size);
                return old_memory;
            }
            else
            {
                memory := alloc(arena, size);
                memcpy(memory, old_memory, old_size);
                return memory;
            }
        }
        else
        {
            return old_memory;
        }

      case .FREE;
        return null;
    }
}

allocator :: (arena: *Arena) -> Allocator
{
    result: Allocator;
    result.proc = arena_allocator_proc;
    result.data = arena;
    return result;
}

size_remaining :: (using arena: Arena, align := 16) -> int #must
{
    return align_forward(at, align) - end;
}

reset :: (using arena: *Arena)
{
    at = buffer;
}

reset_and_decommit :: (using arena: *Arena, threshold := Arena.DEFAULT_COMMIT_PRESERVE_THRESHOLD)
{
    if !owns_memory
    {
        reset(arena);
        return;
    }

    decommit_from  := buffer + threshold;
    decommit_bytes := max(0, committed - decommit_from);

    VirtualFree(buffer, xx decommit_bytes, MEM_DECOMMIT);
    at        = buffer;
    committed = buffer;
}

release :: (using arena: *Arena)
{
    if !owns_memory
    {
        reset(arena);
        return;
    }

    VirtualFree(buffer, xx (end - buffer), MEM_RELEASE);
    Initialize(arena);
}

get_marker :: (using arena: *Arena) -> Arena_Marker
{
    return cast(Arena_Marker)at;
}

reset_to_marker :: (using arena: *Arena, marker_: Arena_Marker)
{
    marker := cast(*u8)marker_;
    if !marker  marker = buffer;

    assert(marker >= buffer && marker < end);
    at = marker;
}

ScopedMemory :: (arena: *Arena) #expand
{
    marker := get_marker(arena);
    `defer reset_to_marker(arena, marker);
}

#scope_file

align_forward :: inline (address: s64, align: s64) -> s64 #must
{
    // https://aggregate.org/MAGIC/#Alignment of Pointers
    result := (address + (align-1)) & -align;
    return result;
}

align_forward :: inline (address: *$T, align: s64) -> *T #must
{
    return cast(*T)align_forward(cast(s64)address, align);
}
