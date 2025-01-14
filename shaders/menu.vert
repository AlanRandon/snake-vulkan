#version 450

layout(push_constant) uniform pc {
	vec2 winSize;
};

layout(location = 0) out vec2 fragTexCoord;

vec2 vertices[4] = vec2[](
	vec2(0.0, 0.0),
	vec2(1.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 1.0)
);

void main() {
	float minAxis = min(winSize.x, winSize.y);
	vec2 viewSize = vec2(minAxis) / winSize * 2.;
	vec2 pos = (vertices[gl_VertexIndex] - vec2(0.5)) * viewSize;
	gl_Position = vec4(pos, 0., 1.);
	fragTexCoord = vertices[gl_VertexIndex];
}

// vim:ft=glsl
