@vs vs
in vec2 position;
in vec2 texIn;
out vec2 texPosition;

void main() {
	gl_Position = vec4(position, 0.0, 1.0);
	texPosition = texIn;
}
@end

@fs fs
layout(binding = 0) uniform texture2D tex;
layout(binding = 1) uniform sampler smp;

in vec2 texPosition;
out vec4 fragColor;

void main() {
	fragColor = texture(sampler2D(tex, smp), texPosition);
}
@end

@program texture vs fs
