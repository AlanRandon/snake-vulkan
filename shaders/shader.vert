#version 450

layout(push_constant) uniform pc {
	vec2 winsize;
};

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec3 inColor;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec2 inOffset;
layout(location = 4) in float inTileNumber;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTexCoord;

void main() {
	float minAxis = min(winsize.x, winsize.y);
	vec2 viewSize = vec2(minAxis / winsize.x, minAxis / winsize.y) * 2.;
	vec2 pos = (inOffset + inPosition - vec2(0.5)) * viewSize;
	gl_Position = vec4(pos, 0.0, 1.0);
	fragColor = inColor;
	fragTexCoord = (inTexCoord + vec2(inTileNumber, 0.0)) * vec2(0.125, 1.0);
}

// vim:ft=glsl
