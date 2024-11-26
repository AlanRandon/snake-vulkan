#version 450

layout(push_constant) uniform pc {
	vec2 winSize;
	vec2 cellSize;
};

layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in vec2 inOffset;
layout(location = 3) in float inTileNumber;

layout(location = 0) out vec2 fragTexCoord;

vec2 corners[4] = vec2[](
	vec2(0.0, 0.0),
	vec2(1.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 1.0)
);

void main() {
	float minAxis = min(winSize.x, winSize.y);
	vec2 viewSize = vec2(minAxis) / winSize * 2.;
	vec2 pos = (((inOffset + corners[gl_VertexIndex]) * cellSize) - vec2(0.5)) * viewSize;
	gl_Position = vec4(pos, 0.0, 1.0);
	fragTexCoord = (inTexCoord + vec2(inTileNumber, 0.0)) * vec2(0.125, 1.0);
}

// vim:ft=glsl
