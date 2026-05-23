// Ghibli Serene Nature ambient pulse shader.
// Palette derived by hand for deep forest ink, moss greens, misty lake blues,
// and warm earth highlights. This shader only adds slow theme-colored glow.

const vec3 MOSS = vec3(0.561, 0.682, 0.435);       // #8fae6f
const vec3 LAKE_MIST = vec3(0.478, 0.627, 0.647);  // #7aa0a5
const vec3 SUN_STRAW = vec3(0.839, 0.718, 0.475);  // #d6b779

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec4 terminal = texture(iChannel0, uv);

    float slowWave = 0.5 + 0.5 * sin(iTime * 0.45 + uv.y * 5.2 + uv.x * 1.4);
    float leafGlow = smoothstep(0.18, 0.96, slowWave) * 0.030;
    float sunDrift = smoothstep(0.0, 1.0, uv.x) * smoothstep(1.0, 0.10, uv.y) * 0.020;

    vec3 glow = mix(LAKE_MIST, MOSS, uv.y) * leafGlow + SUN_STRAW * sunDrift;
    vec3 color = terminal.rgb + glow * (1.0 - max(max(terminal.r, terminal.g), terminal.b) * 0.45);

    fragColor = vec4(clamp(color, 0.0, 1.0), terminal.a);
}
