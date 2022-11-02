//
// Public API
// modeled after https://www.rfleury.com/p/ui-part-1-the-interaction-medium
//

#if false
{

UI_Size_Kind :: enum
{
    Null;
    Pixels;
    TextContent;
    PercentOfParent;
    SumOfChildren;
}

UI_Size :: struct
{
    kind: UI_Size_Kind;
    value      : float;
    strictness : float;
}

UI_Key :: struct
{
    value: u64;
}

operator == :: (a: UI_Key, b: UI_Key) -> bool
{
    return a.value == b.value;
}

UI_Key_Null :: UI_Key.{0};

UI_Axis2 :: enum
{
    X;
    Y;
}

UI_Range :: struct
{
    min: float;
    max: float;
}

UI_Rect :: union
{
    struct
    {
        x: UI_Range;
        y: UI_Range;
    }
    v: [2]UI_Range;
}

UI_Box_Flags :: enum_flags
{
    Clickable;
    // ViewScroll;
    DrawText;
    DrawBorder;
    DrawBackground;
    DrawDropShadow;
    Clip;
    // HotAnimation;
    // ActiveAnimation;
}

UI_Command :: struct
{
    using Kind :: enum
    {
        Remove;
    }

    kind : Kind;
    key  : UI_Key;
}

UI_Box :: struct
{
    first  : *UI_Box;
    last   : *UI_Box;
    next   : *UI_Box;
    prev   : *UI_Box;
    parent : *UI_Box;

    hash_next : *UI_Box;

    key: UI_Key;
    last_frame_touched_index: u64;

    flags: UI_Box_Flags;
    text: string;
    semantic_size: [2]UI_Size;
    layout_axis: UI_Axis2;

    background_color: Vector4;

    computed_size         : [2]float;
    computed_rel_position : [2]float;
    rect                  : UI_Rect;

    hot_t    : float;
    active_t : float;
}

UI_Input_Button :: enum
{
    LeftMouse;
    MiddleMouse;
    RightMouse;

    Shift;
    Control;
    Alt;

    Down;
    Up;
    Left;
    Right;
}

UI_Comm :: struct
{
    box: *UI_Box;
    clicked           : bool;
    double_clicked    : bool;
    right_clicked     : bool;
    pressed           : bool;
    released          : bool;
    dragging          : bool;
    hovering          : bool;
}

ui_key_from_string :: (text: string) -> UI_Key
{
    start := find_index_from_left(text, "###");
    if start == -1  start  = 0;
    else            start += 3;

    hash_input := advance(text, start);
    hash := fnv1a(hash_input);

    key: UI_Key;
    key.value = hash;
    
    return key;
}

ui_mouse_p :: () -> Vector2
{
    return ui.mouse_p;
}

ui_mouse_delta :: () -> Vector2
{
    return ui.mouse_p - ui.prev_mouse_p;
}

ui_make_box :: (flags: UI_Box_Flags, format_string: string, args: ..Any) -> *UI_Box
{
    text_formatted := tprint(format_string, args);
    key := ui_key_from_string(text_formatted);
    box := ui__get_box(key);
    box.flags       = flags;
    box.text        = text_formatted;
    box.layout_axis = .Y;
    return box;
} @PrintLike

set_layout :: (box: *UI_Box, axis: UI_Axis2)
{
    box.layout_axis = axis;
}

set_text :: (box: *UI_Box, text: string)
{
    box.text = copy_string(text, allocator=temp);
}

ui_window :: (x: float, y: float, w: float, h: float, title: string, args: ..Any) -> *UI_Box
{
    box := ui_make_box(UI_Box_Flags.Clip|.DrawBackground|.DrawDropShadow, title, args);
    box.background_color = make_vector4(0, 0, 0, 0.25);

    box.rect.x.min = x;
    box.rect.y.min = y;

    box.semantic_size[UI_Axis2.X].kind  = .Pixels;
    box.semantic_size[UI_Axis2.X].value = w;

    box.semantic_size[UI_Axis2.Y].kind  = .Pixels;
    box.semantic_size[UI_Axis2.Y].value = h;

    return box;
}

ui_comm_from_box :: (box: *UI_Box) -> UI_Comm
{
    return .{};
}

ui_push_parent :: (box: *UI_Box) -> *UI_Box
{
    old_parent := ui.current_parent;

    box.parent = ui.current_parent;
    ui.current_parent = box;

    return old_parent;
}

ui_pop_parent :: () -> *UI_Box
{
    old_parent := ui.current_parent;

    assert(ui.current_parent != null);
    ui.current_parent = ui.current_parent.parent;

    return old_parent;
}

ui_solve_layout :: (root: *UI_Box)
{
    for axis: enum_values(UI_Axis2)
    {
        ui__layout_solve_independent_sizes(root, axis);
        ui__layout_solve_upwards_dependent_sizes(root, axis);
        ui__layout_solve_downwards_dependent_sizes(root, axis);
        ui__layout_solve_size_violations(root, axis);
        ui__layout_finalize_positions(root, axis);
    }
}

ui_post_command :: (command: UI_Command)
{
    if always(ui.command_count < ui.commands.count)
    {
        ui.commands[ui.command_count] = command;
        ui.command_count += 1;
    }
}

ui_begin :: ()
{
    ui.first_text_node = null;
    ui.last\_text_node = null;

    ui.mouse_delta = ui.mouse_p - ui.prev_mouse_p;

    zero_array(ui.pressed);
    zero_array(ui.released);

    // clear connections
    for 0..ui.box_hash.count-1
    {
        box := ui.box_hash[it];
        while box
        {
            box.first  = null;
            box.last   = null;
            box.next   = null;
            box.prev   = null;
            box.parent = null;

            box = box.next;
        }
    }
}

ui_end :: ()
{
    assert(ui.current_parent == null);

    for 0..ui.box_hash.count-1
    {
        box := ui.box_hash[it];
        while box
        {
            if box.last_frame_touched_index < ui.current_frame_index
            {
                command: UI_Command;
                command.kind = .Remove;
                command.key  = box.key;
                ui_post_command(command);
            }

            box = box.next;
        }
    }

    for 0..ui.command_count-1
    {
        command := *ui.commands[it];
        if command.kind ==
        {
          case .Remove;
            mask  := ui.box_hash.count-1;
            index := command.key.value & mask;
            remove_at := *ui.box_hash[index];
            while <<remove_at && (<<remove_at).key != command.key  remove_at = *(<<remove_at).hash_next;

            removed := <<remove_at;
            <<remove_at = (<<remove_at).hash_next;

            removed.next = ui.first_free_box;
            ui.first_free_box = removed;
        }
    }

    ui.current_frame_index += 1;
}

ui_draw :: (list: *Immediate_Draw_List, box: *UI_Box)
{
    draw := immediate_draw(list);
    draw.transform = pixel_coordinates();

    for :depth_first_pre_order node: box
    {
        if node.flags & .DrawBackground
        {
            immediate_rect(list, node.rect.x.min, node.rect.y.min, node.rect.x.max, node.rect.y.max, color=node.background_color);
            print("Drawing box '%'\n", node.text);
        }
    }
}

ui_provide_mouse_position :: (mouse_position: Vector2)
{
    ui.mouse_p = mouse_position;
}

ui_provide_button_state :: (button: UI_Input_Button, state: bool)
{
    ui.pressed [button] =  state && !ui.down[button];
    ui.released[button] = !state &&  ui.down[button];
    ui.down    [button] =  state;
}

ui_provide_text :: (text: string)
{
    node := alloc(*ui.arena, UI_Text_Node);
    node.text = copy_string(text, allocator=temp);
    append_queue(*ui.first_text_node, *ui.last_text_node, node);
}

// iterators

next :: (root: *UI_Box, body: Code, flags: For_Flags) #expand
{
    `it_index := 0;
    `it := root;

    while it
    {
        defer it = it.next;

        #insert body;
    }
}

prev :: (root: *UI_Box, body: Code, flags: For_Flags) #expand
{
    `it_index := 0;
    `it := root;

    while it
    {
        defer it = it.prev;

        #insert body;
    }
}

depth_first_pre_order :: (root: *UI_Box, body: Code, flags: For_Flags) #expand
{
    `it_index := 0;
    `it := root;

    while it
    {
        defer it_index += 1;

        #insert body;

        next: *UI_Box = null;

        if it.first
        {
            next = it.first;
        }
        else
        {
            p := it;
            while p
            {
                if p.next
                {
                    next = p.next;
                    break;
                }

                p = p.parent;
            }
        }

        it = next;
    }
}

depth_first_post_order :: (root: *UI_Box, body: Code, flags: For_Flags) #expand
{
    `it_index := 0;
    `it := root;

    while it.first  it = it.first;

    while it
    {
        defer it_index += 1;

        #insert body;

        if it.next  it = it.next;
        else        it = it.parent;
    }
}

//
//
//

#scope_file

//
// Private
//

UI_State :: struct
{
    arena: Arena;

    current_frame_index: u64;

    first_text_node : *UI_Text_Node;
    last\_text_node : *UI_Text_Node;

    command_count: int;
    commands: [4096]UI_Command;

    mouse_p      : Vector2;
    prev_mouse_p : Vector2;
    mouse_delta  : Vector2;

    pressed  : [#run enum_count(UI_Input_Button)] bool;
    released : [#run enum_count(UI_Input_Button)] bool;
    down     : [#run enum_count(UI_Input_Button)] bool;

    box_hash: [4096]*UI_Box;
    first_free_box: *UI_Box;

    current_parent: *UI_Box;
}

ui: UI_State;

UI_Text_Node :: struct
{
    next: *UI_Text_Node;
    text: string;
}

ui__get_box :: (key: UI_Key) -> *UI_Box
{
    using ui;

    mask  := cast(u64)box_hash.count-1;
    index := key.value & mask;

    box := box_hash[index];
    while box && box.key != key  box = box.hash_next;

    if !box
    {
        if !ui.first_free_box
        {
            ui.first_free_box = alloc(*ui.arena, UI_Box);
        }
        box = ui.first_free_box;
        ui.first_free_box = box.next;

        box.hash_next = box_hash[index];
        box_hash[index] = box;
    }

    // need to save this
    hash_next := box.hash_next;

    Initialize(box);
    box.hash_next = hash_next;

    box.key = key;

    box.parent = current_parent;

    if box.parent  
    {
        if box.parent.last
        {
            box.prev = box.parent.last;
            box.prev.next = box;
            box.parent.last = box;
        }
        else
        {
            box.parent.first = box;
            box.parent.last  = box;
        }
    }

    box.last_frame_touched_index = current_frame_index;

    return box;
}

ui__layout_solve_independent_sizes :: (root: *UI_Box, axis: UI_Axis2)
{
    for :depth_first_pre_order box: root
    {
        semantic := *box.semantic_size[axis];
        assert(semantic.kind != .Null);

        if semantic.kind ==
        {
          case .Pixels;
            box.computed_size[axis] = semantic.value;
          case .TextContent;
            // @Incomplete
        }
    }
}

ui__layout_solve_upwards_dependent_sizes :: (root: *UI_Box, axis: UI_Axis2)
{
    for :depth_first_pre_order box: root
    {
        semantic := *box.semantic_size[axis];
        assert(semantic.kind != .Null);

        if semantic.kind == .PercentOfParent
        {
            assert(box.parent != null);
            box.computed_size[axis] = box.parent.computed_size[axis]*semantic.value;
        }
    }
}

ui__layout_solve_downwards_dependent_sizes :: (root: *UI_Box, axis: UI_Axis2)
{
    box := root;
    while box.first  box = box.first;

    while box
    {
        defer box = box.parent;

        semantic := *box.semantic_size[axis];
        assert(semantic.kind != .Null);

        if semantic.kind == .SumOfChildren
        {
            for :next child: box
            {
                box.computed_size[axis] += child.computed_size[axis];
            }
        }
    }
}

ui__layout_solve_size_violations :: (root: *UI_Box, axis: UI_Axis2)
{
    for :depth_first_pre_order box: root
    {
        // @Incomplete
    }
}

ui__layout_finalize_positions :: (root: *UI_Box, axis: UI_Axis2)
{
    for :depth_first_pre_order box: root
    {
        if box.layout_axis == axis
        {
            if box.prev
            {
                box.computed_rel_position[axis] = box.prev.computed_rel_position[axis] + box.prev.computed_size[axis];
            }
        }

        if box.parent
        {
            if axis == .Y // because Y is up, a bit lame... can we make this axis independent and also support flipped y easily?
            {
                box.rect.v[axis].min = box.parent.rect.v[axis].max - box.computed_rel_position[axis] - box.computed_size[axis];
            }
            else
            {
                box.rect.v[axis].min = box.parent.rect.v[axis].min + box.computed_rel_position[axis];
            }
        }
        box.rect.v[axis].max = box.rect.v[axis].min + box.computed_size[axis];
    }
}

//
// Utility
//

fnv1a :: (input: string) -> u64
{
    PRIME  : u64 : 0x00000100000001B3;
    OFFSET : u64 : 0xcbf29ce484222325;

    hash := OFFSET;
    for 0..input.count-1
    {
        hash = hash^input[it];
        hash = hash*PRIME;
    }

    return hash;
}

//
//
//

#scope_export

//
//
//

test_ui_box_traversal :: ()
{
    push_nodes :: (parent: *UI_Box, left: u64, right: u64) -> *UI_Box, *UI_Box
    {
        l := New(UI_Box);
        l.key.value = left;

        r := New(UI_Box);
        r.key.value = right;

        l.parent = parent;
        r.parent = parent;

        parent.first      = l;
        parent.first.next = r;

        return l, r;
    }

    root := New(UI_Box);
    root.key = .{1};

    n2, n3 := push_nodes(root, 2, 3);
    n4, n5 := push_nodes(n2,   4, 5);

    pre\_order_values := u64.[1, 2, 4, 5, 3];
    post_order_values := u64.[4, 5, 2, 3, 1];

    failure := false;

    {
        i := 0;
        for :depth_first_pre_order n: root
        {
            defer i += 1;

            if n.key.value != pre_order_values[i]
            {
                print("Failure! Pre-order node for index % did not match (% != %)\n", i, n.key.value, pre_order_values[i]);
                failure = true;
            }
        }
    }

    {
        i := 0;
        for :depth_first_post_order n: root
        {
            defer i += 1;

            if n.key.value != post_order_values[i]
            {
                print("Failure! Post-order node for index % did not match (% != %)\n", i, n.key.value, post_order_values[i]);
                failure = true;
            }
        }
    }

    if failure  assert(false, "UI_Box traversal test failed.");
}

}
