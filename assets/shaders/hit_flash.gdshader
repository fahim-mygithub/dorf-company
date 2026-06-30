shader_type canvas_item;

// Hit flash — mix the sprite toward flash_color by `flash` (0..1).
// Drive `flash` 0->1->0 over ~0.15s on damage (longer here for the test demo).
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0);

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(mix(tex.rgb, flash_color.rgb, flash), tex.a);
}
