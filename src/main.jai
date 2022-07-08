#import "Basic";
#import "Math";
#import "Atomics";

USE_SAMPLED_SPECTRUM :: true;

#load "windows.jai";
#load "utility.jai";
#load "random.jai";
#load "math.jai";
#load "spectrum.jai";
#load "pathtracer.jai";

g_start_time: float64;
g_time: float;

Bitmap :: struct
{
    w: int;
    h: int;
    stride: int;
    data: [] u8;
}

Accumulation_Buffer :: struct
{
    w: int;
    h: int;
    stride: int;
    data: *Vector3;
    frame_count: int = 1;
}

get_texel :: inline (acc: Accumulation_Buffer, x: int, y: int) -> *Vector3
{
    return cast(*Vector3) (cast(*u8) acc.data + x*size_of(Vector3) + y*acc.stride);
}

make_accumulation_buffer :: (w: int, h: int) -> Accumulation_Buffer
{
    acc: Accumulation_Buffer;
    acc.w      = w;
    acc.h      = h;
    acc.stride = size_of(Vector3)*acc.w;
    acc.data   = alloc(size_of(Vector3)*acc.w*acc.h);
    memset(acc.data, 0, size_of(Vector3)*acc.w*acc.h);
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
    memset(acc.data, 0, size_of(Vector3)*acc.w*acc.h);
}

Shared_Render_Data :: struct
{
    render_cond: CONDITION_VARIABLE;
    render_lock: SRWLOCK;

    tiles_to_consume: s64;
    tiles_unfinished: s64;

    frame_index: int;

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

            render_scene(camera, scene, accumulation_buffer, tile, data.shared.frame_index);

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

    render_w := 480;
    render_h := 360;

    {
        success, error_message := init_window(render_w, render_h);
        if !success
        {
            error_box(error_message);
            return;
        }
    }

    {
        success, error_message := init_d3d();
        if !success  
        {
            error_box(error_message);
            return;
        }
    }

    input: Input;

    camera: Camera;
    scene: Scene;
    init_scene(*camera, *scene);

    shared_data: Shared_Render_Data;
    shared_data.frame_index = 1;
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
                    }

                case WM_KEYUP;      #through;
                case WM_KEYDOWN;    #through;
                case WM_SYSKEYUP;   #through;
                case WM_SYSKEYDOWN;
                    vk_code := msg.wParam;
                    pressed := msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN;

                    if vk_code ==
                    {
                        case #char "W";  handle_button_press(*input.move_forward, pressed);
                        case #char "A";  handle_button_press(*input.move_left, pressed);
                        case #char "S";  handle_button_press(*input.move_back, pressed);
                        case #char "D";  handle_button_press(*input.move_right, pressed);
                        case VK_SPACE;   handle_button_press(*input.move_up, pressed);
                        case VK_CONTROL; handle_button_press(*input.move_down, pressed);

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

        render_w = xx (client_rect.right - client_rect.left);
        render_h = xx (client_rect.bottom - client_rect.top);

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

        if atomic_read(*shared_data.tiles_unfinished) == 0
        {
            AcquireSRWLockExclusive(*shared_data.render_lock);

            render_end_time := get_time();
            render_time := render_end_time - render_start_time;
            render_start_time = render_end_time;

            resized := maybe_resize_textures(render_w, render_h);
            if resized
            {
                resize(*accumulation_buffer, render_w, render_h);
                accumulation_buffer.frame_count = 0; // because of the += 1 down below. gross
            }

            resolve_accumulation_buffer(*accumulation_buffer);
            accumulation_buffer.frame_count += 1;

            if updated_camera
            {
                updated_camera = false;
                reset(*accumulation_buffer);
            }

            tile_count_x := (accumulation_buffer.w + TILE_SIZE - 1) / TILE_SIZE;
            tile_count_y := (accumulation_buffer.h + TILE_SIZE - 1) / TILE_SIZE;
            tile_count_total := tile_count_x*tile_count_y;

            shared_data.camera = update_camera(shared_data.camera, input, 1.0 / 60.0);
            shared_data.accumulation_buffer = *accumulation_buffer;

            g_time = cast(float) (get_time() - g_start_time);

            shared_data.frame_index += 1;

            shared_data.tiles_unfinished = tile_count_total;
            atomic_write(*shared_data.tiles_to_consume, tile_count_total); // writing this last because it's the state we check to mitigate spurious wake-ups

            ReleaseSRWLockExclusive(*shared_data.render_lock);
            WakeAllConditionVariable(*shared_data.render_cond);

            title := tprint("render time: %ms\n", 1000.0*render_time);
            SetWindowTextW(hwnd, utf8_to_wide(title));
        }

        present();

        reset_temporary_storage();
    }
}

#scope_file

init_scene :: (camera: *Camera, scene: *Scene)
{
    camera.p = make_vector3(0, 5, -15);
    camera.d = normalize(make_vector3(0, 0, 0) - camera.p);
    camera.fov = 60.0;

    red   := add_material(scene, .{ color = .{ 1, 0, 0 } });
    green := add_material(scene, .{ color = .{ 0, 1, 0 } });
    blue  := add_material(scene, .{ color = .{ 0, 0, 1 } });

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
    plane.d = -8.0;
    plane.material_index = blue;

    add_primitive(scene, plane);
}

updated_camera := false;

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

    camera.d += dt*turn_speed*turn_delta;
    camera.d = normalize(camera.d);

    if length(move_delta) > 0.0 ||
       length(turn_delta) > 0.0
    {
        updated_camera = true;
    }

    return camera;
}

// win32

hwnd: HWND;

window_proc :: (hWnd: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call 
{
    hdc : HDC;
 
    if message == 
    { 
        case WM_DESTROY;
            PostQuitMessage(0); 
     
         case; 
            return DefWindowProcW(hWnd, message, wParam, lParam); 
    } 
 
    return 0; 
} 

init_window :: (w: int, h: int) -> success: bool, error_message: string
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
        return false, "Failed to register window class";
    }

    window_rect: RECT;
    window_rect.left   = 0;
    window_rect.top    = 0;
    window_rect.right  = xx w;
    window_rect.bottom = xx h;

    AdjustWindowRect(*window_rect, WS_OVERLAPPEDWINDOW, BOOL.FALSE);

    hwnd = CreateWindowExW(0, utf8_to_wide("SpectralWindowClass"), utf8_to_wide("Spectral Pathtracer"),
                           WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, 
                           window_rect.right - window_rect.left,
                           window_rect.bottom - window_rect.top,
                           null, null, null, null);

    if !hwnd
    {
        return false, "Failed to create window";
    }

    ShowWindow(hwnd, SW_SHOWDEFAULT);

    return true, "";
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

// d3d11

D3D_State :: struct
{
    driver_type   := D3D_DRIVER_TYPE.NULL;
    feature_level := D3D_FEATURE_LEVEL._11_0;

    device                         : *ID3D11Device;
    device_context                 : *ID3D11DeviceContext;
    swap_chain                     : *IDXGISwapChain1;

    nearest_neighbour_sampler      : *ID3D11SamplerState;

    fullscreen_vs                  : *ID3D11VertexShader;
    resolve_accumulation_buffer_cb : *ID3D11Buffer;
    resolve_accumulation_buffer_ps : *ID3D11PixelShader;

    accumulation_buffer            : *ID3D11Texture2D;
    accumulation_buffer_srv        : *ID3D11ShaderResourceView;

    target_texture                 : *ID3D11Texture2D;
    target_texture_srv             : *ID3D11ShaderResourceView;
    target_texture_rtv             : *ID3D11RenderTargetView;

    back_buffer                    : *ID3D11Texture2D;
    back_buffer_rtv                : *ID3D11RenderTargetView;

    viewport                       : D3D11_VIEWPORT;

    display_w: DWORD;
    display_h: DWORD;
}

d3d: D3D_State;

Resolve_Accumulation_Buffer_PS_Parameters :: struct
{
    frame_count: float;
    padding0: float;
    padding1: float;
    padding2: float;
}

compile_shader :: (source: string, entry_point: string, shader_model: string) -> string, HRESULT
{
    flags := D3DCOMPILE.ENABLE_STRICTNESS;

    #if DEBUG
    {
        flags |= .DEBUG;
        flags |= .SKIP_OPTIMIZATION;
    }

    bytecode, errors, hr := D3DCompile(source, "source", .[], null, entry_point, shader_model, xx flags, 0);
    defer free(errors);

    if FAILED(hr)
    {
        free(bytecode);
        if errors  print("Shader compilation error: %\n", errors, to_standard_error=true);
        return "", hr;
    }

    return bytecode, hr;
}

init_d3d :: () -> success: bool, error_message: string
{
    hr: HRESULT;

    flags: D3D11_CREATE_DEVICE_FLAG;
    flags |= .DEBUG;

    driver_types   := D3D_DRIVER_TYPE.[.HARDWARE, .WARP, .REFERENCE];
    feature_levels := D3D_FEATURE_LEVEL.[._11_1, ._11_0, ._10_1, ._10_0];

    base_device: *ID3D11Device;
    base_device_context: *ID3D11DeviceContext;
 
    for 0..driver_types.count-1 
    {
        d3d.driver_type = driver_types[it]; 
        hr = D3D11CreateDevice(null, d3d.driver_type, null, flags, feature_levels.data, feature_levels.count, D3D11_SDK_VERSION, *d3d.device, *d3d.feature_level, *d3d.device_context);
 
        if hr == E_INVALIDARG 
        {
            // DirectX 11.0 platforms will not recognize D3D_FEATURE_LEVEL_11_1 so we need to retry without it.
            hr = D3D11CreateDevice(null, d3d.driver_type, null, flags, feature_levels.data + 1, feature_levels.count - 1, D3D11_SDK_VERSION, *d3d.device, *d3d.feature_level, *d3d.device_context);
        }
 
        if SUCCEEDED(hr)  break;
    } 

    dxgi_factory: *IDXGIFactory2;
    {
        dxgi_device: *IDXGIDevice;
        dxgi_adapter: *IDXGIAdapter;

        hr = IUnknown_QueryInterface(d3d.device, *uid(IDXGIDevice1_UUID), xx *dxgi_device);
        if FAILED(hr)  return false, "Failed to query IDXGIDevice1 interface";

        hr = IDXGIDevice_GetAdapter(dxgi_device, xx *dxgi_adapter);
        if FAILED(hr)  return false, "Failed to get device adapater";

        hr = IDXGIObject_GetParent(dxgi_adapter, *uid(IDXGIFactory2_UUID), xx *dxgi_factory);
        if FAILED(hr)  return false, "Failed to get adapter parent factory";

        IUnknown_Release(dxgi_adapter);
        IUnknown_Release(dxgi_device);
    }

    rect: RECT;
    GetClientRect(hwnd, *rect);

    w: u32 = xx (rect.right - rect.left);
    h: u32 = xx (rect.bottom - rect.top);

    {
        sd: DXGI_SWAP_CHAIN_DESC1;
        sd.Width              = w;
        sd.Height             = h;
        sd.Format             = .R8G8B8A8_UNORM;
        sd.SampleDesc.Count   = 1;
        sd.SampleDesc.Quality = 0;
        sd.BufferUsage        = .RENDER_TARGET_OUTPUT;
        sd.BufferCount        = 2;
        sd.Scaling            = .NONE;
        sd.SwapEffect         = .FLIP_SEQUENTIAL;
        sd.AlphaMode          = .UNSPECIFIED;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(dxgi_factory, d3d.device, hwnd, *sd, null, null, *d3d.swap_chain);
        if FAILED(hr)  return false, "Failed to create swap chain";
    }

    {
        success, message := create_textures(w, h);
        if !success  return false, message;
    }

    {
        d3d.viewport.Width  = xx w;
        d3d.viewport.Height = xx h;
        d3d.viewport.MinDepth = 0.0;
        d3d.viewport.MaxDepth = 1.0;
        d3d.viewport.TopLeftX = 0.0;
        d3d.viewport.TopLeftY = 0.0;
        ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.viewport);
    }

    {
        desc: D3D11_SAMPLER_DESC;
        desc.Filter         = .MIN_MAG_MIP_POINT;
        desc.AddressU       = .CLAMP;
        desc.AddressV       = .CLAMP;
        desc.AddressW       = .CLAMP;
        desc.MaxAnisotropy  = 1;
        desc.ComparisonFunc = .ALWAYS;
        hr = ID3D11Device_CreateSamplerState(d3d.device, *desc, *d3d.nearest_neighbour_sampler);
        if FAILED(hr)  return false, "Failed to create sampler state";
    }

    shader_text := read_entire_file("shaders/shaders.hlsl");

    {
        vs: string;
        vs, hr = compile_shader(shader_text, "fullscreen_vs", "vs_4_0");
        defer free(vs);
        if FAILED(hr)  return false, "Failed to compile vertex shader";

        hr = ID3D11Device_CreateVertexShader(d3d.device, vs.data, xx vs.count, null, *d3d.fullscreen_vs);
        if FAILED(hr)  return false, "Failed to create vertex shader";
    }

    {
        ps: string;
        ps, hr = compile_shader(shader_text, "resolve_accumulation_buffer_ps", "ps_4_0");
        defer free(ps);
        if FAILED(hr)  return false, "Failed to compile pixel shader";

        hr = ID3D11Device_CreatePixelShader(d3d.device, ps.data, xx ps.count, null, *d3d.resolve_accumulation_buffer_ps);
        if FAILED(hr)  return false, "Failed to create pixel shader";
    }

    {
        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth      = size_of(Resolve_Accumulation_Buffer_PS_Parameters);
        desc.Usage          = .DYNAMIC;
        desc.BindFlags      = .CONSTANT_BUFFER;
        desc.CPUAccessFlags = .WRITE;

        data: Resolve_Accumulation_Buffer_PS_Parameters;
        init_data: D3D11_SUBRESOURCE_DATA;
        init_data.pSysMem = *data;

        hr = ID3D11Device_CreateBuffer(d3d.device, *desc, *init_data, *d3d.resolve_accumulation_buffer_cb);
        if FAILED(hr)  return false, "Failed to create constant buffer";
    }

    return true, "";
}

release_textures :: ()
{
    checked_release(xx *d3d.accumulation_buffer);
    checked_release(xx *d3d.accumulation_buffer_srv);
    checked_release(xx *d3d.target_texture);
    checked_release(xx *d3d.target_texture_srv);
    checked_release(xx *d3d.target_texture_rtv);
    checked_release(xx *d3d.back_buffer);
    checked_release(xx *d3d.back_buffer_rtv);
}

create_textures :: (w: u32, h: u32) -> bool, string
{
    release_textures();

    hr: HRESULT;

    d3d.viewport.Width  = xx w;
    d3d.viewport.Height = xx h;
    d3d.viewport.MinDepth = 0.0;
    d3d.viewport.MaxDepth = 1.0;
    d3d.viewport.TopLeftX = 0.0;
    d3d.viewport.TopLeftY = 0.0;

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = w;
        tex_desc.Height             = h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R32G32B32_FLOAT;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .DYNAMIC;
        tex_desc.BindFlags          = .SHADER_RESOURCE;
        tex_desc.CPUAccessFlags     = .WRITE;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, null, *d3d.accumulation_buffer);
        if FAILED(hr)  return false, "Failed to create accumulation buffer";

        hr = ID3D11Device_CreateShaderResourceView(d3d.device, d3d.accumulation_buffer, null, *d3d.accumulation_buffer_srv);
        if FAILED(hr)  return false, "Failed to create target texture srv";
    }

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = w;
        tex_desc.Height             = h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R8G8B8A8_UNORM_SRGB;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .DEFAULT;
        tex_desc.BindFlags          = D3D11_BIND_FLAG.RENDER_TARGET|.SHADER_RESOURCE;
        tex_desc.CPUAccessFlags     = .WRITE;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, null, *d3d.target_texture);
        if FAILED(hr)  return false, "Failed to create target texture";

        hr = ID3D11Device_CreateShaderResourceView(d3d.device, d3d.target_texture, null, *d3d.target_texture_srv);
        if FAILED(hr)  return false, "Failed to create target texture srv";

        hr = ID3D11Device_CreateRenderTargetView(d3d.device, d3d.target_texture, null, *d3d.target_texture_rtv);
        if FAILED(hr)  return false, "Failed to create target texture rtv";
    }

    hr = IDXGISwapChain_GetBuffer(d3d.swap_chain, 0, *uid(ID3D11Texture2D_UUID), xx *d3d.back_buffer);
    if FAILED(hr)  return false, "Failed to get backbuffer";

    hr = ID3D11Device_CreateRenderTargetView(d3d.device, d3d.back_buffer, null, *d3d.back_buffer_rtv);
    if FAILED(hr)  return false, "Failed to create backbuffer rtv";

    return true, "";
}

maybe_resize_textures :: (w_: int, h_: int) -> bool
{
    w: u32 = xx w_;
    h: u32 = xx h_;

    hr: HRESULT;

    if w != d3d.display_w ||
       h != d3d.display_h
    {
        release_textures();

        d3d.display_w = w;
        d3d.display_h = h;

        if w && h
        {
            hr = IDXGISwapChain_ResizeBuffers(d3d.swap_chain, 2, w, h, .R8G8B8A8_UNORM, 0);
            if always(SUCCEEDED(hr))
            {
                success, message := create_textures(w, h);
                if !success
                {
                    print("What the heck: %\n", message, to_standard_error=true);
                }
            }
        }

        return true;
    }

    return false;
}

resolve_accumulation_buffer :: (acc: *Accumulation_Buffer)
{
    {
        mapped: D3D11_MAPPED_SUBRESOURCE;
        hr := ID3D11DeviceContext_Map(d3d.device_context, d3d.resolve_accumulation_buffer_cb, 0, .WRITE_DISCARD, 0, *mapped);

        if always(SUCCEEDED(hr))
        {
            parameters := cast(*Resolve_Accumulation_Buffer_PS_Parameters) mapped.pData;
            parameters.frame_count = cast(float) acc.frame_count;

            ID3D11DeviceContext_Unmap(d3d.device_context, d3d.resolve_accumulation_buffer_cb, 0);
        }
    }

    {
        mapped: D3D11_MAPPED_SUBRESOURCE;

        hr := ID3D11DeviceContext_Map(d3d.device_context, d3d.accumulation_buffer, 0, .WRITE_DISCARD, 0, *mapped);
        if always(SUCCEEDED(hr))
        {
            dst := mapped.pData;

            if mapped.RowPitch == acc.stride
            {
                memcpy(dst, acc.data, size_of(Vector3)*acc.w*acc.h);
            }
            else
            {
                for y: 0..acc.h-1
                {
                    memcpy(dst, acc.data + y*acc.stride, acc.stride);
                    dst += mapped.RowPitch;
                }
            }

            ID3D11DeviceContext_Unmap(d3d.device_context, d3d.accumulation_buffer, 0);
        }
    }

    ID3D11DeviceContext_OMSetRenderTargets(d3d.device_context, 1, *d3d.back_buffer_rtv, null);
    ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(d3d.device_context, D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(d3d.device_context, d3d.fullscreen_vs, null, 0);
    ID3D11DeviceContext_PSSetShader(d3d.device_context, d3d.resolve_accumulation_buffer_ps, null, 0);
    ID3D11DeviceContext_PSSetSamplers(d3d.device_context, 0, 1, *d3d.nearest_neighbour_sampler);
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *d3d.accumulation_buffer_srv);
    ID3D11DeviceContext_PSSetConstantBuffers(d3d.device_context, 0, 1, *d3d.resolve_accumulation_buffer_cb);
    ID3D11DeviceContext_Draw(d3d.device_context, 3, 0);
}

present :: ()
{
    // ID3D11DeviceContext_CopyResource(d3d.device_context, d3d.back_buffer, d3d.target_texture);

    hr := IDXGISwapChain_Present(d3d.swap_chain, 1, 0);
    if hr == DXGI_STATUS_OCCLUDED
    {
        // window is not visible, so no vsync is possible,
        // sleep a bit instead.
        Sleep(16);
    }
    else
    {
        assert(SUCCEEDED(hr));
    }
}

checked_release :: (ptr: **IUnknown)
{
    if <<ptr
    {
        IUnknown_Release(<<ptr);
        <<ptr = null;
    }
}

//
//
//

#import "File";
#import "Thread";
#import "System";
#import "Windows";
#import "Windows_Utf8";
#import "d3d11"()(INCLUDE_DEBUG_BINDINGS = true);
#import "d3d_compiler";
#import "dxgi";
