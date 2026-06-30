# Card VFX canvas_item shader snippets

All are `shader_type canvas_item;`. Expose uniforms so an AnimationPlayer/Tween can drive them.

## Hit flash (mix toward white)
```gdshader
shader_type canvas_item;
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0);
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    COLOR = vec4(mix(tex.rgb, flash_color.rgb, flash) , tex.a);
}
```
Drive: tween `flash` 0→1→0 over ~0.15s on damage.

## Dissolve (card destruction / summon)
```gdshader
shader_type canvas_item;
uniform sampler2D noise_tex;
uniform float threshold : hint_range(0.0, 1.0) = 0.0;
uniform vec4 edge_color : source_color = vec4(1.0, 0.6, 0.1, 1.0);
uniform float edge_width = 0.05;
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float n = texture(noise_tex, UV).r;
    if (n < threshold) discard;
    float edge = step(n - edge_width, threshold);
    COLOR = vec4(mix(tex.rgb, edge_color.rgb, edge), tex.a);
}
```
Drive: tween `threshold` 0→1 to dissolve, reverse to materialize.

## Holographic shimmer (rare card)
```gdshader
shader_type canvas_item;
uniform float speed = 1.0;
uniform float strength : hint_range(0.0, 1.0) = 0.3;
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float band = sin((UV.x + UV.y) * 10.0 + TIME * speed) * 0.5 + 0.5;
    vec3 holo = vec3(band, 1.0 - band, 0.5 + 0.5 * band);
    COLOR = vec4(mix(tex.rgb, holo, strength * tex.a), tex.a);
}
```

## Setting uniforms from script
```gdscript
var mat := sprite.material as ShaderMaterial
mat.set_shader_parameter("flash", 1.0)
# or keyframe "material:shader_parameter/flash" in an AnimationPlayer value track
```

## Aura glow (Paladin devotion / smite shaft)
```gdshader
shader_type canvas_item;
uniform float intensity : hint_range(0.0, 3.0) = 1.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.84, 0.4, 1.0);
uniform float pulse_speed = 2.0;
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    float pulse = 0.75 + 0.25 * sin(TIME * pulse_speed);
    vec3 glow = glow_color.rgb * intensity * pulse;
    COLOR = vec4(tex.rgb + glow * tex.a, tex.a);
}
```
Drive `intensity` from Devotion level; raise on smite impact then fade.
