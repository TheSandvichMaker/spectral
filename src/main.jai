#import "Basic";
#import "Math";
#import "Atomics";
#import "File";
#import "Thread";
#import "System";
#import "Windows";
#import "Windows_Utf8";
#import "stb_image";

USE_SAMPLED_SPECTRUM :: true;

#load "windows.jai";
#load "directx.jai";
#load "utility.jai";
#load "random.jai";
#load "math.jai";
#load "spectrum.jai";
#load "pathtracer.jai";

g_start_time: float64;

g_blue_noise1: [8] Bitmap;
g_blue_noise3: [8] Bitmap;

Bitmap :: struct
{
    w: int;
    h: int;
    c: int;
    stride: int;
    data: [] u8;
}

Accumulation_Buffer :: struct
{
    TYPE :: Vector4;

    w: int;
    h: int;
    stride: int;
    data: *TYPE;
    frame_count: int = 1;
}

get_texel :: inline (acc: Accumulation_Buffer, x: int, y: int) -> *Vector4
{
    return cast(*Vector4) (cast(*u8) acc.data + x*size_of(Vector4) + y*acc.stride);
}

make_accumulation_buffer :: (w: int, h: int) -> Accumulation_Buffer
{
    acc: Accumulation_Buffer;
    acc.w      = w;
    acc.h      = h;
    acc.stride = size_of(acc.TYPE)*acc.w;
    acc.data   = alloc(size_of(acc.TYPE)*acc.w*acc.h);
    memset(acc.data, 0, size_of(acc.TYPE)*acc.w*acc.h);
    return acc;
}

resize :: (acc: *Accumulation_Buffer, w: int, h: int)
{
    if w != acc.w || h != acc.h
    {
        free(acc.data);
        << acc = make_accumulation_buffer(w, h);
    }
}

reset :: (acc: *Accumulation_Buffer)
{
    acc.frame_count = 1;
    memset(acc.data, 0, size_of(acc.TYPE)*acc.w*acc.h);
}

Shared_Render_Data :: struct
{
    render_cond: CONDITION_VARIABLE;
    render_lock: SRWLOCK;

    tiles_to_consume: s64;
    tiles_unfinished: s64;

    camera: Camera;
    scene: *Scene;
    accumulation_buffer: *Accumulation_Buffer;
}

Thread_Render_Data :: struct
{
    shared: *Shared_Render_Data;

    render_time: float;
}

Button :: struct
{
    ended_down: bool;
    half_presses: u8;
}

pressed :: inline (using button: Button) -> bool
{
    return half_presses > 1 || (half_presses == 1 && ended_down);
}

released :: inline (using button: Button) -> bool
{
    return half_presses > 1 || (half_presses == 1 && !ended_down);
}

down :: inline (using button: Button) -> bool
{
    return ended_down;
}

Input :: struct
{
    move_forward : Button;
    move_back    : Button;
    move_left    : Button;
    move_right   : Button;
    move_up      : Button;
    move_down    : Button;

    cursor_delta_x : int;
    cursor_delta_y : int;
}

prepare_for_next_frame :: (input: *Input)
{
    ti := type_info(Input);

    for member: ti.members
    {
        button := try_get_member(input, member, Button);
        if button
        {
            button.half_presses = 0;
        }
    }
}

handle_button_press :: (button: *Button, ended_down: bool)
{
    if button.ended_down == ended_down  button.half_presses += 1;
    button.ended_down = ended_down;
}

TILE_SIZE :: 64;

render_thread :: (thread: *Thread) -> s64
{
    data := cast(*Thread_Render_Data) thread.data;

    while true
    {
        AcquireSRWLockShared(*data.shared.render_lock);

        while data.shared.tiles_to_consume <= 0
        {
            SleepConditionVariableSRW(*data.shared.render_cond, *data.shared.render_lock, INFINITE, CONDITION_VARIABLE_LOCKMODE_SHARED);
        }

        camera := data.shared.camera;
        scene  := data.shared.scene;
        accumulation_buffer := data.shared.accumulation_buffer;

        ReleaseSRWLockShared(*data.shared.render_lock);

        tile_count_x := (accumulation_buffer.w + TILE_SIZE - 1) / TILE_SIZE;
        tile_count_y := (accumulation_buffer.h + TILE_SIZE - 1) / TILE_SIZE;
        tile_count_total := tile_count_x*tile_count_y;

        while true
        {
            tile_index := atomic_add(*data.shared.tiles_to_consume, -1) - 1;

            if tile_index < 0
            {
                break;
            }

            tile: Tile;
            tile.x0 = TILE_SIZE*(tile_index % tile_count_x);
            tile.y0 = TILE_SIZE*(tile_index / tile_count_x);
            tile.x1 = min(tile.x0 + TILE_SIZE, accumulation_buffer.w);
            tile.y1 = min(tile.y0 + TILE_SIZE, accumulation_buffer.h);

            render_scene(camera, scene, accumulation_buffer, tile);

            atomic_decrement(*data.shared.tiles_unfinished);
        }

        reset_temporary_storage();
    }

    return 0;
}

main :: ()
{
    SetProcessDPIAware();
    // Windows is very bad at thread-switching by default unless you do this. Sad.
    timeBeginPeriod(1);

    window_w: u32 = 1280;
    window_h: u32 = 1024;
    render_w: u32 = 320;
    render_h: u32 = 256;

    hwnd: HWND;

    {
        error_message: string;
        hwnd, error_message = init_window(window_w, window_h);
        if !hwnd
        {
            error_box(error_message);
            return;
        }
    }

    {
        success, error_message := init_d3d(hwnd, render_w, render_h);
        if !success  
        {
            error_box(error_message);
            return;
        }
    }

    init_assets();

    input  : Input;
    camera : Camera;
    scene  : Scene;
    init_scene(*camera, *scene);

    shared_data: Shared_Render_Data;
    shared_data.camera = camera;
    shared_data.scene = *scene;

    g_start_time := get_time();

    thread_count := get_number_of_processors() / 2;

    if thread_count > MAX_THREADS  
    {
        thread_count = MAX_THREADS;
    }

    MAX_THREADS :: 64;
    threads     : [MAX_THREADS] Thread;
    thread_data : [MAX_THREADS] Thread_Render_Data;

    for 0..thread_count-1
    {
        thread := *threads[it];
        data   := *thread_data[it];

        data.shared = *shared_data;
        thread.data = data;
        if !thread_init(thread, render_thread)
        {
            error_box("Could not create render thread.");
            return;
        }

        thread_start(thread);
    }

    quit := false;
    frame_time: float;

    render_start_time := get_time();

    accumulation_buffer := make_accumulation_buffer(render_w, render_h);

    cursor_locked := false;

    while !quit
    {
        prepare_for_next_frame(*input);

        client_rect: RECT;
        GetClientRect(hwnd, *client_rect);

        screen_rect := client_to_screen(hwnd, client_rect);

        msg: MSG;
        if PeekMessageW(*msg, null, 0, 0, PM_REMOVE)
        {
            if msg.message ==
            {
                case WM_QUIT;
                    quit = true;

                case WM_LBUTTONDOWN;
                    if !cursor_locked
                    {
                        cursor_locked = true;
                        SetCapture(hwnd);
                        ShowCursor(0);
                        ClipCursor(*screen_rect);

                        mid_point: POINT;
                        mid_point.x = (client_rect.left + client_rect.right) / 2;
                        mid_point.y = (client_rect.bottom + client_rect.top) / 2;

                        ClientToScreen(hwnd, *mid_point);
                        SetCursorPos(mid_point.x, mid_point.y);
                    }

                case WM_KEYUP;      #through;
                case WM_KEYDOWN;    #through;
                case WM_SYSKEYUP;   #through;
                case WM_SYSKEYDOWN;
                    vk_code := msg.wParam;
                    pressed := msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN;

                    if vk_code ==
                    {
                        case #char "W";  if cursor_locked  handle_button_press(*input.move_forward, pressed);
                        case #char "A";  if cursor_locked  handle_button_press(*input.move_left, pressed);
                        case #char "S";  if cursor_locked  handle_button_press(*input.move_back, pressed);
                        case #char "D";  if cursor_locked  handle_button_press(*input.move_right, pressed);
                        case VK_SPACE;   if cursor_locked  handle_button_press(*input.move_up, pressed);
                        case VK_CONTROL; if cursor_locked  handle_button_press(*input.move_down, pressed);

                        case VK_ESCAPE;
                            if cursor_locked
                            {
                                cursor_locked = false;
                                ReleaseCapture();
                                ShowCursor(1);
                                ClipCursor(null);
                            }
                    }

                case;
                    TranslateMessage(*msg);
                    DispatchMessageW(*msg);
            }
        }

        window_w = xx (client_rect.right - client_rect.left);
        window_h = xx (client_rect.bottom - client_rect.top);

        cursor_delta_x: int;
        cursor_delta_y: int;

        if cursor_locked
        {
            mid_point: POINT;
            mid_point.x = (client_rect.left + client_rect.right) / 2;
            mid_point.y = (client_rect.bottom + client_rect.top) / 2;

            ClientToScreen(hwnd, *mid_point);

            cursor: POINT;
            GetCursorPos(*cursor);

            cursor_delta_x = cursor.x - mid_point.x;
            cursor_delta_y = cursor.y - mid_point.y;

            SetCursorPos(mid_point.x, mid_point.y);
        }

        input.cursor_delta_x = cursor_delta_x;
        input.cursor_delta_y = cursor_delta_y;

        camera = update_camera(camera, input, 1.0 / 60.0);

        if atomic_read(*shared_data.tiles_unfinished) == 0
        {
            AcquireSRWLockExclusive(*shared_data.render_lock);

            render_end_time := get_time();
            render_time := render_end_time - render_start_time;
            render_start_time = render_end_time;

            resized := maybe_resize_textures(window_w, window_h, render_w, render_h);
            if resized
            {
                resize(*accumulation_buffer, render_w, render_h);
                accumulation_buffer.frame_count = 0; // because of the += 1 down below. gross
            }

            resolve_accumulation_buffer(*accumulation_buffer);
            accumulation_buffer.frame_count += 1;

            // ----------------------------------------------------

            shared_data.scene.dt = 1.0 / 60.0;
            shared_data.scene.time += shared_data.scene.dt;

            shared_data.camera = camera;
            shared_data.accumulation_buffer = *accumulation_buffer;
            shared_data.scene.frame_index += 1;

            // update_scene(shared_data.scene);

            if scene_dirty
            {
                scene_dirty = false;
                shared_data.scene.frame_index = 0;
                reset(*accumulation_buffer);
            }

            tile_count_x := (accumulation_buffer.w + TILE_SIZE - 1) / TILE_SIZE;
            tile_count_y := (accumulation_buffer.h + TILE_SIZE - 1) / TILE_SIZE;
            tile_count_total := tile_count_x*tile_count_y;

            shared_data.tiles_unfinished = tile_count_total;
            atomic_write(*shared_data.tiles_to_consume, tile_count_total); // writing this last because it's the state we check to mitigate spurious wake-ups

            ReleaseSRWLockExclusive(*shared_data.render_lock);
            WakeAllConditionVariable(*shared_data.render_cond);

            // ----------------------------------------------------

            title := tprint("render time: %ms\n", 1000.0*render_time);
            SetWindowTextW(hwnd, utf8_to_wide(title));
        }

        immediate_set_ndc_space();

        immediate_quad(0.20, 0.20, 0.80, 0.80, make_vector4(1, 0, 1, 1));
        immediate_flush();

        immediate_bind_texture(get_scene_texture());
        immediate_quad(0.25, 0.25, 0.75, 0.75, make_vector4(1, 1, 1, 1));
        immediate_flush();

        present();

        reset_temporary_storage();
    }
}

#scope_file

load_bitmap :: (path: string, channels: int) -> Bitmap
{
    w: s32;
    h: s32;
    c: s32;
    pixels := stbi_load(temp_c_string(path), *w, *h, *c, xx channels);

    bitmap: Bitmap;
    bitmap.w          = w;
    bitmap.h          = h;
    bitmap.c          = channels;
    bitmap.stride     = w*channels;
    bitmap.data.data  = pixels;
    bitmap.data.count = bitmap.stride*bitmap.h;

    return bitmap;
}

free_bitmap :: (bitmap: *Bitmap)
{
    free(bitmap.data.data);
    memset(bitmap, 0, size_of(Bitmap));
}

init_assets :: ()
{
    g_blue_noise1[0] = load_bitmap("textures/noise/LDR_LLL1_0.png", 1);
    g_blue_noise1[1] = load_bitmap("textures/noise/LDR_LLL1_1.png", 1);
    g_blue_noise1[2] = load_bitmap("textures/noise/LDR_LLL1_2.png", 1);
    g_blue_noise1[3] = load_bitmap("textures/noise/LDR_LLL1_3.png", 1);
    g_blue_noise1[4] = load_bitmap("textures/noise/LDR_LLL1_4.png", 1);
    g_blue_noise1[5] = load_bitmap("textures/noise/LDR_LLL1_5.png", 1);
    g_blue_noise1[6] = load_bitmap("textures/noise/LDR_LLL1_6.png", 1);
    g_blue_noise1[7] = load_bitmap("textures/noise/LDR_LLL1_7.png", 1);

    g_blue_noise3[0] = load_bitmap("textures/noise/LDR_RGB1_0.png", 3);
    g_blue_noise3[1] = load_bitmap("textures/noise/LDR_RGB1_1.png", 3);
    g_blue_noise3[2] = load_bitmap("textures/noise/LDR_RGB1_2.png", 3);
    g_blue_noise3[3] = load_bitmap("textures/noise/LDR_RGB1_3.png", 3);
    g_blue_noise3[4] = load_bitmap("textures/noise/LDR_RGB1_4.png", 3);
    g_blue_noise3[5] = load_bitmap("textures/noise/LDR_RGB1_5.png", 3);
    g_blue_noise3[6] = load_bitmap("textures/noise/LDR_RGB1_6.png", 3);
    g_blue_noise3[7] = load_bitmap("textures/noise/LDR_RGB1_7.png", 3);
}

init_scene :: (camera: *Camera, scene: *Scene)
{
    camera.p = make_vector3(0, 5, -15);
    camera.d = normalize(make_vector3(0, 0, 0) - camera.p);
    camera.fov = 60.0;

    scene.sky_top = 1.5*make_vector3(0.2, 0.3, 0.8);
    scene.sky_bot = 1.5*make_vector3(0.5, 0.7, 0.9);

    light := add_material(scene, .{ kind = .Emissive, color = .{ 25, 20.5, 15 } });
    red   := add_material(scene, .{ ior = 2.1, color = .{ 1, 0, 0 } });
    green := add_material(scene, .{ ior = 1.5, color = .{ 0, 1, 0 } });
    blue  := add_material(scene, .{ ior = 1.5, color = .{ 0, 0, 1 } });

    light_sphere: Sphere;
    light_sphere.p = make_vector3(3, 10, 2);
    light_sphere.r = 3.0;
    light_sphere.material_index = light;
    
    add_primitive(scene, light_sphere);

    sphere: Sphere;
    sphere.p = make_vector3(0, 0, 0);
    sphere.r = 4.0;
    sphere.material_index = red;

    add_primitive(scene, sphere);

    box: Box;
    box.p = make_vector3(0,-6, 0);
    box.r = make_vector3(5, 2, 5);
    box.material_index = green;

    add_primitive(scene, box);

    plane: Plane;
    plane.n = make_vector3(0, 1, 0);
    plane.p = make_vector3(0, -8.0, 0);
    plane.material_index = blue;

    add_primitive(scene, plane);
}

update_scene :: (using scene: *Scene)
{
    scene_dirty = true;

    new_x := 10.0*sin(2.0*time);
    spheres[0].dp.x = (new_x - spheres[0].p.x) / dt;
    spheres[0]. p.x = new_x;
}

scene_dirty := false;

update_camera :: (camera_: Camera, input: Input, dt: float) -> Camera
{
    camera := camera_;

    x, y, z := basis_vectors(camera.d);

    move_speed := 25.0;
    move_delta: Vector3;

    if down(input.move_forward)  move_delta -= z;
    if down(input.move_back)     move_delta += z;
    if down(input.move_left)     move_delta -= x;
    if down(input.move_right)    move_delta += x;
    if down(input.move_down)     move_delta -= WORLD_UP;
    if down(input.move_up)       move_delta += WORLD_UP;

    move_delta = normalize(move_delta);

    camera.p += dt*move_speed*move_delta;

    turn_speed := 0.1;
    turn_delta : Vector3;

    turn_delta += x*cast(float) input.cursor_delta_x;
    turn_delta -= y*cast(float) input.cursor_delta_y;

    camera.prev_d = camera.d;
    camera.d += dt*turn_speed*turn_delta;
    camera.d = normalize(camera.d);

    if length(move_delta) > 0.0 ||
       length(turn_delta) > 0.0
    {
        scene_dirty = true;
    }

    return camera;
}

// win32

window_proc :: (hWnd: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call 
{
    hdc : HDC;
 
    if message == 
    { 
        case WM_DESTROY;
            PostQuitMessage(0); 

        case WM_MOUSEACTIVATE;
            return MA_ACTIVATEANDEAT;
     
        case; 
            return DefWindowProcW(hWnd, message, wParam, lParam); 
    } 
 
    return 0; 
} 

init_window :: (w: int, h: int) -> hwnd: HWND, error_message: string
{
    window_class: WNDCLASSEXW;
    window_class.cbSize        = size_of(WNDCLASSEXW);
    window_class.style         = CS_HREDRAW|CS_VREDRAW;
    window_class.lpfnWndProc   = xx window_proc;
    window_class.cbClsExtra    = 0;
    window_class.cbWndExtra    = 0;
    window_class.hIcon         = LoadIconW(null, utf8_to_wide("APPICON"));
    window_class.hCursor       = LoadCursorW(null, IDC_ARROW);
    window_class.lpszClassName = utf8_to_wide("SpectralWindowClass");

    if !RegisterClassExW(*window_class)
    {
        return null, "Failed to register window class";
    }

    window_rect: RECT;
    window_rect.left   = 0;
    window_rect.top    = 0;
    window_rect.right  = xx w;
    window_rect.bottom = xx h;

    AdjustWindowRect(*window_rect, WS_OVERLAPPEDWINDOW, BOOL.FALSE);

    hwnd := CreateWindowExW(0, utf8_to_wide("SpectralWindowClass"), utf8_to_wide("Spectral Pathtracer"),
                            WS_OVERLAPPEDWINDOW,
                            CW_USEDEFAULT, CW_USEDEFAULT, 
                            window_rect.right - window_rect.left,
                            window_rect.bottom - window_rect.top,
                            null, null, null, null);

    if !hwnd
    {
        return null, "Failed to create window";
    }

    ShowWindow(hwnd, SW_SHOWDEFAULT);

    return hwnd, "";
}

error_box :: (message: string)
{
    MessageBoxW(null, utf8_to_wide(message), utf8_to_wide("Error"), MB_OK);
}

client_to_screen :: (hwnd: HWND, rect: RECT) -> RECT
{
    // good API, windows...

    screen_rect_lr: POINT;
    screen_rect_lr.x = rect.left;
    screen_rect_lr.y = rect.right;

    ClientToScreen(hwnd, *screen_rect_lr);

    screen_rect_tb: POINT;
    screen_rect_tb.x = rect.top;
    screen_rect_tb.y = rect.bottom;

    ClientToScreen(hwnd, *screen_rect_tb);

    result: RECT;
    result.left   = screen_rect_lr.x;
    result.right  = screen_rect_lr.y;
    result.top    = screen_rect_tb.x;
    result.bottom = screen_rect_tb.y;

    return result;
}
