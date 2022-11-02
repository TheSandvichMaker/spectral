init_d3d :: (hwnd: HWND, render_w: u32, render_h: u32) -> success: bool, error_message: string
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
        success, message := create_textures(w, h, render_w, render_h);
        if !success  return false, message;
    }

    {
        desc: D3D11_SAMPLER_DESC;
        desc.Filter         = .MIN_MAG_MIP_POINT;
        desc.AddressU       = .CLAMP;
        desc.AddressV       = .CLAMP;
        desc.AddressW       = .CLAMP;
        desc.MaxAnisotropy  = 1;
        desc.ComparisonFunc = .ALWAYS;
        hr = ID3D11Device_CreateSamplerState(d3d.device, *desc, *d3d.point_sampler);
        if FAILED(hr)  return false, "Failed to create sampler state";
    }

    {
        desc: D3D11_SAMPLER_DESC;
        desc.Filter         = .MIN_MAG_MIP_LINEAR;
        desc.AddressU       = .CLAMP;
        desc.AddressV       = .CLAMP;
        desc.AddressW       = .CLAMP;
        desc.MaxAnisotropy  = 1;
        desc.ComparisonFunc = .ALWAYS;
        hr = ID3D11Device_CreateSamplerState(d3d.device, *desc, *d3d.linear_sampler);
        if FAILED(hr)  return false, "Failed to create sampler state";
    }

    shader_text := read_entire_file("shaders/accumulation_buffer.hlsl");
    defer free(shader_text);

    {
        vs: string;
        vs, hr = compile_shader(shader_text, "fullscreen_vs", "vs_5_0");
        defer free(vs);
        if FAILED(hr)  return false, "Failed to compile vertex shader";

        hr = ID3D11Device_CreateVertexShader(d3d.device, vs.data, xx vs.count, null, *d3d.fullscreen_vs);
        if FAILED(hr)  return false, "Failed to create vertex shader";
    }

    {
        ps: string;
        ps, hr = compile_shader(shader_text, "resolve_accumulation_buffer_ps", "ps_5_0");
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

    immediate_shaders := read_entire_file("shaders/immediate.hlsl");
    defer free(immediate_shaders);

    {
        vs: string;
        vs, hr = compile_shader(immediate_shaders, "immediate_vs", "vs_4_0");
        defer free(vs);
        if FAILED(hr)  return false, "Failed to compile vertex shader";

        hr = ID3D11Device_CreateVertexShader(d3d.device, vs.data, xx vs.count, null, *d3d.immediate_vs);
        if FAILED(hr)  return false, "Failed to create vertex shader";

        layout: [3] D3D11_INPUT_ELEMENT_DESC;

        layout[0].SemanticName         = "POSITION";
        layout[0].SemanticIndex        = 0;
        layout[0].Format               = .R32G32B32_FLOAT;
        layout[0].InputSlot            = 0;
        layout[0].AlignedByteOffset    = 0;
        layout[0].InputSlotClass       = .VERTEX_DATA;
        layout[0].InstanceDataStepRate = 0;

        layout[1].SemanticName         = "COLOR";
        layout[1].SemanticIndex        = 0;
        layout[1].Format               = .R32_UINT;
        layout[1].InputSlot            = 0;
        layout[1].AlignedByteOffset    = 12;
        layout[1].InputSlotClass       = .VERTEX_DATA;
        layout[1].InstanceDataStepRate = 0;

        layout[2].SemanticName         = "TEXCOORD";
        layout[2].SemanticIndex        = 0;
        layout[2].Format               = .R32G32_FLOAT;
        layout[2].InputSlot            = 0;
        layout[2].AlignedByteOffset    = 16;
        layout[2].InputSlotClass       = .VERTEX_DATA;
        layout[2].InstanceDataStepRate = 0;

        hr = ID3D11Device_CreateInputLayout(d3d.device, layout.data, cast(u32) layout.count, vs.data, cast(u64) vs.count, *d3d.immediate_layout);
        if FAILED(hr)  return false, "Failed to create input layout";
    }

    {
        ps: string;
        ps, hr = compile_shader(immediate_shaders, "immediate_ps", "ps_5_0");
        defer free(ps);
        if FAILED(hr)  return false, "Failed to compile pixel shader";

        hr = ID3D11Device_CreatePixelShader(d3d.device, ps.data, xx ps.count, null, *d3d.immediate_ps);
        if FAILED(hr)  return false, "Failed to create pixel shader";
    }

    {
        ps: string;
        ps, hr = compile_shader(immediate_shaders, "immediate_write_depth_ps", "ps_5_0");
        defer free(ps);
        if FAILED(hr)  return false, "Failed to compile pixel shader";

        hr = ID3D11Device_CreatePixelShader(d3d.device, ps.data, xx ps.count, null, *d3d.immediate_write_depth_ps);
        if FAILED(hr)  return false, "Failed to create pixel shader";
    }

    {
        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth      = size_of(Immediate_Vs_Cb);
        desc.Usage          = .DYNAMIC;
        desc.BindFlags      = .CONSTANT_BUFFER;
        desc.CPUAccessFlags = .WRITE;

        data: Immediate_Vs_Cb;
        data.matrix = Matrix4_Identity;
        init_data: D3D11_SUBRESOURCE_DATA;
        init_data.pSysMem = *data;

        hr = ID3D11Device_CreateBuffer(d3d.device, *desc, *init_data, *d3d.immediate_vs_cb);
        if FAILED(hr)  return false, "Failed to create constant buffer";
    }

    {
        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth      = size_of(u16)*MAX_IMMEDIATE_INDICES;
        desc.Usage          = .DYNAMIC;
        desc.BindFlags      = .INDEX_BUFFER;
        desc.CPUAccessFlags = .WRITE;

        hr = ID3D11Device_CreateBuffer(d3d.device, *desc, null, *d3d.immediate_indices);
        if FAILED(hr)  return false, "Failed to create immediate index buffer";
    }

    {
        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth      = size_of(Immediate_Vertex)*MAX_IMMEDIATE_VERTICES;
        desc.Usage          = .DYNAMIC;
        desc.BindFlags      = .VERTEX_BUFFER;
        desc.CPUAccessFlags = .WRITE;

        hr = ID3D11Device_CreateBuffer(d3d.device, *desc, null, *d3d.immediate_vertices);
        if FAILED(hr)  return false, "Failed to create immediate vertex buffer";
    }

    {
        desc: D3D11_BLEND_DESC;
        desc.RenderTarget[0].BlendEnable           = .TRUE;
        desc.RenderTarget[0].SrcBlend              = .SRC_ALPHA;
        desc.RenderTarget[0].DestBlend             = .INV_SRC_ALPHA;
        desc.RenderTarget[0].BlendOp               = .ADD;
        desc.RenderTarget[0].SrcBlendAlpha         = .ONE;
        desc.RenderTarget[0].DestBlendAlpha        = .ZERO;
        desc.RenderTarget[0].BlendOpAlpha          = .ADD;
        desc.RenderTarget[0].RenderTargetWriteMask = xx D3D11_COLOR_WRITE_ENABLE.ALL;

        hr = ID3D11Device_CreateBlendState(d3d.device, *desc, *d3d.blend_premultiplied);
        if FAILED(hr)  return false, "Failed to create immediate blend state";
    }

    {
        desc: D3D11_BLEND_DESC;
        desc.RenderTarget[0].BlendEnable           = .TRUE;
        desc.RenderTarget[0].SrcBlend              = .ONE;
        desc.RenderTarget[0].DestBlend             = .ZERO;
        desc.RenderTarget[0].BlendOp               = .ADD;
        desc.RenderTarget[0].SrcBlendAlpha         = .ONE;
        desc.RenderTarget[0].DestBlendAlpha        = .ZERO;
        desc.RenderTarget[0].BlendOpAlpha          = .ADD;
        desc.RenderTarget[0].RenderTargetWriteMask = xx D3D11_COLOR_WRITE_ENABLE.ALL;

        hr = ID3D11Device_CreateBlendState(d3d.device, *desc, *d3d.blend_disabled);
        if FAILED(hr)  return false, "Failed to create immediate blend state";
    }

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = 1;
        tex_desc.Height             = 1;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R32G32B32A32_FLOAT;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .IMMUTABLE;
        tex_desc.BindFlags          = .SHADER_RESOURCE;

        white := make_vector4(1, 1, 1, 1);
        init_data: D3D11_SUBRESOURCE_DATA;
        init_data.pSysMem = *white;
        init_data.SysMemPitch = 1;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, *init_data, *d3d.white_texture);
        if FAILED(hr)  return false, "Failed to create white texture";

        hr = ID3D11Device_CreateShaderResourceView(d3d.device, d3d.white_texture, null, *d3d.white_texture_srv);
        if FAILED(hr)  return false, "Failed to create white texture srv";
    }

    {
        desc: D3D11_RASTERIZER_DESC;
        desc.FillMode              = .SOLID;
        desc.CullMode              = .BACK;
        desc.FrontCounterClockwise = .TRUE;
        desc.DepthClipEnable       = .TRUE;

        hr = ID3D11Device_CreateRasterizerState(d3d.device, *desc, *d3d.default_rs);
        if FAILED(hr)  return false, "Failed to create rasterizer state";

        ID3D11DeviceContext_RSSetState(d3d.device_context, d3d.default_rs);
    }

    {
        desc: D3D11_RASTERIZER_DESC;
        desc.FillMode              = .WIREFRAME;
        desc.CullMode              = .BACK;
        desc.FrontCounterClockwise = .TRUE;
        desc.DepthClipEnable       = .TRUE;

        hr = ID3D11Device_CreateRasterizerState(d3d.device, *desc, *d3d.wireframe_rs);
        if FAILED(hr)  return false, "Failed to create rasterizer state";
    }

    return true, "";
}

maybe_resize_textures :: (window_w: u32, window_h: u32, render_w: u32, render_h: u32) -> bool
{
    hr: HRESULT;

    if render_w != d3d.render_w ||
       render_h != d3d.render_h ||
       window_w != d3d.window_w ||
       window_h != d3d.window_h
    {
        release_textures();

        d3d.render_w = render_w;
        d3d.render_h = render_h;
        d3d.window_w = window_w;
        d3d.window_h = window_h;

        if window_w && window_h
        {
            hr = IDXGISwapChain_ResizeBuffers(d3d.swap_chain, 2, window_w, window_h, .R8G8B8A8_UNORM, 0);
            if always(SUCCEEDED(hr))
            {
                success, message := create_textures(window_w, window_h, render_w, render_h);
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
    cb: Resolve_Accumulation_Buffer_PS_Parameters;
    cb.frame_count = cast(float)acc.frame_count;

    update_buffer(d3d.resolve_accumulation_buffer_cb, *cb);

    {
        // TODO(daniel): It would be nice to make the accumulation buffer match the pitch of the texture
        // so we can always just memcpy it.

        mapped: D3D11_MAPPED_SUBRESOURCE;

        hr := ID3D11DeviceContext_Map(d3d.device_context, d3d.accumulation_buffer, 0, .WRITE_DISCARD, 0, *mapped);
        if always(SUCCEEDED(hr))
        {
            dst := mapped.pData;

            if mapped.RowPitch == acc.stride
            {
                memcpy(dst, acc.data, size_of(acc.TYPE)*acc.w*acc.h);
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

    ID3D11DeviceContext_OMSetRenderTargets(d3d.device_context, 1, *d3d.target_texture_rtv, null);
    ID3D11DeviceContext_OMSetDepthStencilState(d3d.device_context, null, 1);
    ID3D11DeviceContext_OMSetBlendState(d3d.device_context, d3d.blend_disabled, null, 0xffffffff);


    ID3D11DeviceContext_RSSetState(d3d.device_context, d3d.default_rs);
    ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.render_viewport);

    ID3D11DeviceContext_IASetPrimitiveTopology(d3d.device_context, D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST);

    ID3D11DeviceContext_VSSetShader(d3d.device_context, d3d.fullscreen_vs, null, 0);

    ID3D11DeviceContext_PSSetShader(d3d.device_context, d3d.resolve_accumulation_buffer_ps, null, 0);
    ID3D11DeviceContext_PSSetSamplers(d3d.device_context, 0, 1, *d3d.linear_sampler);
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *d3d.accumulation_buffer_srv);
    ID3D11DeviceContext_PSSetConstantBuffers(d3d.device_context, 0, 1, *d3d.resolve_accumulation_buffer_cb);

    ID3D11DeviceContext_Draw(d3d.device_context, 3, 0);

    null_srv: *ID3D11ShaderResourceView;
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *null_srv);
}

present :: ()
{
    // if immediate.icount > 0
    // {
    //     immediate_flush();
    // }

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

    color := make_vector4(0, 0, 0, 1);
    ID3D11DeviceContext_ClearRenderTargetView(d3d.device_context, d3d.back_buffer_rtv, *color.component);
    ID3D11DeviceContext_ClearDepthStencilView(d3d.device_context, d3d.depth_stencil_view, xx D3D11_CLEAR_FLAG.DEPTH, 0.0, 0);
}

Texture :: struct
{
    using plat: Texture_Platform;
}

Texture_Platform :: struct
{
    tex: *ID3D11Texture2D;
    srv: *ID3D11ShaderResourceView;
    rtv: *ID3D11RenderTargetView;
}

Map_Access :: enum
{
    Read;
    Write;
}

map :: (tex: Texture, access: Map_Access) -> Bitmap
{
    d3d_access: D3D11_MAP;
    if access ==
    {
        case .Read;   d3d_access = .READ;
        case .Write;  d3d_access = .WRITE_DISCARD;
    }

    bitmap: Bitmap;

    mapped: D3D11_MAPPED_SUBRESOURCE;

    hr := ID3D11DeviceContext_Map(d3d.device_context, tex.tex, 0, d3d_access, 0, *mapped);
    if always(SUCCEEDED(hr))
    {
        desc: D3D11_TEXTURE2D_DESC;
        ID3D11Texture2D_GetDesc(tex.tex, *desc);

        bitmap.w          = xx desc.Width;
        bitmap.h          = xx desc.Height;
        bitmap.c          = 4; // TODO: Actually look at the texture's format!!
        bitmap.stride     = xx mapped.RowPitch;
        bitmap.data.data  = xx mapped.pData;
        bitmap.data.count = bitmap.stride*bitmap.h;
    }

    return bitmap;
}

unmap :: (tex: Texture)
{
    ID3D11DeviceContext_Unmap(d3d.device_context, tex.tex, 0);
}

create_texture :: (bitmap: *Bitmap) -> Texture
{
    format: DXGI_FORMAT;

    tex_desc: D3D11_TEXTURE2D_DESC;
    tex_desc.Width              = xx bitmap.w;
    tex_desc.Height             = xx bitmap.h;
    tex_desc.MipLevels          = 1;
    tex_desc.ArraySize          = 1;
    tex_desc.Format             = .R8G8B8A8_UNORM_SRGB;
    tex_desc.SampleDesc.Count   = 1;
    tex_desc.SampleDesc.Quality = 0;
    tex_desc.Usage              = .IMMUTABLE;
    tex_desc.BindFlags          = .SHADER_RESOURCE;

    init_data: D3D11_SUBRESOURCE_DATA;
    init_data.pSysMem = bitmap.data.data;
    init_data.SysMemPitch = xx (bitmap.w*bitmap.c);

    result: Texture;

    hr := ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, *init_data, *result.tex);
    if FAILED(hr)  return .{};

    hr = ID3D11Device_CreateShaderResourceView(d3d.device, result.tex, null, *result.srv);
    if FAILED(hr)  return .{};

    return result;
}

get_scene_texture :: () -> Texture
{
    tex: Texture;
    tex.tex = d3d.target_texture;
    tex.srv = d3d.target_texture_srv;
    tex.rtv = d3d.target_texture_rtv;
    return tex;
}

map_screenshot_texture :: () -> Bitmap
{
    ID3D11DeviceContext_CopyResource(d3d.device_context, d3d.target_copy_back_texture, d3d.target_texture);

    texture: Texture;
    texture.tex = d3d.target_copy_back_texture;

    result := map(texture, .Read);
    return result;
}

unmap_screenshot_texture :: ()
{
    ID3D11DeviceContext_Unmap(d3d.device_context, d3d.target_copy_back_texture, 0);
}

Immediate_Vertex :: struct
{
    position: Vector3;
    color: u32;
    texcoord: Vector2;
}

Immediate_Vs_Cb :: struct
{
    matrix: Matrix4;
}

Sampler :: enum u8
{
    Point;
    Linear;
}

Fill_Mode :: enum u8
{
    Solid;
    Wireframe;
}

Immediate_Flags :: enum_flags
{
    BlendDisable;
    DepthTestEnable;
    DepthWriteEnable;
    WriteAlphaAsDepth;
}

Immediate_Draw_Call :: struct
{
    texture   : Texture;
    transform : Matrix4;
    flags     : Immediate_Flags;
    sampler   : Sampler;
    fill_mode : Fill_Mode;

    icount  : u32;
    ioffset : u32;
}

Immediate_Draw_List :: struct
{
    draw_call_count: u32;
    draw_calls: [MAX_IMMEDIATE_DRAW_CALLS] Immediate_Draw_Call;

    icount: u32;
    vcount: u32;

    ibuffer: [MAX_IMMEDIATE_INDICES ] u16;
    vbuffer: [MAX_IMMEDIATE_VERTICES] Immediate_Vertex;
}

current_draw_call :: (list: *Immediate_Draw_List) -> *Immediate_Draw_Call
{
    if list.draw_call_count > 0
    {
        return *list.draw_calls[list.draw_call_count - 1];
    }
    else
    {
        return null;
    }
}

texture_white :: () -> Texture
{
    white_texture: Texture;
    white_texture.tex = d3d.white_texture;
    white_texture.srv = d3d.white_texture_srv;
    return white_texture;
}

immediate_draw :: (list: *Immediate_Draw_List, texture: Texture = .{}, sampler: Sampler = .Linear, flags: Immediate_Flags = 0) -> *Immediate_Draw_Call
{
    draw := *list.draw_calls[list.draw_call_count];
    list.draw_call_count += 1;

    Initialize(draw);
    draw.texture   = ifx texture.tex  texture else texture_white();
    draw.sampler   = sampler;
    draw.transform = normalized_coordinates();
    draw.flags     = flags;
    draw.ioffset   = cast(u32)list.icount;

    return draw;
}

immediate_draw_list :: () -> *Immediate_Draw_List
{
    return *immediate.draw_list;
}

immediate_index :: (list: *Immediate_Draw_List, index: u16)
{
    call := current_draw_call(list);

    list.ibuffer[list.icount] = index;
    list.icount += 1;
    call.icount += 1;
}

immediate_indices :: (list: *Immediate_Draw_List, indices: ..u16)
{
    for indices
    {
        immediate_index(list, it);
    }
}

immediate_vertex :: (list: *Immediate_Draw_List, vertex: Immediate_Vertex) -> u16
{
    index := cast(u16)list.vcount;
    list.vbuffer[index] = vertex;
    list.vcount += 1;
    return index;
}

immediate_vertex :: (list: *Immediate_Draw_List, position: Vector3, color: u32, texcoord: Vector2 = .{0, 0}) -> u16
{
    vertex: Immediate_Vertex = ---;
    vertex.position = position;
    vertex.color    = color;
    vertex.texcoord = texcoord;
    return immediate_vertex(list, vertex);
}

immediate_quad :: (list: *Immediate_Draw_List, i0: u16, i1: u16, i2: u16, i3: u16)
{
    immediate_index(list, i0);
    immediate_index(list, i1);
    immediate_index(list, i2);

    immediate_index(list, i0);
    immediate_index(list, i2);
    immediate_index(list, i3);
}

immediate_quad :: (list: *Immediate_Draw_List,
                   v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, 
                   color := Vector4.{1, 1, 1, 1}, 
                   uv0 := Vector2.{0, 0}, uv1 := Vector2.{1, 0}, uv2 := Vector2.{1, 1}, uv3 := Vector2.{0, 1})
{
    icolor := pack_color(color);

    v00 := immediate_vertex(list, v0, icolor, uv0);
    v10 := immediate_vertex(list, v1, icolor, uv1);
    v11 := immediate_vertex(list, v2, icolor, uv2);
    v01 := immediate_vertex(list, v3, icolor, uv3);

    immediate_index(list, v00);
    immediate_index(list, v10);
    immediate_index(list, v11);

    immediate_index(list, v00);
    immediate_index(list, v11);
    immediate_index(list, v01);
}

immediate_rect :: (list: *Immediate_Draw_List, 
                   x0: float, y0: float, x1: float, y1: float, 
                   color: Vector4 = .{1, 1, 1, 1}, 
                   u0 := 0.0, v0 := 0.0, u1 := 1.0, v1 := 1.0)
{
    immediate_quad(
        list,
        make_vector3(x0, y0, 0.5),
        make_vector3(x1, y0, 0.5),
        make_vector3(x1, y1, 0.5),
        make_vector3(x0, y1, 0.5),
        color,
        make_vector2(u0, v0),
        make_vector2(u1, v0),
        make_vector2(u1, v1),
        make_vector2(u0, v1),
    );
}

immediate_cube :: (list: *Immediate_Draw_List, transform: Matrix4, color_: Vector4 = .{1, 1, 1, 1})
{
    color := pack_color(color_);

    v000 := immediate_vertex(list, (transform*make_vector4(-1, -1, -1, 1)).xyz, color, make_vector2(0, 0));
    v100 := immediate_vertex(list, (transform*make_vector4( 1, -1, -1, 1)).xyz, color, make_vector2(0, 0));
    v010 := immediate_vertex(list, (transform*make_vector4(-1,  1, -1, 1)).xyz, color, make_vector2(0, 0));
    v110 := immediate_vertex(list, (transform*make_vector4( 1,  1, -1, 1)).xyz, color, make_vector2(0, 0));
    v001 := immediate_vertex(list, (transform*make_vector4(-1, -1,  1, 1)).xyz, color, make_vector2(0, 0));
    v101 := immediate_vertex(list, (transform*make_vector4( 1, -1,  1, 1)).xyz, color, make_vector2(0, 0));
    v011 := immediate_vertex(list, (transform*make_vector4(-1,  1,  1, 1)).xyz, color, make_vector2(0, 0));
    v111 := immediate_vertex(list, (transform*make_vector4( 1,  1,  1, 1)).xyz, color, make_vector2(0, 0));

    immediate_indices(list, v000, v101, v001);
    immediate_indices(list, v000, v100, v101);

    immediate_indices(list, v010, v011, v111);
    immediate_indices(list, v010, v111, v110);

    immediate_indices(list, v000, v110, v100);
    immediate_indices(list, v000, v010, v110);

    immediate_indices(list, v001, v101, v111);
    immediate_indices(list, v001, v111, v011);

    immediate_indices(list, v000, v001, v011);
    immediate_indices(list, v000, v011, v010);

    immediate_indices(list, v100, v111, v101);
    immediate_indices(list, v100, v110, v111);
}

immediate_sphere :: (list: *Immediate_Draw_List, p: Vector3, r: float, color_: Vector4 = .{1, 1, 1, 1}, slices := 16, stacks := 16)
{
    // source: https://www.danielsieger.com/blog/2021/03/27/generating-spheres.html

    color := pack_color(color_);

    vertices: [..] u16;
    vertices.allocator = temp;

    // top vertex
    v0 := immediate_vertex(list, p + make_vector3(0, r, 0), color);
    array_add(*vertices, v0);

    // vertices per stack/slice
    for i: 0..stacks-2
    {
        phi := PI*cast(float)(i + 1) / cast(float)stacks;
        for j: 0..slices-1
        {
            theta := 2*PI*cast(float)j / cast(float)slices;
            x := sin(phi)*cos(theta);
            y := cos(phi);
            z := sin(phi)*sin(theta);
            array_add(*vertices, immediate_vertex(list, p + r*make_vector3(x, y, z), color));
        }
    }

    // bottom vertex
    v1 := immediate_vertex(list, p - make_vector3(0, r, 0), color);
    array_add(*vertices, v1);

    // top/bottom triangles
    for i: 0..slices-1
    {
        i0 :=  i + 1;
        i1 := (i + 1) % slices + 1;
        immediate_indices(list, v0, vertices[i1], vertices[i0]);
        i0 =  i               + slices*(stacks - 2) + 1;
        i1 = (i + 1) % slices + slices*(stacks - 2) + 1;
        immediate_indices(list, v1, vertices[i0], vertices[i1]);
    }

    // add quads
    for j: 0..stacks-3
    {
        j0 :=  j     *slices + 1;
        j1 := (j + 1)*slices + 1;
        for i: 0..slices-1
        {
            i0 := j0 + i;
            i1 := j0 + (i + 1) % slices;
            i2 := j1 + (i + 1) % slices;
            i3 := j1 + i;
            immediate_quad(list, vertices[i0], vertices[i1], vertices[i2], vertices[i3]);
        }
    }
}

pixel_coordinates :: () -> Matrix4
{
    a := 2.0 / d3d.window_w;
    b := 2.0 / d3d.window_h;

    return make_matrix4(
        a, 0, 0,-1,
        0, b, 0,-1,
        0, 0, 1, 0,
        0, 0, 0, 1,
    );
}

normalized_coordinates :: () -> Matrix4
{
    a := 2.0;
    b := 2.0;

    return make_matrix4(
        a, 0, 0,-1,
        0, b, 0,-1,
        0, 0, 1, 0,
        0, 0, 0, 1,
    );
}

to_pixel_coordinates :: (normalized: Vector2) -> Vector2
{
    result: Vector2 = ---;
    result.x = cast(float)d3d.window_w*normalized.x;
    result.y = cast(float)d3d.window_h*normalized.y;
    return result;
}

to_normalized_coordinates :: (pixel: Vector2) -> Vector2
{
    result: Vector2 = ---;
    result.x = pixel.x / cast(float)d3d.window_w;
    result.y = pixel.y / cast(float)d3d.window_h;
    return result;
}

pack_color :: (color_: Vector4) -> u32
{
    color := saturate(color_);
    color.xyz *= color.w;

    result: u32 = 0;
    result |= (cast(u32)(color.x * 255.0));
    result |= (cast(u32)(color.y * 255.0)) << 8;
    result |= (cast(u32)(color.z * 255.0)) << 16;
    result |= (cast(u32)(color.w * 255.0)) << 24;

    return result;
}

immediate_flush :: (list: *Immediate_Draw_List)
{
    if list.draw_call_count == 0  return;

    update_buffer(d3d.immediate_indices, list.ibuffer.data, list.icount);
    update_buffer(d3d.immediate_vertices, list.vbuffer.data, list.vcount);

    ID3D11DeviceContext_OMSetRenderTargets(d3d.device_context, 1, *d3d.back_buffer_rtv, d3d.depth_stencil_view);

    ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.window_viewport);

    ID3D11DeviceContext_IASetPrimitiveTopology(d3d.device_context, D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(d3d.device_context, d3d.immediate_layout);
    ID3D11DeviceContext_IASetIndexBuffer(d3d.device_context, d3d.immediate_indices, .R16_UINT, 0);

    stride: u32 = size_of(Immediate_Vertex);
    offset: u32 = 0;
    ID3D11DeviceContext_IASetVertexBuffers(d3d.device_context, 0, 1, *d3d.immediate_vertices, *stride, *offset);

    ID3D11DeviceContext_VSSetShader(d3d.device_context, d3d.immediate_vs, null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(d3d.device_context, 0, 1, *d3d.immediate_vs_cb);

    for 0..list.draw_call_count-1
    {
        draw_call := *list.draw_calls[it];

        vs_cb: Immediate_Vs_Cb;
        vs_cb.matrix = draw_call.transform;

        update_buffer(d3d.immediate_vs_cb, *vs_cb);

        rasterizer := d3d.default_rs;
        if draw_call.fill_mode == .Wireframe
            rasterizer = d3d.wireframe_rs;
        ID3D11DeviceContext_RSSetState(d3d.device_context, rasterizer);

        blend: *ID3D11BlendState = d3d.blend_premultiplied;
        if draw_call.flags & .BlendDisable  
            blend = null;
        ID3D11DeviceContext_OMSetBlendState(d3d.device_context, blend, null, 0xffffffff);

        ds := d3d.depth_state_none;
        if draw_call.flags & .DepthWriteEnable && draw_call.flags & .DepthTestEnable
            ds = d3d.depth_state_write_test;
        else if draw_call.flags & .DepthWriteEnable
            ds = d3d.depth_state_write;
        else if draw_call.flags & .DepthTestEnable
            ds = d3d.depth_state_test;
        ID3D11DeviceContext_OMSetDepthStencilState(d3d.device_context, ds, 1);

        ps := d3d.immediate_ps;
        if draw_call.flags & .WriteAlphaAsDepth  
            ps = d3d.immediate_write_depth_ps;
        ID3D11DeviceContext_PSSetShader(d3d.device_context, ps, null, 0);

        ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *draw_call.texture.srv);

        sampler: *ID3D11SamplerState;
        if draw_call.sampler ==
        {
            case .Point;  sampler = d3d.point_sampler;
            case .Linear; sampler = d3d.linear_sampler;
            case; assert(false, "Invalid sampler!");
        }
        ID3D11DeviceContext_PSSetSamplers(d3d.device_context, 0, 1, *sampler);

        ID3D11DeviceContext_DrawIndexed(d3d.device_context, draw_call.icount, draw_call.ioffset, 0);

        null_srv: *ID3D11ShaderResourceView;
        ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *null_srv);
    }

    list.draw_call_count = 0;
    list.icount = 0;
    list.vcount = 0;
}

#scope_file

MAX_IMMEDIATE_DRAW_CALLS :: 1 << 13;
MAX_IMMEDIATE_INDICES    :: 1 << 14;
MAX_IMMEDIATE_VERTICES   :: 1 << 14;

Immediate_State :: struct
{
    draw_list: Immediate_Draw_List;
}

immediate: Immediate_State;

D3D_State :: struct
{
    driver_type   := D3D_DRIVER_TYPE.NULL;
    feature_level := D3D_FEATURE_LEVEL._11_0;

    device                         : *ID3D11Device;
    device_context                 : *ID3D11DeviceContext;
    swap_chain                     : *IDXGISwapChain1;

    default_rs                     : *ID3D11RasterizerState;
    wireframe_rs                   : *ID3D11RasterizerState;

    point_sampler                  : *ID3D11SamplerState;
    linear_sampler                 : *ID3D11SamplerState;

    white_texture                  : *ID3D11Texture2D;
    white_texture_srv              : *ID3D11ShaderResourceView;

    blend_premultiplied            : *ID3D11BlendState;
    blend_disabled                 : *ID3D11BlendState;

    immediate_indices              : *ID3D11Buffer;
    immediate_vertices             : *ID3D11Buffer;
    immediate_layout               : *ID3D11InputLayout;
    immediate_vs_cb                : *ID3D11Buffer;
    immediate_vs                   : *ID3D11VertexShader;
    immediate_ps                   : *ID3D11PixelShader;
    immediate_write_depth_ps       : *ID3D11PixelShader;

    fullscreen_vs                  : *ID3D11VertexShader;
    resolve_accumulation_buffer_cb : *ID3D11Buffer;
    resolve_accumulation_buffer_ps : *ID3D11PixelShader;

    accumulation_buffer            : *ID3D11Texture2D;
    accumulation_buffer_srv        : *ID3D11ShaderResourceView;

    target_texture                 : *ID3D11Texture2D;
    target_texture_srv             : *ID3D11ShaderResourceView;
    target_texture_rtv             : *ID3D11RenderTargetView;

    target_copy_back_texture       : *ID3D11Texture2D;

    back_buffer                    : *ID3D11Texture2D;
    back_buffer_rtv                : *ID3D11RenderTargetView;
    depth_stencil_buffer           : *ID3D11Texture2D;
    depth_state_write_test         : *ID3D11DepthStencilState;
    depth_state_write              : *ID3D11DepthStencilState;
    depth_state_test               : *ID3D11DepthStencilState;
    depth_state_none               : *ID3D11DepthStencilState;
    depth_stencil_view             : *ID3D11DepthStencilView;

    window_viewport                : D3D11_VIEWPORT;
    render_viewport                : D3D11_VIEWPORT;

    window_w: DWORD;
    window_h: DWORD;
    render_w: DWORD;
    render_h: DWORD;
}

d3d: D3D_State;

Resolve_Accumulation_Buffer_PS_Parameters :: struct
{
    frame_count: float;
    padding0: float;
    padding1: float;
    padding2: float;
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
    checked_release(xx *d3d.depth_stencil_buffer);
}

create_textures :: (window_w: u32, window_h: u32, render_w: u32, render_h: u32) -> bool, string
{
    release_textures();

    hr: HRESULT;

    d3d.window_viewport.Width  = xx window_w;
    d3d.window_viewport.Height = xx window_h;
    d3d.window_viewport.MinDepth = 0.0;
    d3d.window_viewport.MaxDepth = 1.0;
    d3d.window_viewport.TopLeftX = 0.0;
    d3d.window_viewport.TopLeftY = 0.0;

    d3d.render_viewport.Width  = xx render_w;
    d3d.render_viewport.Height = xx render_h;
    d3d.render_viewport.MinDepth = 0.0;
    d3d.render_viewport.MaxDepth = 1.0;
    d3d.render_viewport.TopLeftX = 0.0;
    d3d.render_viewport.TopLeftY = 0.0;

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = render_w;
        tex_desc.Height             = render_h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R32G32B32A32_FLOAT;
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
        tex_desc.Width              = render_w;
        tex_desc.Height             = render_h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R8G8B8A8_UNORM;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .DEFAULT;
        tex_desc.BindFlags          = D3D11_BIND_FLAG.RENDER_TARGET|.SHADER_RESOURCE;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, null, *d3d.target_texture);
        if FAILED(hr)  return false, "Failed to create target texture";

        hr = ID3D11Device_CreateShaderResourceView(d3d.device, d3d.target_texture, null, *d3d.target_texture_srv);
        if FAILED(hr)  return false, "Failed to create target texture srv";

        hr = ID3D11Device_CreateRenderTargetView(d3d.device, d3d.target_texture, null, *d3d.target_texture_rtv);
        if FAILED(hr)  return false, "Failed to create target texture rtv";
    }

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = render_w;
        tex_desc.Height             = render_h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R8G8B8A8_UNORM;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .STAGING;
        tex_desc.CPUAccessFlags     = .READ;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, null, *d3d.target_copy_back_texture);
        if FAILED(hr)  return false, "Failed to create target texture";
    }

    {
        tex_desc: D3D11_TEXTURE2D_DESC;
        tex_desc.Width              = window_w;
        tex_desc.Height             = window_h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .D32_FLOAT;
        tex_desc.SampleDesc.Count   = 1;
        tex_desc.SampleDesc.Quality = 0;
        tex_desc.Usage              = .DEFAULT;
        tex_desc.BindFlags          = .DEPTH_STENCIL;

        hr = ID3D11Device_CreateTexture2D(d3d.device, *tex_desc, null, *d3d.depth_stencil_buffer);
        if FAILED(hr)  return false, "Failed to create depth/stencil texture";

        {
            ds_desc: D3D11_DEPTH_STENCIL_DESC;
            ds_desc.DepthEnable    = .TRUE;
            ds_desc.DepthWriteMask = .ALL;
            ds_desc.DepthFunc      = .GREATER_EQUAL;

            hr = ID3D11Device_CreateDepthStencilState(d3d.device, *ds_desc, *d3d.depth_state_write_test);
            if FAILED(hr)  return false, "Failed to create depth/stencil state";
        }

        {
            ds_desc: D3D11_DEPTH_STENCIL_DESC;
            ds_desc.DepthEnable    = .TRUE;
            ds_desc.DepthWriteMask = .ALL;
            ds_desc.DepthFunc      = .ALWAYS;

            hr = ID3D11Device_CreateDepthStencilState(d3d.device, *ds_desc, *d3d.depth_state_write);
            if FAILED(hr)  return false, "Failed to create depth/stencil state";
        }

        {
            ds_desc: D3D11_DEPTH_STENCIL_DESC;
            ds_desc.DepthEnable    = .TRUE;
            ds_desc.DepthWriteMask = .ZERO;
            ds_desc.DepthFunc      = .GREATER_EQUAL;

            hr = ID3D11Device_CreateDepthStencilState(d3d.device, *ds_desc, *d3d.depth_state_test);
            if FAILED(hr)  return false, "Failed to create depth/stencil state";
        }

        {
            ds_desc: D3D11_DEPTH_STENCIL_DESC;
            ds_desc.DepthEnable    = .FALSE;
            ds_desc.DepthWriteMask = .ZERO;

            hr = ID3D11Device_CreateDepthStencilState(d3d.device, *ds_desc, *d3d.depth_state_none);
            if FAILED(hr)  return false, "Failed to create depth/stencil state";
        }

        dsv_desc: D3D11_DEPTH_STENCIL_VIEW_DESC;
        dsv_desc.Format        = .D32_FLOAT;
        dsv_desc.ViewDimension = .TEXTURE2D;

        hr = ID3D11Device_CreateDepthStencilView(d3d.device, d3d.depth_stencil_buffer, *dsv_desc, *d3d.depth_stencil_view);
        if FAILED(hr)  return false, "Failed to create depth/stencil view";
    }

    hr = IDXGISwapChain_GetBuffer(d3d.swap_chain, 0, *uid(ID3D11Texture2D_UUID), xx *d3d.back_buffer);
    if FAILED(hr)  return false, "Failed to get backbuffer";

    hr = ID3D11Device_CreateRenderTargetView(d3d.device, d3d.back_buffer, null, *d3d.back_buffer_rtv);
    if FAILED(hr)  return false, "Failed to create backbuffer rtv";

    return true, "";
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

checked_release :: (ptr: **IUnknown)
{
    if <<ptr
    {
        IUnknown_Release(<<ptr);
        <<ptr = null;
    }
}

update_buffer :: (buffer: *ID3D11Buffer, data: *$T, count: int = 1)
{
    if count <= 0  return;

    mapped: D3D11_MAPPED_SUBRESOURCE;

    hr := ID3D11DeviceContext_Map(d3d.device_context, buffer, 0, .WRITE_DISCARD, 0, *mapped);
    if always(SUCCEEDED(hr))
    {
        assert(size_of(T) <= mapped.DepthPitch);
        memcpy(mapped.pData, data, size_of(T)*count);
        ID3D11DeviceContext_Unmap(d3d.device_context, buffer, 0);
    }
}

#import "d3d11"()(INCLUDE_DEBUG_BINDINGS = true);
#import "d3d_compiler";
#import "dxgi";
