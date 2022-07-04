struct Vertex_Shader_Output
{
    float2 texcoord : TEXCOORD;
    float4 position : SV_POSITION;
};

Vertex_Shader_Output fullscreen_vs(uint vertex_id : SV_VertexID)
{
    Vertex_Shader_Output OUT;
    OUT.texcoord = float2(uint2(vertex_id, vertex_id << 1) & 2);
    OUT.position = float4(lerp(float2(-1, 1), float2(1, -1), OUT.texcoord), 0, 1);
    return OUT;
}

cbuffer Parameters : register(b0)
{
    float frame_count;
}

Texture2D<float4> accumulation_buffer : register(t0);
sampler samp : register(s0);

float4 resolve_accumulation_buffer_ps(float2 texcoord : TEXCOORD, float4 pos : SV_POSITION) : SV_Target
{
    float3 color = accumulation_buffer.Sample(samp, texcoord);
    color /= frame_count;

    return float4(1, 0, 0, 1);
}
