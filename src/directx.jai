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
        hr = ID3D11Device_CreateSamplerState(d3d.device, *desc, *d3d.nearest_neighbour_sampler);
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
        hr = ID3D11Device_CreateSamplerState(d3d.device, *desc, *d3d.bilinear_sampler);
        if FAILED(hr)  return false, "Failed to create sampler state";
    }

    shader_text := read_entire_file("shaders/shaders.hlsl");
    defer free(shader_text);

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
        ps, hr = compile_shader(immediate_shaders, "immediate_ps", "ps_4_0");
        defer free(ps);
        if FAILED(hr)  return false, "Failed to compile pixel shader";

        hr = ID3D11Device_CreatePixelShader(d3d.device, ps.data, xx ps.count, null, *d3d.immediate_ps);
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

        hr = ID3D11Device_CreateBlendState(d3d.device, *desc, *d3d.immediate_blend);
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

    immediate.texture.tex = d3d.white_texture;
    immediate.texture.srv = d3d.white_texture_srv;

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
        tex_desc.Width              = window_w;
        tex_desc.Height             = window_h;
        tex_desc.MipLevels          = 1;
        tex_desc.ArraySize          = 1;
        tex_desc.Format             = .R8G8B8A8_UNORM;
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
    ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.window_viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(d3d.device_context, D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(d3d.device_context, d3d.fullscreen_vs, null, 0);
    ID3D11DeviceContext_PSSetShader(d3d.device_context, d3d.resolve_accumulation_buffer_ps, null, 0);
    ID3D11DeviceContext_PSSetSamplers(d3d.device_context, 0, 1, *d3d.nearest_neighbour_sampler);
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *d3d.accumulation_buffer_srv);
    ID3D11DeviceContext_PSSetConstantBuffers(d3d.device_context, 0, 1, *d3d.resolve_accumulation_buffer_cb);
    ID3D11DeviceContext_Draw(d3d.device_context, 3, 0);

    null_srv: *ID3D11ShaderResourceView;
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *null_srv);
}

present :: ()
{
    if immediate.icount > 0
    {
        immediate_flush();
    }

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

Texture :: struct
{
    tex: *ID3D11Texture2D;
    srv: *ID3D11ShaderResourceView;
    rtv: *ID3D11RenderTargetView;
}

map :: (tex: Texture) -> Bitmap
{
    bitmap: Bitmap;

    mapped: D3D11_MAPPED_SUBRESOURCE;

    hr := ID3D11DeviceContext_Map(d3d.device_context, tex.tex, 0, .WRITE_DISCARD, 0, *mapped);
    if always(SUCCEEDED(hr))
    {
        desc: D3D11_TEXTURE2D_DESC;
        ID3D11Texture2D_GetDesc(tex.tex, *desc);

        bitmap.w          = xx desc.Width;
        bitmap.h          = xx desc.Height;
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

get_scene_texture :: () -> Texture
{
    tex: Texture;
    tex.tex = d3d.target_texture;
    tex.srv = d3d.target_texture_srv;
    tex.rtv = d3d.target_texture_rtv;
    return tex;
}

Immediate_Shader :: enum
{
    None;
    Default;
    Image;
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

immediate_set_shader :: (shader: Immediate_Shader)
{
    assert(immediate.shader == .None);
    immediate.shader = shader;
}

immediate_bind_texture :: (tex: Texture)
{
    immediate.texture = tex;
}

immediate_index :: (index: u16)
{
    immediate.ibuffer[immediate.icount] = index;
    immediate.icount += 1;
}

immediate_vertex :: (vertex: Immediate_Vertex) -> u16
{
    index := cast(u16)immediate.vcount;
    immediate.vbuffer[index] = vertex;
    immediate.vcount += 1;
    return index;
}

immediate_vertex :: (position: Vector3, color: u32, texcoord: Vector2) -> u16
{
    vertex: Immediate_Vertex = ---;
    vertex.position = position;
    vertex.color    = color;
    vertex.texcoord = texcoord;
    return immediate_vertex(vertex);
}

immediate_quad :: (x0: float, y0: float, x1: float, y1: float, color: Vector4)
{
    icolor := pack_color(color);

    v00 := immediate_vertex(make_vector3(x0, y0, 0.5), icolor, make_vector2(0, 1));
    v10 := immediate_vertex(make_vector3(x1, y0, 0.5), icolor, make_vector2(1, 1));
    v01 := immediate_vertex(make_vector3(x0, y1, 0.5), icolor, make_vector2(0, 0));
    v11 := immediate_vertex(make_vector3(x1, y1, 0.5), icolor, make_vector2(1, 0));

    immediate_index(v00);
    immediate_index(v11);
    immediate_index(v10);

    immediate_index(v00);
    immediate_index(v01);
    immediate_index(v11);
}

immediate_set_screenspace :: ()
{
    a := 2.0 / d3d.window_w;
    b := 2.0 / d3d.window_h;

    cb: Immediate_Vs_Cb;
    cb.matrix = make_matrix4(
        a, 0, 0,-1,
        0, b, 0,-1,
        0, 0, 1, 0,
        0, 0, 0, 1,
    );

    update_buffer(d3d.immediate_vs_cb, *cb);
}

immediate_set_ndc_space :: ()
{
    a := 1.0;
    b := 1.0;

    cb: Immediate_Vs_Cb;
    cb.matrix = make_matrix4(
        a, 0, 0,-1,
        0, b, 0,-1,
        0, 0, 1, 0,
        0, 0, 0, 1,
    );

    update_buffer(d3d.immediate_vs_cb, *cb);
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

immediate_flush :: ()
{
    if immediate.icount == 0  return;

    update_buffer(d3d.immediate_indices, immediate.ibuffer.data, immediate.icount);
    update_buffer(d3d.immediate_vertices, immediate.vbuffer.data, immediate.vcount);

    ID3D11DeviceContext_OMSetRenderTargets(d3d.device_context, 1, *d3d.back_buffer_rtv, null);
    ID3D11DeviceContext_OMSetBlendState(d3d.device_context, d3d.immediate_blend, null, 0xffffffff);
    ID3D11DeviceContext_RSSetViewports(d3d.device_context, 1, *d3d.window_viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(d3d.device_context, D3D11_PRIMITIVE_TOPOLOGY.TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(d3d.device_context, d3d.immediate_layout);
    ID3D11DeviceContext_IASetIndexBuffer(d3d.device_context, d3d.immediate_indices, .R16_UINT, 0);

    stride: u32 = size_of(Immediate_Vertex);
    offset: u32 = 0;
    ID3D11DeviceContext_IASetVertexBuffers(d3d.device_context, 0, 1, *d3d.immediate_vertices, *stride, *offset);

    ID3D11DeviceContext_VSSetShader(d3d.device_context, d3d.immediate_vs, null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(d3d.device_context, 0, 1, *d3d.immediate_vs_cb);
    ID3D11DeviceContext_PSSetShader(d3d.device_context, d3d.immediate_ps, null, 0);
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *immediate.texture.srv);
    ID3D11DeviceContext_PSSetSamplers(d3d.device_context, 0, 1, *d3d.bilinear_sampler);
    ID3D11DeviceContext_DrawIndexed(d3d.device_context, xx immediate.icount, 0, 0);

    null_srv: *ID3D11ShaderResourceView;
    ID3D11DeviceContext_PSSetShaderResources(d3d.device_context, 0, 1, *null_srv);

    immediate.icount = 0;
    immediate.vcount = 0;

    white_texture: Texture;
    white_texture.tex = d3d.white_texture;
    white_texture.srv = d3d.white_texture_srv;
    immediate.texture = white_texture;
}

#scope_file

MAX_IMMEDIATE_INDICES  :: 1 << 14;
MAX_IMMEDIATE_VERTICES :: 1 << 14;

Immediate_State :: struct
{
    shader: Immediate_Shader;
    texture: Texture;

    icount: int;
    vcount: int;

    ibuffer: [MAX_IMMEDIATE_INDICES ] u16;
    vbuffer: [MAX_IMMEDIATE_VERTICES] Immediate_Vertex;
}

immediate: Immediate_State;

D3D_State :: struct
{
    driver_type   := D3D_DRIVER_TYPE.NULL;
    feature_level := D3D_FEATURE_LEVEL._11_0;

    device                         : *ID3D11Device;
    device_context                 : *ID3D11DeviceContext;
    swap_chain                     : *IDXGISwapChain1;

    nearest_neighbour_sampler      : *ID3D11SamplerState;
    bilinear_sampler               : *ID3D11SamplerState;

    white_texture                  : *ID3D11Texture2D;
    white_texture_srv              : *ID3D11ShaderResourceView;

    immediate_indices              : *ID3D11Buffer;
    immediate_vertices             : *ID3D11Buffer;
    immediate_blend                : *ID3D11BlendState;
    immediate_layout               : *ID3D11InputLayout;
    immediate_vs_cb                : *ID3D11Buffer;
    immediate_vs                   : *ID3D11VertexShader;
    immediate_ps                   : *ID3D11PixelShader;

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
