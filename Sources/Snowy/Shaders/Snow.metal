#include <metal_stdlib>
using namespace metal;

struct FrameUniforms { float2 viewport; float time; float padding; };
struct SnowVertex { float2 position; float2 material; };
struct ParticleInstance { float2 position; float radius; float opacity; };
struct DriftOut { float4 position [[position]]; float2 material; float2 point; };
struct FlakeOut { float4 position [[position]]; float2 uv; float opacity; };

float4 project(float2 point, constant FrameUniforms &frame) {
    return float4(point.x / frame.viewport.x * 2 - 1, 1 - point.y / frame.viewport.y * 2, 0, 1);
}

vertex DriftOut driftVertex(uint id [[vertex_id]], const device SnowVertex *vertices [[buffer(0)]],
                            constant FrameUniforms &frame [[buffer(1)]]) {
    SnowVertex v = vertices[id];
    return { project(v.position, frame), v.material, v.position };
}

fragment half4 driftFragment(DriftOut in [[stage_in]]) {
    float shade = smoothstep(0.0, 1.0, in.material.x);
    float grain = fract(52.9829189 * fract(dot(in.point, float2(0.06711056, 0.00583715))));
    half3 color = mix(half3(0.76, 0.84, 0.93), half3(0.99, 0.995, 1.0), half(shade));
    color += half((grain - 0.5) * 0.012);
    half alpha = half(in.material.y);
    return half4(color * alpha, alpha);
}

vertex FlakeOut flakeVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                            const device ParticleInstance *particles [[buffer(0)]],
                            constant FrameUniforms &frame [[buffer(1)]]) {
    const float2 corners[6] = { {-1,-1}, {1,-1}, {-1,1}, {1,-1}, {1,1}, {-1,1} };
    ParticleInstance p = particles[instance];
    float2 uv = corners[id];
    return { project(p.position + uv * (p.radius + 0.6), frame), uv, p.opacity };
}

fragment half4 flakeFragment(FlakeOut in [[stage_in]]) {
    float distance = length(in.uv);
    half alpha = half((1 - smoothstep(0.30, 1.0, distance)) * in.opacity);
    return half4(half3(0.96, 0.98, 1.0) * alpha, alpha);
}
