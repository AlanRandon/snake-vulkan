#version 450

layout(push_constant) uniform pc {
	vec2 winSize;
	vec2 cellSize;
};

layout(location = 0) in vec2 inOffset;
layout(location = 1) in float inTileNumber;
layout(location = 2) in vec4 cellTransform;
layout(location = 4) in vec2 cellTranslate;

layout(location = 0) out vec2 fragTexCoord;

vec2 vertices[4] = vec2[](
	vec2(0.0, 0.0),
	vec2(1.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 1.0)
);

vec2 texVertices[4] = vec2[](
	vec2(1.0, 0.0),
	vec2(0.0, 0.0),
	vec2(0.0, 1.0),
	vec2(1.0, 1.0)
);

void main() {
	float minAxis = min(winSize.x, winSize.y);
	vec2 viewSize = vec2(minAxis) / winSize * 2.;
	vec2 posInGrid = (inOffset + vertices[gl_VertexIndex]);
	vec2 pos = (posInGrid * cellSize - vec2(0.5)) * viewSize;
	gl_Position = vec4(pos, 0., 1.);
	vec2 texVertex = (mat2x2(cellTransform) * texVertices[gl_VertexIndex]) + cellTranslate;
	fragTexCoord = (texVertex + vec2(inTileNumber, 0.)) * vec2(1. / 9., 1.);
}

// vim:ft=glsl
