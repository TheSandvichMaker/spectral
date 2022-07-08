// --------------------------------------------
// Vertex Shader

struct VS_Output
{
    float4 position : SV_POSITION;
    float2 texcoord : TEXCOORD;
};

VS_Output fullscreen_vs(uint id : SV_VertexID) 
{
    VS_Output OUT;
    OUT.texcoord = uint2(id << 1, id) & 2;
    OUT.position = float4(OUT.texcoord*float2(2, -2) + float2(-1, 1), 0, 1);
    return OUT;
}

// --------------------------------------------
// Pixel Shader

cbuffer Parameters : register(b0)
{
    float frame_count;
}

Texture2D<float3> accumulation_buffer : register(t0);
sampler samp : register(s0);

float3 linear_to_srgb(float3 c)
{
    return c <= 0.0031308 ? 12.92*c : 1.055*pow(c, 1.0/2.4) - 0.055;
}

float4 hash43n(float3 p)
{
    p  = frac(p * float3(5.3987, 5.4421, 6.9371));
    p += dot(p.yzx, p.xyz  + float3(21.5351, 14.3137, 15.3247));
    return frac(float4(p.x * p.y * 95.4307, p.x * p.y * 97.5901, p.x * p.z * 93.8369, p.y * p.z * 91.6931 ));
}

float3 tonemap(float3 c)
{
    return 1.0 - exp(-c);
}

float4 resolve_accumulation_buffer_ps(VS_Output IN) : SV_Target 
{
    float3 color = accumulation_buffer.Sample(samp, IN.texcoord);
    color /= frame_count;

    float4 r0f = hash43n(float3(IN.texcoord, fmod(frame_count, 1024)));
    float4 rnd = r0f - 0.5;
    float4 t = step(0.5/255.0, color.xyzz)*step(color.xyzz, 1.0 - 0.5/255.0);
    rnd += t*(r0f.yzwx - 0.5);

    color.xyz += rnd.xyz / 255.0;

    color = tonemap(color);
    color = linear_to_srgb(color);

    return float4(color, 1.0);
}

// --------------------------------------------
