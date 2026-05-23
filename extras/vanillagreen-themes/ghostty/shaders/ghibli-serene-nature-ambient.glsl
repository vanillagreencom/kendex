// Ghibli Serene Nature ambient shader.
// Palette derived by hand for deep forest ink, moss greens, misty lake blues,
// and warm earth highlights. This shader only blends subtle theme-colored light.

const vec3 FOREST_INK = vec3(0.090, 0.129, 0.114); // #17211d
const vec3 MOSS = vec3(0.561, 0.682, 0.435);       // #8fae6f
const vec3 LAKE_MIST = vec3(0.478, 0.627, 0.647);  // #7aa0a5
const vec3 SUN_STRAW = vec3(0.839, 0.718, 0.475);  // #d6b779

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec4 terminal = texture(iChannel0, uv);

    vec3 verticalMist = mix(LAKE_MIST, MOSS, smoothstep(0.10, 0.95, uv.y));
    float luminance = dot(terminal.rgb, vec3(0.2126, 0.7152, 0.0722));
    float shadowTint = (1.0 - smoothstep(0.16, 0.70, luminance)) * 0.075;

    vec2 center = uv - vec2(0.5, 0.48);
    float softVignette = 1.0 - smoothstep(0.18, 0.82, dot(center, center) * 2.0);
    vec3 color = mix(terminal.rgb, verticalMist, shadowTint);
    color += SUN_STRAW * 0.018 * softVignette;
    color = mix(FOREST_INK, color, 0.992);

    fragColor = vec4(clamp(color, 0.0, 1.0), terminal.a);
}
