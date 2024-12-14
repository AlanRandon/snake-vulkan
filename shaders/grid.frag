#version 450

layout(binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;


void main() {
    outColor = texture(texSampler, fragTexCoord);
    // ignore transparent pixels
    if (outColor.w == 0.0) {
	discard;
    }
}

// vim:ft=glsl
