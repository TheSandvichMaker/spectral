// --------------------------------------------
// Vertex Shader

cbuffer Matrices : register(b0)
{
    float4x4 mat;
}

struct VS_Input
{
    float3 position : POSITION;
    uint   color    : COLOR;
    float2 texcoord : TEXCOORD;
};

struct VS_Output
{
    float4 position : SV_POSITION;
    float4 color    : COLOR;
    float2 texcoord : TEXCOORD;
};

VS_Output immediate_vs(VS_Input IN) 
{
    VS_Output OUT;
    OUT.position = mul(float4(IN.position, 0.5), mat);
    OUT.color.x = float((IN.color >>  0) & 0xFF) * (1.0 / 255.0);
    OUT.color.y = float((IN.color >>  8) & 0xFF) * (1.0 / 255.0);
    OUT.color.z = float((IN.color >> 16) & 0xFF) * (1.0 / 255.0);
    OUT.color.w = float((IN.color >> 24) & 0xFF) * (1.0 / 255.0);
    OUT.texcoord = IN.texcoord;
    return OUT;
}

// --------------------------------------------
// Pixel Shader

Texture2D<float4> tex : register(t0);
sampler           smp : register(s0);

float4 immediate_ps(VS_Output IN) : SV_Target 
{
    float4 color = IN.color*tex.Sample(smp, IN.texcoord);
    return color;
}

// --------------------------------------------
