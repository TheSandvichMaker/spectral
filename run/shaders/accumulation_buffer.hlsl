// --------------------------------------------
// Vertex Shader

struct VS_Output
{
    float4 position : SV_POSITION;
    float2 texcoord : TEXCOORD;
};

// 000      & 2 == 00
// 001      & 2 == 00
// 010      & 2 == 10

// 000 << 1 & 2 == 00
// 001 << 1 & 2 == 10
// 100 << 1 & 2 == 00

// uint2(0, 0)
// uint2(0, 2)
// uint2(2, 0)

// -1  1
// -1 -1
//  1  1

VS_Output fullscreen_vs(uint id : SV_VertexID) 
{
    VS_Output OUT;
    OUT.texcoord = uint2(id, id << 1) & 2;
    OUT.position = float4(lerp(float2(-1, 1), float2(1, -1), OUT.texcoord), 0, 1);
    return OUT;
}

// --------------------------------------------
// Pixel Shader

// The code in this file was originally written by Stephen Hill (@self_shadow), who deserves all
// credit for coming up with this fit and implementing it. Buy him a beer next time you see him. :)

// sRGB => XYZ => D65_2_D60 => AP1 => RRT_SAT
static const float3x3 ACESInputMat =
{
    {0.59719, 0.35458, 0.04823},
    {0.07600, 0.90834, 0.01566},
    {0.02840, 0.13383, 0.83777}
};

// ODT_SAT => XYZ => D60_2_D65 => sRGB
static const float3x3 ACESOutputMat =
{
    { 1.60475, -0.53108, -0.07367},
    {-0.10208,  1.10813, -0.00605},
    {-0.00327, -0.07276,  1.07602}
};

float3 RRTAndODTFit(float3 v)
{
    float3 a = v * (v + 0.0245786f) - 0.000090537f;
    float3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
    return a / b;
}

float3 ACESFitted(float3 color)
{
    color = mul(ACESInputMat, color);

    // Apply RRT and ODT
    color = RRTAndODTFit(color);

    color = mul(ACESOutputMat, color);

    // Clamp to [0, 1]
    color = saturate(color);

    return color;
}

cbuffer Parameters : register(b0)
{
    float frame_count;
}

Texture2D<float4> accumulation_buffer : register(t0);
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

struct PS_Output
{
    float4 color : SV_Target;
};

PS_Output resolve_accumulation_buffer_ps(VS_Output IN)
{
    float4 sample = accumulation_buffer.Sample(samp, IN.texcoord);
    float3 color = sample.rgb;
    float  depth = sample.a;

    color /= frame_count;

    float4 r0f = hash43n(float3(IN.texcoord, fmod(frame_count, 1024)));
    float4 rnd = r0f - 0.5;
    float4 t = step(0.5/255.0, color.xyzz)*step(color.xyzz, 1.0 - 0.5/255.0);
    rnd += t*(r0f.yzwx - 0.5);

    color += rnd.xyz / 255.0;

    color = ACESFitted(color);
    color = linear_to_srgb(color);

    PS_Output OUT;
    OUT.color = float4(color, depth);

    return OUT;
}

// --------------------------------------------
