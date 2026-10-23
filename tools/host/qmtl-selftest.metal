// Shaders for tools/host/qmtl-selftest.m.
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut st_vertex(uint vid [[vertex_id]], const device float2 *pos [[buffer(0)]])
{
	return { float4(pos[vid], 0, 1) };
}

fragment float4 st_fragment(constant float4 &color [[buffer(0)]])
{
	return color;
}
