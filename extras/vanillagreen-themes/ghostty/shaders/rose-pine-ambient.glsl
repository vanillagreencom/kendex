// mascot-core: shared template for all themes.
// Renders: theme ambient + 8-bit pixel-art character + (optional) 8-bit bell.
// theme.sh / render-mascot.sh substitutes the placeholders below.

#define PX           5.0
#define FPS          8.0
#define BELL_PX      5.0
#define BELL_FPS     6.0

// Geometry knobs (substituted per theme).
#define SHAPE_W      5.5
#define SHAPE_H      5.5
#define SHAPE_SQUARE 0.0   // 0.0 = ellipse, 1.0 = rectangle

// Style selectors (substituted per theme).
#define EYE_STYLE    0.0      // 0=v-oval+hl, 1=round-dot, 2=slit, 3=red-glow
#define ACCESSORY    0.0      // 0=none, 1=leaf-hat, 2=fangs, 3=flower-crown,
                                        // 4=ninja-band, 5=beak, 6=tongue, 7=wings,
                                        // 8=leaf-stem, 9=belly-patch
#define BLUSH_ON     0.0       // 0.0 or 1.0
#define FOOT_ON      1.0        // 0.0 or 1.0 (some characters float)
#define MOVEMENT     0.0       // 0=walk, 1=fly, 2=hop, 3=slide,
                                        // 4=roll, 5=hover, 6=march, 7=bounce
#define SPRITE_TYPE  7.0    // 0=blob, 1=cat, 2=splat,
                                        // 3=pirate corsair, 4=rocketship,
                                        // 5=WSB guy, 6=deer pair, 7=bunny,
                                        // 8=squirrel, 9=NES warrior
#define SPRITE_TYPE_ID 7
#define LOOP_DUR     28.0       // seconds for the blob walk pingpong

// Palette (substituted per theme).
#define BODY_COL     vec3(0.965, 0.886, 0.835)
#define OUTLINE_COL  vec3(0.435, 0.235, 0.290)
#define FOOT_COL     vec3(0.965, 0.886, 0.835)
#define BLUSH_COL    vec3(0.922, 0.435, 0.573)
#define ACC_COL      vec3(0.0, 0.0, 0.0)
#define ACC2_COL     vec3(0.0, 0.0, 0.0)
#define EYE_COL      vec3(0.157, 0.090, 0.141)
#define EYE_HL_COL   vec3(1.0, 1.0, 1.0)
#define BELL_COL     vec3(0.922, 0.435, 0.573)
#define BELL_OUTLINE vec3(0.157, 0.090, 0.141)

#define SHOW_BELL    0.0
#define SHOW_BELL_ID 0
#define BG_COL       vec3(0.200, 0.169, 0.157)

float hash11(float n) { return fract(sin(n * 12.9898) * 43758.5453); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float len2(vec2 v) { return dot(v, v); }
float len3(vec3 v) { return dot(v, v); }
bool inRect(vec2 px, vec2 lo, vec2 hi) {
    return px.x >= lo.x && px.x <= hi.x && px.y >= lo.y && px.y <= hi.y;
}
bool samePx(vec2 a, float x, float y) { return a.x == x && a.y == y; }

// ----- Pirate Corsair sprite (detailed 16-bit style) -----
// Matches reference: stout pirate, huge red beard, tricorn hat with gold trim,
// red bandana, teal coat with gold-trimmed collar, brown belt + boots,
// sword held in left hand extending above hat.
// Sprite extents: x in [-11, 10], y in [0, 54].
vec4 sampleCorsair(vec2 fragPos, vec2 anchor, float scale, float pose, float frame, float dir,
                  vec3 coat, vec3 outline, vec3 beard, vec3 skin, vec3 hat,
                  vec3 gold, vec3 belt, vec3 boot, vec3 sword, vec3 cream,
                  vec3 navy, vec3 bandana_col, vec3 eye_blue) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -12.0 || spx.x > 11.0 || spx.y < -1.0 || spx.y > 55.0) return vec4(0.0);
    float ax = abs(spx.x);

    // Per-pixel hash for texture variation (shadow / base / lit dither).
    float h = hash21(spx + vec2(127.0, 311.0));
    // shade_t: 0 = shadow, 0.5 = base, 1.0 = lit.  Combine hash with position
    // so we get a directional lighting feel (top-right brighter, bottom-left darker)
    // overlaid with hash-based noise (gives the painterly pixel-art look).
    float pos_light = 0.5 + (spx.x * 0.04) + (spx.y * 0.012);
    float shade_t = clamp(pos_light + (h - 0.5) * 0.55, 0.0, 1.0);
    // Discretize to 3 tones for crisp pixel-art shading.
    float tone = (shade_t < 0.33) ? 0.0 : ((shade_t < 0.66) ? 1.0 : 2.0);

    // ============================================================
    // SWORD (held in left hand, blade extends above hat).
    // ============================================================
    bool sword_blade_lit  = spx.x == -9.0 && spx.y >= 17.0 && spx.y <= 51.0;
    bool sword_blade_dark = spx.x == -8.0 && spx.y >= 17.0 && spx.y <= 51.0;
    bool sword_tip        = (spx.x == -9.0 || spx.x == -8.0) && spx.y == 52.0;
    bool sword_notch      = spx.x == -8.0 && (spx.y == 30.0 || spx.y == 38.0); // detail
    bool sword_guard      = spx.y == 16.0 && spx.x >= -10.0 && spx.x <= -7.0;
    bool sword_handle     = spx.x == -8.0 && spx.y >= 12.0 && spx.y <= 15.0;
    bool sword_pommel_top = spx.y == 11.0 && (spx.x == -8.0 || spx.x == -9.0);
    bool sword_pommel_btm = spx.y == 10.0 && spx.x == -8.0;

    if (sword_tip)         return vec4(sword * 1.1, 1.0);
    if (sword_notch)       return vec4(sword * 0.55, 1.0);
    if (sword_blade_lit)   return vec4(sword * 1.05, 1.0);
    if (sword_blade_dark)  return vec4(sword * 0.68, 1.0);
    if (sword_guard) {
        return vec4(gold * (spx.x == -7.0 ? 1.2 : 0.85), 1.0);   // lit edge
    }
    if (sword_handle)      return vec4(belt * (spx.y > 13.0 ? 0.55 : 0.45), 1.0);
    if (sword_pommel_top)  return vec4(gold * 1.15, 1.0);
    if (sword_pommel_btm)  return vec4(gold * 0.75, 1.0);

    // ============================================================
    // LEFT HAND gripping sword (skin pixels around handle).
    // ============================================================
    bool left_hand = (spx.x == -7.0 && spx.y >= 13.0 && spx.y <= 15.0)
                  || (spx.x == -6.0 && spx.y == 14.0);
    if (left_hand) return vec4(skin, 1.0);

    // ============================================================
    // HAT (tricorn).  Brim wide with gold trim, crown above with center emblem.
    // ============================================================
    // Brim outline (gold).
    bool hat_brim_gold = (spx.y == 38.0 && (ax == 10.0 || ax == 9.0))
                      || (spx.y == 37.0 && (ax == 10.0 || ax == 9.0 || ax == 8.0))
                      || (spx.y == 41.0 && (ax >= 6.0 && ax <= 9.0))
                      || (spx.y == 42.0 && (ax == 5.0 || ax == 6.0))
                      || (spx.y == 43.0 && (ax == 4.0 || ax == 5.0));
    // Brim interior.
    bool hat_brim = (spx.y == 38.0 && ax <= 8.0)
                 || (spx.y == 39.0 && ax <= 9.0)
                 || (spx.y == 40.0 && ax <= 8.0)
                 || (spx.y == 41.0 && ax <= 5.0);
    // Crown.
    bool hat_crown = (spx.y == 42.0 && ax <= 4.0)
                  || (spx.y == 43.0 && ax <= 3.0)
                  || (spx.y == 44.0 && ax <= 2.0);
    // Gold center emblem.
    bool hat_emblem = (spx.y == 39.0 || spx.y == 40.0) && (spx.x == 0.0 || spx.x == 1.0);
    bool hat_emblem_dot = spx.x == 0.0 && spx.y == 40.0;

    if (hat_emblem_dot)   return vec4(belt * 0.7, 1.0);
    if (hat_emblem)       return vec4(gold * (h > 0.5 ? 1.15 : 0.85), 1.0);
    if (hat_brim_gold)    return vec4(gold * (h > 0.4 ? 1.10 : 0.80), 1.0);
    if (hat_brim || hat_crown) {
        if (tone < 0.5)     return vec4(hat * 0.65, 1.0);  // shadow
        if (tone < 1.5)     return vec4(hat,        1.0);
        return vec4(hat * 1.30, 1.0);                       // lit
    }

    // ============================================================
    // BANDANA (under hat, right side, with tail hanging down).
    // ============================================================
    bool bandana = (spx.y == 36.0 && spx.x >= 4.0 && spx.x <= 8.0)
                || (spx.y == 35.0 && spx.x >= 4.0 && spx.x <= 8.0)
                || (spx.y == 34.0 && spx.x >= 5.0 && spx.x <= 8.0)
                || (spx.y == 33.0 && spx.x >= 6.0 && spx.x <= 8.0)
                || (spx.y == 32.0 && (spx.x == 8.0 || spx.x == 7.0))
                || (spx.y == 31.0 && spx.x == 8.0)
                || (spx.y == 30.0 && spx.x == 8.0);
    if (bandana) {
        if (tone < 0.5) return vec4(bandana_col * 0.6, 1.0);
        if (tone < 1.5) return vec4(bandana_col,        1.0);
        return vec4(bandana_col * 1.35, 1.0);
    }

    // ============================================================
    // EYES (blue with white pixel).
    // ============================================================
    bool eye_L = (spx.x == -2.0 && spx.y == 34.0);
    bool eye_R = (spx.x ==  2.0 && spx.y == 34.0);
    if (eye_L || eye_R) return vec4(eye_blue * 1.1, 1.0);

    // ============================================================
    // BEARD (HUGE red beard, zig-zag bottom).
    // ============================================================
    bool in_beard = false;
    if (spx.y == 32.0 && ax <= 4.0 && !(spx.x == 0.0)) in_beard = true;
    if (spx.y == 31.0 && ax <= 5.0) in_beard = true;
    if (spx.y == 30.0 && ax <= 5.0) in_beard = true;
    if (spx.y == 29.0 && ax <= 5.0) in_beard = true;
    if (spx.y == 28.0 && ax <= 4.0) in_beard = true;
    if (spx.y == 27.0 && ax <= 4.0) in_beard = true;
    if (spx.y == 26.0 && ax <= 3.0) in_beard = true;
    // Zig-zag bottom edge (3 points).
    if (spx.y == 25.0 && (ax == 0.0 || ax == 2.0 || ax == 3.0)) in_beard = true;
    if (spx.y == 24.0 && (ax == 0.0)) in_beard = true;
    if (in_beard) {
        if (tone < 0.5) return vec4(beard * 0.55, 1.0);   // shadow red-brown
        if (tone < 1.5) return vec4(beard,        1.0);   // base orange
        return vec4(beard * 1.18 + vec3(0.0, 0.05, 0.0), 1.0);   // lit orange-yellow
    }

    // ============================================================
    // FACE / NOSE / SKIN.
    // ============================================================
    bool nose = spx.x == 0.0 && spx.y == 33.0;
    bool face = spx.y >= 32.0 && spx.y <= 36.0 && ax <= 4.0;
    if (nose) return vec4(skin * 0.78, 1.0);
    if (face) {
        if (tone < 0.5) return vec4(skin * 0.78, 1.0);
        if (tone < 1.5) return vec4(skin,        1.0);
        return vec4(skin * 1.12, 1.0);
    }

    // ============================================================
    // RIGHT ARM hanging at side (with cream cuff + skin hand).
    // ============================================================
    bool right_hand  = (spx.x == 8.0 || spx.x == 9.0) && (spx.y == 11.0 || spx.y == 12.0);
    bool right_cuff_red = (spx.x == 8.0 || spx.x == 9.0) && spx.y == 13.0;  // red cuff band
    bool right_cuff  = (spx.x == 7.0 || spx.x == 8.0 || spx.x == 9.0) && spx.y == 14.0;
    bool right_sleev = (spx.x == 7.0 || spx.x == 8.0 || spx.x == 9.0) && spx.y >= 15.0 && spx.y <= 23.0;

    if (right_hand)     return vec4(skin * (h > 0.5 ? 1.08 : 0.92), 1.0);
    if (right_cuff_red) return vec4(bandana_col * 1.1, 1.0);
    if (right_cuff)     return vec4(cream * (h > 0.5 ? 1.05 : 0.90), 1.0);
    if (right_sleev) {
        if (tone < 0.5) return vec4(coat * 0.60, 1.0);
        if (tone < 1.5) return vec4(coat,        1.0);
        return vec4(coat * 1.25, 1.0);
    }

    // ============================================================
    // COLLAR with gold trim (each shoulder).
    // ============================================================
    bool collar_gold = (spx.y == 24.0 && (ax == 4.0 || ax == 5.0 || ax == 6.0))
                    || (spx.y == 23.0 && (ax == 5.0 || ax == 6.0));
    bool collar_cream = (spx.y == 23.0 && (ax == 3.0 || ax == 4.0))
                     || (spx.y == 22.0 && (ax == 4.0 || ax == 5.0));
    if (collar_gold)  return vec4(gold * (h > 0.4 ? 1.15 : 0.85), 1.0);
    if (collar_cream) return vec4(cream * (h > 0.5 ? 1.05 : 0.88), 1.0);

    // ============================================================
    // CREAM SHIRT (V-neck visible in coat opening).
    // ============================================================
    bool shirt = (spx.y == 23.0 && ax <= 1.0)
              || (spx.y == 22.0 && ax <= 2.0)
              || (spx.y == 21.0 && ax <= 2.0)
              || (spx.y == 20.0 && ax <= 1.0)
              || (spx.y == 19.0 && ax == 0.0);
    if (shirt) {
        if (tone < 0.5) return vec4(cream * 0.72, 1.0);
        if (tone < 1.5) return vec4(cream,        1.0);
        return vec4(cream * 1.05, 1.0);
    }

    // ============================================================
    // COAT (teal main body).
    // ============================================================
    bool coat_body = spx.y >= 14.0 && spx.y <= 23.0 && ax <= 6.0;
    if (coat_body) {
        if (tone < 0.5) return vec4(coat * 0.60, 1.0);   // deep shadow side
        if (tone < 1.5) return vec4(coat,        1.0);   // base teal
        return vec4(coat * 1.30, 1.0);                    // lit highlight
    }

    // ============================================================
    // POUCH on right hip (brown rectangle).
    // ============================================================
    bool pouch = (spx.x >= 4.0 && spx.x <= 6.0) && (spx.y >= 8.0 && spx.y <= 13.0);
    if (pouch) {
        if (tone < 0.5) return vec4(belt * 0.60, 1.0);
        if (tone < 1.5) return vec4(belt,        1.0);
        return vec4(belt * 1.25, 1.0);
    }

    // ============================================================
    // BELT (brown band with gold square buckle).
    // ============================================================
    bool buckle = (spx.y == 13.0 || spx.y == 14.0) && (spx.x == -1.0 || spx.x == 0.0 || spx.x == 1.0);
    bool belt_band = spx.y == 13.0 && ax <= 6.0;
    if (buckle)    return vec4(gold * (h > 0.5 ? 1.15 : 0.80), 1.0);
    if (belt_band) return vec4(belt * (h > 0.5 ? 1.10 : 0.85), 1.0);

    // ============================================================
    // PANTS (navy, legs alternate when walking).
    // ============================================================
    bool legs_apart = (pose > 0.5 && frame > 0.5);
    bool pants;
    if (legs_apart) {
        pants = spx.y >= 6.0 && spx.y <= 12.0 &&
                ((spx.x >= -5.0 && spx.x <= -2.0) || (spx.x >= 2.0 && spx.x <= 5.0));
    } else {
        pants = spx.y >= 6.0 && spx.y <= 12.0 &&
                ((spx.x >= -4.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 4.0));
    }
    if (pants) {
        if (tone < 0.5) return vec4(navy * 0.60, 1.0);
        if (tone < 1.5) return vec4(navy,        1.0);
        return vec4(navy * 1.40, 1.0);   // navy lifts noticeably when lit
    }

    // ============================================================
    // BOOTS (brown with two-band cuff at top).
    // ============================================================
    bool boot_cuff_top, boot_cuff_band, boot_body;
    if (legs_apart) {
        boot_cuff_top  = spx.y == 5.0 && ((spx.x >= -6.0 && spx.x <= -2.0) || (spx.x >= 2.0 && spx.x <= 6.0));
        boot_cuff_band = spx.y == 4.0 && ((spx.x >= -6.0 && spx.x <= -2.0) || (spx.x >= 2.0 && spx.x <= 6.0));
        boot_body      = spx.y >= 0.0 && spx.y <= 3.0 && ((spx.x >= -6.0 && spx.x <= -2.0) || (spx.x >= 2.0 && spx.x <= 6.0));
    } else {
        boot_cuff_top  = spx.y == 5.0 && ((spx.x >= -5.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 5.0));
        boot_cuff_band = spx.y == 4.0 && ((spx.x >= -5.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 5.0));
        boot_body      = spx.y >= 0.0 && spx.y <= 3.0 && ((spx.x >= -5.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 5.0));
    }
    if (boot_cuff_top)  return vec4(belt * (h > 0.4 ? 1.10 : 0.85), 1.0);
    if (boot_cuff_band) return vec4(boot * 0.75, 1.0);
    if (boot_body) {
        if (tone < 0.5) return vec4(boot * 0.55, 1.0);
        if (tone < 1.5) return vec4(boot,        1.0);
        return vec4(boot * 1.30, 1.0);
    }

    return vec4(0.0);
}

// ----- NES-style WARRIOR sprite (Belmont-ish chunky pixel art) -----
// Side-profile walking stance.  frame: 0/1 leg alternation.  dir: facing.
// arm_up: raised front arm for grappling-hook / sky-point pose.
vec4 sampleWarrior(vec2 fragPos, vec2 anchor, float scale, float frame, float dir,
                   float arm_up,
                   vec3 tunic, vec3 outline, vec3 skin, vec3 head_band, vec3 boot) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -8.0 || spx.x > 9.0 || spx.y < -1.0 || spx.y > 28.0) return vec4(0.0);
    float ax = abs(spx.x);

    // ====== HEAD + HAIR (top, peaks like a hood) ======
    bool in_hair_top = (spx.y == 25.0 && spx.x >= -3.0 && spx.x <= 1.0)
                    || (spx.y == 24.0 && spx.x >= -4.0 && spx.x <= 2.0)
                    || (spx.y == 23.0 && spx.x >= -5.0 && spx.x <= 3.0);
    bool in_headband = (spx.y == 22.0 && spx.x >= -5.0 && spx.x <= 3.0);
    bool in_face = (spx.y == 21.0 && spx.x >= -5.0 && spx.x <= 3.0)
                || (spx.y == 20.0 && spx.x >= -5.0 && spx.x <= 3.0)
                || (spx.y == 19.0 && spx.x >= -5.0 && spx.x <= 3.0)
                || (spx.y == 18.0 && spx.x >= -4.0 && spx.x <= 2.0);
    bool in_eye  = (spx.x == 0.0 && spx.y == 20.0);
    bool in_hair_back = (spx.y == 20.0 && spx.x == 3.0)
                     || (spx.y == 19.0 && spx.x == 3.0)
                     || (spx.y == 18.0 && spx.x == 2.0);

    // ====== NECK + SHOULDERS ======
    bool in_neck      = spx.y == 17.0 && spx.x >= -3.0 && spx.x <= 1.0;
    bool in_shoulders = spx.y == 16.0 && spx.x >= -5.0 && spx.x <= 4.0;

    // ====== TORSO (chunky tunic) ======
    bool in_torso = (spx.y >= 10.0 && spx.y <= 15.0) && spx.x >= -5.0 && spx.x <= 4.0;
    // Visible skin patches at the chest opening (cream/coral V-cut).
    bool chest_skin = (spx.y == 14.0 && (spx.x == -1.0 || spx.x == 0.0))
                   || (spx.y == 13.0 && spx.x == 0.0);
    // Front arm hangs forward during walking, then reaches upward for the hook.
    bool arm_up_pose = arm_up > 0.5;
    bool arm_front_skin = arm_up_pose
        ? ((spx.x == -6.0 && spx.y >= 17.0 && spx.y <= 19.0)
        || (spx.x == -7.0 && spx.y >= 20.0 && spx.y <= 23.0)
        || (spx.y == 24.0 && spx.x >= -7.0 && spx.x <= -6.0))
        : ((spx.y == 13.0 && spx.x == -5.0)
        || (spx.y == 12.0 && spx.x == -5.0)
        || (spx.y == 11.0 && spx.x == -5.0));
    bool arm_up_sleeve = arm_up_pose
                      && ((spx.y == 16.0 && spx.x >= -6.0 && spx.x <= -5.0)
                       || (spx.y == 17.0 && spx.x == -6.0));
    // Back arm hangs behind.
    bool arm_back_skin = (spx.y == 13.0 && spx.x == 4.0)
                      || (spx.y == 12.0 && spx.x == 4.0);

    // ====== WAIST / HIPS ======
    bool in_waist = spx.y == 9.0 && spx.x >= -4.0 && spx.x <= 3.0;

    // ====== LEGS (split, alternating walk frames) ======
    bool in_leg_F, in_leg_B;
    if (frame < 0.5) {
        // Stride: front leg forward, back leg back.
        in_leg_F = (spx.y >= 2.0 && spx.y <= 8.0) && (spx.x >= -5.0 && spx.x <= -3.0);
        in_leg_B = (spx.y >= 2.0 && spx.y <= 8.0) && (spx.x >= 1.0 && spx.x <= 3.0);
    } else {
        // Step: legs closer together.
        in_leg_F = (spx.y >= 2.0 && spx.y <= 8.0) && (spx.x >= -4.0 && spx.x <= -2.0);
        in_leg_B = (spx.y >= 2.0 && spx.y <= 8.0) && (spx.x >= 0.0 && spx.x <= 2.0);
    }
    // Knee skin patches (front of each leg).
    bool knee_F = ((frame < 0.5 && spx.y == 5.0 && spx.x == -4.0)
                || (frame >= 0.5 && spx.y == 5.0 && spx.x == -3.0));
    bool knee_B = ((frame < 0.5 && spx.y == 5.0 && spx.x == 2.0)
                || (frame >= 0.5 && spx.y == 5.0 && spx.x == 1.0));

    // ====== BOOTS (wider than legs at the very bottom) ======
    bool in_boot_F, in_boot_B;
    if (frame < 0.5) {
        in_boot_F = (spx.y >= 0.0 && spx.y <= 1.0) && (spx.x >= -6.0 && spx.x <= -2.0);
        in_boot_B = (spx.y >= 0.0 && spx.y <= 1.0) && (spx.x >= 0.0 && spx.x <= 4.0);
    } else {
        in_boot_F = (spx.y >= 0.0 && spx.y <= 1.0) && (spx.x >= -5.0 && spx.x <= -1.0);
        in_boot_B = (spx.y >= 0.0 && spx.y <= 1.0) && (spx.x >= -1.0 && spx.x <= 3.0);
    }

    // ====== LAYER ORDER ======
    if (in_eye)               return vec4(outline, 1.0);
    if (chest_skin || arm_front_skin || arm_back_skin || knee_F || knee_B)
                              return vec4(skin, 1.0);
    if (in_face)              return vec4(skin, 1.0);
    if (in_hair_back)         return vec4(outline, 1.0);
    if (in_headband)          return vec4(head_band, 1.0);
    if (in_hair_top)          return vec4(outline, 1.0);
    if (in_neck)              return vec4(skin, 1.0);
    if (arm_up_sleeve)        return vec4(tunic, 1.0);
    if (in_shoulders)         return vec4(tunic, 1.0);
    if (in_torso)             return vec4(tunic, 1.0);
    if (in_waist)             return vec4(tunic, 1.0);
    if (in_leg_F || in_leg_B) return vec4(tunic, 1.0);
    if (in_boot_F || in_boot_B) return vec4(boot, 1.0);
    return vec4(0.0);
}

// ----- Squirrel sprite (side-profile, big bushy tail curling up) -----
// pose: 0=walking, 1=paused/look.  frame: 0/1 walk-cycle alternation.
vec4 sampleSquirrel(vec2 fragPos, vec2 anchor, float scale, float pose, float frame, float dir,
                    vec3 body, vec3 outline, vec3 belly, vec3 tail_dark, vec3 nose) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -9.0 || spx.x > 12.0 || spx.y < -1.0 || spx.y > 20.0) return vec4(0.0);

    // ============================================================
    // EARS (2x2 each on top of the head)
    // ============================================================
    bool in_ear_L = (spx.y == 14.0 || spx.y == 15.0)
                 && (spx.x == -5.0 || spx.x == -4.0);
    bool in_ear_R = (spx.y == 14.0 || spx.y == 15.0)
                 && (spx.x == -2.0 || spx.x == -1.0);
    bool ear_pink_L = (spx.y == 14.0 && spx.x == -4.0);
    bool ear_pink_R = (spx.y == 14.0 && spx.x == -1.0);

    // ============================================================
    // HEAD: 5 wide x 4 tall block on the left
    // ============================================================
    bool in_head = (spx.y >= 10.0 && spx.y <= 13.0) && (spx.x >= -6.0 && spx.x <= -1.0);

    // ============================================================
    // EYE: single dot
    // ============================================================
    bool eye = (spx.x == -3.0 && spx.y == 12.0);

    // ============================================================
    // NOSE: pink at the front of the face
    // ============================================================
    bool in_nose = (spx.x == -7.0 && spx.y == 11.0);

    // ============================================================
    // BODY: round, slightly to the right of the head
    // ============================================================
    vec2 to_body = spx - vec2(1.0, 6.0);
    float bd2 = len2(vec2(to_body.x / 4.0, to_body.y / 3.0));
    bool in_body  = bd2 <= 1.0;
    bool out_body = bd2 > 1.0 && bd2 <= 1.3456 && !in_head;

    // ============================================================
    // BELLY (lighter patch on front-bottom of body)
    // ============================================================
    bool in_belly = (spx.y >= 4.0 && spx.y <= 7.0) && (spx.x >= -2.0 && spx.x <= 1.0);

    // ============================================================
    // HEAD OUTLINE (1-pixel ring around head + body junction)
    // ============================================================
    bool out_head = !in_head && (
           (spx.y == 9.0  && spx.x >= -6.0 && spx.x <= -1.0)
        || (spx.y == 14.0 && spx.x >= -6.0 && spx.x <= -1.0)
        || (spx.x == -7.0 && spx.y >= 10.0 && spx.y <= 13.0)
        || (spx.x ==  0.0 && spx.y >= 10.0 && spx.y <= 13.0)
    );

    // ============================================================
    // LEGS / PAWS (4 small, frame alternation)
    // ============================================================
    bool in_legs;
    if (frame < 0.5) {
        in_legs = (spx.y >= 0.0 && spx.y <= 3.0) &&
                  (spx.x == -2.0 || spx.x == 0.0 || spx.x == 3.0 || spx.x == 5.0);
    } else {
        in_legs = (spx.y >= 1.0 && spx.y <= 3.0) &&
                  (spx.x == -2.0 || spx.x == 0.0 || spx.x == 3.0 || spx.x == 5.0)
               || (spx.y == 0.0 && (spx.x == -2.0 || spx.x == 5.0));
    }

    // ============================================================
    // BIG BUSHY TAIL: thick column curling up the right side and
    //   over toward the head, classic squirrel silhouette.
    // ============================================================
    bool in_tail = false;
    // Lower attachment to rear of body (thick base).
    if (spx.y >= 4.0 && spx.y <= 8.0 && (spx.x == 5.0 || spx.x == 6.0)) in_tail = true;
    // Mid section rising upward (wider).
    if (spx.y >= 8.0 && spx.y <= 11.0 && (spx.x == 6.0 || spx.x == 7.0 || spx.x == 8.0)) in_tail = true;
    // Top section continues up.
    if (spx.y >= 12.0 && spx.y <= 15.0 && (spx.x == 7.0 || spx.x == 8.0 || spx.x == 9.0)) in_tail = true;
    // Curl back over the body toward the head.
    if (spx.y == 17.0 && (spx.x == 5.0 || spx.x == 6.0 || spx.x == 7.0 || spx.x == 8.0)) in_tail = true;
    if (spx.y == 16.0 && (spx.x == 5.0 || spx.x == 6.0 || spx.x == 7.0 || spx.x == 8.0 || spx.x == 9.0)) in_tail = true;
    // Tail tip / hook ending near the back of the head.
    if (spx.y == 15.0 && (spx.x == 4.0 || spx.x == 5.0)) in_tail = true;
    if (spx.y == 14.0 && spx.x == 4.0) in_tail = true;

    // Tail texture: darker stripe every 3rd pixel diagonally.
    bool tail_shadow = in_tail && mod(spx.y + spx.x, 3.0) < 1.0;

    // Tail outline: 1px ring outside the tail mass.
    bool out_tail =
        !in_tail
     && (   (spx.y == 3.0 && (spx.x == 5.0 || spx.x == 6.0))
         || (spx.y == 18.0 && (spx.x >= 5.0 && spx.x <= 8.0))
         || (spx.x == 4.0 && spx.y >= 5.0 && spx.y <= 13.0)
         || (spx.x == 9.0 && spx.y >= 12.0 && spx.y <= 16.0)
         || (spx.x == 10.0 && spx.y >= 13.0 && spx.y <= 15.0));

    // ============================================================
    // LAYER ORDER
    // ============================================================
    if (eye)                       return vec4(outline, 1.0);
    if (in_nose)                   return vec4(nose, 1.0);
    if (ear_pink_L || ear_pink_R)  return vec4(nose, 1.0);
    if (in_ear_L || in_ear_R)      return vec4(body, 1.0);
    if (in_belly)                  return vec4(belly, 1.0);
    if (in_legs)                   return vec4(body, 1.0);
    if (out_head || out_body)      return vec4(outline, 1.0);
    if (in_head)                   return vec4(body, 1.0);
    if (tail_shadow)               return vec4(tail_dark, 1.0);
    if (out_tail)                  return vec4(outline, 1.0);
    if (in_tail)                   return vec4(body, 1.0);
    if (in_body)                   return vec4(body, 1.0);
    return vec4(0.0);
}

// ----- Pixel-art butterfly (9x9 sprite, 4-wing flap with body + antennae) -----
vec4 sampleButterfly(vec2 fragPos, vec2 pos, float scale, vec3 wing_col,
                    float flap_speed, float flap_phase) {
    vec2 lp = (fragPos - pos) / scale;
    vec2 d = floor(lp + 0.5);
    if (abs(d.x) > 5.0 || abs(d.y) > 5.0) return vec4(0.0);
    float frame = mod(floor(iTime * flap_speed + flap_phase), 2.0);
    bool wing = false;
    bool body = false;
    bool antenna = false;
    if (frame < 0.5) {
        // ----- Wings RAISED (vertical-leaning) -----
        // Top wings (upper pair) sweep up and inward.
        wing = (d.y == 4.0 && (d.x == -2.0 || d.x == 2.0))
            || (d.y == 3.0 && (abs(d.x) == 2.0 || abs(d.x) == 3.0))
            || (d.y == 2.0 && abs(d.x) <= 3.0 && abs(d.x) >= 1.0)
            || (d.y == 1.0 && abs(d.x) <= 2.0 && abs(d.x) >= 1.0);
        // Bottom wings (smaller, narrower).
        wing = wing
            || (d.y == -1.0 && (d.x == -2.0 || d.x == 2.0))
            || (d.y == -2.0 && (d.x == -1.0 || d.x == 1.0));
        // Body (vertical 5px).
        body = (d.x == 0.0 && d.y >= -3.0 && d.y <= 2.0);
        // Antennae curl outward from top.
        antenna = (d.y == 4.0 && (d.x == -1.0 || d.x == 1.0))
               || (d.y == 5.0 && (d.x == -1.0 || d.x == 1.0));
    } else {
        // ----- Wings OPEN / SPREAD (horizontal silhouette) -----
        // Top wings spread wide and high.
        wing = (d.y == 2.0 && abs(d.x) <= 4.0 && abs(d.x) >= 1.0)
            || (d.y == 3.0 && (abs(d.x) == 3.0 || abs(d.x) == 4.0))
            || (d.y == 1.0 && abs(d.x) <= 4.0 && abs(d.x) >= 1.0);
        // Bottom wings spread.
        wing = wing
            || (d.y == -1.0 && abs(d.x) <= 3.0 && abs(d.x) >= 1.0)
            || (d.y == -2.0 && (abs(d.x) == 2.0 || abs(d.x) == 3.0))
            || (d.y == 0.0 && abs(d.x) <= 4.0 && abs(d.x) >= 1.0);
        body = (d.x == 0.0 && d.y >= -3.0 && d.y <= 2.0);
        antenna = (d.y == 4.0 && (d.x == -1.0 || d.x == 1.0));
    }
    if (antenna) return vec4(wing_col * 0.5, 1.0);
    if (body)    return vec4(wing_col * 0.4, 1.0);
    if (wing)    return vec4(wing_col, 1.0);
    return vec4(0.0);
}

// ----- Pine tree sprite (Christmas-tree triangles + trunk) -----
vec4 samplePineTree(vec2 fragPos, vec2 anchor, float scale,
                    vec3 needle_light, vec3 needle_dark, vec3 trunk_col, vec3 outline) {
    vec2 lp = (fragPos - anchor) / scale;
    vec2 spx = floor(lp + 0.5);
    if (abs(spx.x) > 7.0 || spx.y < -1.0 || spx.y > 18.0) return vec4(0.0);

    float ax = abs(spx.x);
    // Tree built as 3 stacked triangles + trunk.
    bool layer_top = (spx.y == 17.0 && ax == 0.0)
                  || (spx.y == 16.0 && ax <= 1.0)
                  || (spx.y == 15.0 && ax <= 2.0);
    bool layer_mid = (spx.y == 14.0 && ax <= 1.0)
                  || (spx.y == 13.0 && ax <= 2.0)
                  || (spx.y == 12.0 && ax <= 3.0)
                  || (spx.y == 11.0 && ax <= 4.0);
    bool layer_bot = (spx.y == 10.0 && ax <= 2.0)
                  || (spx.y ==  9.0 && ax <= 3.0)
                  || (spx.y ==  8.0 && ax <= 4.0)
                  || (spx.y ==  7.0 && ax <= 5.0)
                  || (spx.y ==  6.0 && ax <= 6.0);
    bool trunk = (spx.y >= 0.0 && spx.y <= 5.0 && ax <= 1.0);
    bool ground_shadow = false;   // trunk now extends to terminal bottom

    // Highlights: lit side (top-right of each layer) brighter, shadow on bottom-left.
    bool lit = layer_top || layer_mid || layer_bot;
    bool lit_side = lit && spx.x >= 1.0 && (
        (layer_top && spx.y >= 16.0) ||
        (layer_mid && spx.y >= 13.0) ||
        (layer_bot && spx.y >=  9.0)
    );

    if (ground_shadow) return vec4(outline, 1.0);
    if (trunk)         return vec4(trunk_col, 1.0);
    if (lit_side)      return vec4(needle_light, 1.0);
    if (layer_top || layer_mid || layer_bot) return vec4(needle_dark, 1.0);
    return vec4(0.0);
}

// ----- Bunny sprite (side-profile, sitting/hopping/looking) -----
// pose: 0=sitting/normal, 1=hopping (body lifts), 2=looking up (ears alert).
// frame: 0/1 for nose/ear twitch.  dir: facing direction.
vec4 sampleBunny(vec2 fragPos, vec2 anchor, float scale, float pose, float frame, float dir,
                 vec3 body, vec3 outline, vec3 pink, vec3 nose) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -6.0 || spx.x > 9.0 || spx.y < -1.0 || spx.y > 17.0) return vec4(0.0);

    // Ear tilt: hopping = ears swept back, looking = ears straight up.
    float ear_tilt = (pose > 1.5) ? 0.0 : ((pose > 0.5) ? -1.0 : 0.0);

    // ===== EARS (two tall ears on top of head) =====
    // Each ear: 1px wide, 4-5px tall, with pink inner pixel.
    float earL_x = -3.0 + ear_tilt;
    float earR_x = -1.0 + ear_tilt;
    bool in_earL = spx.x == earL_x && (spx.y >= 11.0 && spx.y <= 15.0);
    bool in_earR = spx.x == earR_x && (spx.y >= 11.0 && spx.y <= 15.0);
    // Inner pink (middle 2 pixels of each ear).
    bool ear_pink_L = spx.x == earL_x && (spx.y == 12.0 || spx.y == 13.0);
    bool ear_pink_R = spx.x == earR_x && (spx.y == 12.0 || spx.y == 13.0);

    // ===== HEAD (small ellipse on left side of body) =====
    vec2 to_head = spx - vec2(-1.0, 9.0);
    float hd2 = len2(vec2(to_head.x / 2.5, to_head.y / 2.0));
    bool in_head  = hd2 <= 1.0;
    bool out_head = hd2 > 1.0 && hd2 <= 1.69;

    // ===== EYE (single dot) =====
    bool eye = (spx.x == -1.0 && spx.y == 9.0);

    // ===== NOSE (tiny pink triangle on front of face) =====
    bool in_nose = (spx.x == -3.0 && spx.y == 8.0);

    // ===== BODY (oval, larger than head, extends to right) =====
    vec2 to_body = spx - vec2(2.5, 4.0);
    float bd2 = len2(vec2(to_body.x / 4.5, to_body.y / 2.8));
    bool in_body  = bd2 <= 1.0;
    bool out_body = bd2 > 1.0 && bd2 <= 1.3924 && !in_head;

    // ===== TAIL PUFF (small cloud at rear-right) =====
    bool in_tail = (spx.y >= 4.0 && spx.y <= 6.0)
                && (spx.x == 7.0 || (spx.x == 8.0 && spx.y == 5.0));

    // ===== LEGS / PAWS =====
    bool in_legs = false;
    if (pose < 0.5) {
        // Sitting: 4 small legs at ground level.
        in_legs = (spx.y >= 0.0 && spx.y <= 1.0) &&
                  (spx.x == -1.0 || spx.x == 0.0 || spx.x == 3.0 || spx.x == 5.0);
    } else if (pose < 1.5) {
        // Hopping: back legs stretched downward + backward.
        in_legs = (spx.y >= 0.0 && spx.y <= 1.0 &&
                   (spx.x == 5.0 || spx.x == 6.0 || spx.x == 7.0))
               || (spx.y == 1.0 && (spx.x == -1.0 || spx.x == 0.0));
    } else {
        // Looking up: legs tucked under body.
        in_legs = (spx.y == 1.0) &&
                  (spx.x == -1.0 || spx.x == 0.0 || spx.x == 3.0 || spx.x == 5.0);
    }

    // ===== LAYER ORDER =====
    if (eye)                  return vec4(outline, 1.0);
    if (in_nose)              return vec4(nose, 1.0);
    if (ear_pink_L || ear_pink_R) return vec4(pink, 1.0);
    if (in_earL || in_earR)   return vec4(body, 1.0);
    if (in_tail)              return vec4(body, 1.0);
    if (in_legs)              return vec4(body, 1.0);
    if (out_head || out_body) return vec4(outline, 1.0);
    if (in_head || in_body)   return vec4(body, 1.0);
    return vec4(0.0);
}

// ----- Deer sprite (side-profile) -----
// Single deer, can be mom (with_antlers=true) or fawn (with_antlers=false).
// head_down: 1.0 if grazing (head dipped to ground), 0.0 if walking/standing.
vec4 sampleDeer(vec2 fragPos, vec2 anchor, float scale, float frame, float dir,
                bool with_antlers, float head_down,
                vec3 body, vec3 outline, vec3 belly, vec3 antler) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -10.0 || spx.x > 12.0 || spx.y < -1.0 || spx.y > 18.0) return vec4(0.0);

    // ===== HEAD (left side of sprite, drops when grazing) =====
    float head_dy = head_down * -4.0;
    vec2 head_c = vec2(-6.0, 11.0 + head_dy);
    vec2 to_head = spx - head_c;
    float hd2 = len2(vec2(to_head.x / 2.5, to_head.y / 2.5));
    bool in_head  = hd2 <= 1.0;
    bool out_head = hd2 > 1.0 && hd2 <= 1.5625;

    // ===== EARS (small triangles on top of head, also drop with head) =====
    bool in_ear_L = (spx.x == -7.0 && spx.y == (13.0 + head_dy))
                 || (spx.x == -7.0 && spx.y == (14.0 + head_dy));
    bool in_ear_R = (spx.x == -5.0 && spx.y == (13.0 + head_dy))
                 || (spx.x == -5.0 && spx.y == (14.0 + head_dy));

    // ===== EYE (small dot on the head) =====
    bool eye = spx.x == -5.0 && spx.y == (11.0 + head_dy);

    // ===== ANTLERS (only on mom, small forked shape) =====
    bool in_antler = false;
    if (with_antlers) {
        in_antler = (spx.y == (15.0 + head_dy) && (spx.x == -7.0 || spx.x == -5.0))
                 || (spx.y == (16.0 + head_dy) && (spx.x == -7.0 || spx.x == -5.0))
                 || (spx.y == (17.0 + head_dy) && (spx.x == -8.0 || spx.x == -5.0 || spx.x == -4.0));
    }

    // ===== NECK (bridges head to body) =====
    bool in_neck = (spx.y >= 8.0 && spx.y <= 10.0) && (spx.x >= -4.0 && spx.x <= -2.0);

    // ===== BODY (oval on right side) =====
    vec2 to_bod = spx - vec2(3.0, 7.0);
    float bd2 = len2(vec2(to_bod.x / 5.5, to_bod.y / 3.5));
    bool in_body  = bd2 <= 1.0;
    bool out_body = bd2 > 1.0 && bd2 <= 1.3456;

    // ===== BELLY PATCH (lighter underside) =====
    bool in_belly = (spx.y >= 4.0 && spx.y <= 5.0) && (spx.x >= -1.0 && spx.x <= 6.0);

    // ===== SPOTS (white-ish dots on the back) =====
    bool in_spot = (spx.x == 1.0 && spx.y == 8.0)
                || (spx.x == 4.0 && spx.y == 9.0)
                || (spx.x == 6.0 && spx.y == 7.0);

    // ===== TAIL (small puff at rear) =====
    bool in_tail = (spx.x == 8.0 && spx.y == 7.0)
                || (spx.x == 9.0 && spx.y == 7.0);

    // ===== LEGS (4 thin legs, frame alternation) =====
    bool in_legs;
    if (frame < 0.5) {
        in_legs = (spx.y >= 0.0 && spx.y <= 3.0 &&
                  (spx.x == -2.0 || spx.x == 0.0 || spx.x == 5.0 || spx.x == 7.0));
    } else {
        in_legs = (spx.y >= 1.0 && spx.y <= 3.0 &&
                  (spx.x == -2.0 || spx.x == 0.0 || spx.x == 5.0 || spx.x == 7.0))
               || (spx.y == 0.0 &&
                  (spx.x == -2.0 || spx.x == 7.0));
    }

    // ===== LAYER ORDER =====
    if (eye)                  return vec4(outline, 1.0);
    if (in_antler)            return vec4(antler, 1.0);
    if (in_ear_L || in_ear_R) return vec4(body, 1.0);
    if (out_head || out_body) return vec4(outline, 1.0);
    if (in_legs)              return vec4(body, 1.0);
    if (in_tail)              return vec4(belly, 1.0);
    if (in_spot)              return vec4(belly, 1.0);
    if (in_belly)             return vec4(belly, 1.0);
    if (in_head || in_body || in_neck) return vec4(body, 1.0);
    return vec4(0.0);
}

// ----- WSB-guy sprite -----
// Confident dude with sunglasses, hair, polo, belt, finger guns.
// pose: 0=walking, 1=paused (look at viewer), 2=finger guns.
// frame: 0/1 for walk-cycle alternation.  dir: facing direction.
vec4 sampleWSB(vec2 fragPos, vec2 anchor, float scale, float pose, float frame, float dir,
               vec3 jacket, vec3 outline, vec3 skin, vec3 hair_col,
               vec3 pants_col, vec3 shoes_col, vec3 belt_brown, vec3 gold) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);
    if (spx.x < -8.0 || spx.x > 9.0 || spx.y < -1.0 || spx.y > 24.0) return vec4(0.0);
    float ax = abs(spx.x);

    // ============================================================
    // HEAD + HAIR
    // ============================================================
    bool in_hair = (spx.y == 22.0 && ax <= 2.0)
                || (spx.y == 21.0 && ax <= 3.0)
                || (spx.y == 20.0 && ax <= 4.0)
                || (spx.y == 19.0 && (ax == 3.0 || ax == 4.0));
    bool in_face = (spx.y == 19.0 && ax <= 2.0)
                || (spx.y == 18.0 && ax <= 3.0)
                || (spx.y == 16.0 && ax <= 3.0)
                || (spx.y == 15.0 && ax <= 2.0);
    bool in_sunglasses = (spx.y == 17.0 && spx.x >= -4.0 && spx.x <= 3.0);
    bool in_smirk = (pose > 0.5)
        ? ((spx.y == 16.0 && (spx.x == 0.0 || spx.x == 1.0 || spx.x == 2.0)))
        : (spx.y == 16.0 && (spx.x == 0.0 || spx.x == 1.0));

    // ============================================================
    // BODY (polo / jacket)
    // ============================================================
    bool in_neck      = spx.y == 14.0 && ax <= 1.0;
    bool in_shoulders = spx.y == 13.0 && ax <= 5.0;
    bool in_torso     = spx.y >= 9.0 && spx.y <= 12.0 && ax <= 4.0;
    bool in_collar    = spx.y == 12.0 && (spx.x == -1.0 || spx.x == 0.0 || spx.x == 1.0);
    bool in_buckle    = spx.y == 8.0 && (spx.x == 0.0 || spx.x == 1.0);
    bool in_belt      = spx.y == 8.0 && ax <= 4.0 && !in_buckle;

    // ============================================================
    // PANTS / LEGS
    // ============================================================
    bool in_pants = false;
    bool legs_split = (pose < 0.5 && frame > 0.5);
    if (legs_split) {
        in_pants = (spx.y >= 4.0 && spx.y <= 7.0)
                && ((spx.x >= -4.0 && spx.x <= -2.0) || (spx.x >= 1.0 && spx.x <= 3.0));
    } else {
        in_pants = (spx.y >= 4.0 && spx.y <= 7.0)
                && ((spx.x >= -3.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 2.0));
    }

    // ============================================================
    // SHOES
    // ============================================================
    bool in_shoes = false;
    if (legs_split) {
        in_shoes = (spx.y >= 0.0 && spx.y <= 3.0)
                && ((spx.x >= -5.0 && spx.x <= -2.0) || (spx.x >= 1.0 && spx.x <= 4.0));
    } else {
        in_shoes = (spx.y >= 0.0 && spx.y <= 3.0)
                && ((spx.x >= -4.0 && spx.x <= -1.0) || (spx.x >= 0.0 && spx.x <= 3.0));
    }

    // ============================================================
    // ARMS
    // ============================================================
    bool in_left_arm   = false;
    bool in_right_arm  = false;
    bool in_finger_gun = false;
    if (pose > 1.5) {
        // FINGER GUN pose: right arm extended out + hand making L.
        in_left_arm  = (spx.y >= 9.0 && spx.y <= 12.0) && spx.x == -5.0;
        in_right_arm = (spx.y == 13.0 || spx.y == 12.0) && (spx.x == 5.0 || spx.x == 6.0);
        // L-shaped hand at end of extended arm.
        in_finger_gun = (spx.y == 13.0 && (spx.x == 7.0 || spx.x == 8.0))
                     || (spx.y == 12.0 && spx.x == 7.0)
                     || (spx.y == 11.0 && spx.x == 7.0);
    } else {
        in_left_arm  = (spx.y >= 9.0 && spx.y <= 12.0) && spx.x == -5.0;
        in_right_arm = (spx.y >= 9.0 && spx.y <= 12.0) && spx.x == 5.0;
    }

    // ============================================================
    // DRAW (front -> back early returns)
    // ============================================================
    if (in_finger_gun)  return vec4(skin, 1.0);
    if (in_right_arm)   return vec4(jacket, 1.0);
    if (in_left_arm)    return vec4(jacket, 1.0);
    if (in_smirk)       return vec4(outline, 1.0);
    if (in_sunglasses)  return vec4(outline, 1.0);
    if (in_hair)        return vec4(hair_col, 1.0);
    if (in_face)        return vec4(skin, 1.0);
    if (in_neck)        return vec4(skin, 1.0);
    if (in_collar)      return vec4(jacket * 1.5, 1.0);
    if (in_buckle)      return vec4(gold, 1.0);
    if (in_belt)        return vec4(belt_brown, 1.0);
    if (in_shoulders)   return vec4(jacket, 1.0);
    if (in_torso)       return vec4(jacket, 1.0);
    if (in_pants)       return vec4(pants_col, 1.0);
    if (in_shoes)       return vec4(shoes_col, 1.0);
    return vec4(0.0);
}

// ----- Rocketship sprite -----
// Vertical rocket with nose cone, body, window, fins, animated flame + smoke.
// phase: 0=idle grumble, 1=pre-launch shake, 2=ascending.
// flame_len: length of flame trail (varies with phase).
vec4 sampleRocket(vec2 fragPos, vec2 anchor, float scale, float phase, float flame_len,
                  vec3 body, vec3 outline, vec3 nose_col, vec3 fin_col, vec3 window_col,
                  vec3 flame1, vec3 flame2, vec3 flame3, vec3 smoke_col) {
    vec2 lp = (fragPos - anchor) / scale;
    vec2 spx = floor(lp + 0.5);
    if (abs(spx.x) > 12.0 || spx.y < -28.0 || spx.y > 25.0) return vec4(0.0);
    float ax = abs(spx.x);

    // ===== NOSE CONE (red, triangle on top) =====
    bool in_nose = (spx.y == 22.0 && spx.x == 0.0)
                || (spx.y == 21.0 && ax <= 1.0)
                || (spx.y == 20.0 && ax <= 2.0)
                || (spx.y == 19.0 && ax <= 3.0);
    bool nose_outline = (spx.y == 22.0 && ax == 1.0)
                     || (spx.y == 21.0 && ax == 2.0)
                     || (spx.y == 20.0 && ax == 3.0)
                     || (spx.y == 19.0 && ax == 4.0);

    // ===== BODY (white/silver cylinder) =====
    bool in_body = spx.y >= 8.0 && spx.y <= 18.0 && ax <= 3.0;
    bool body_outline = (spx.y >= 8.0 && spx.y <= 18.0 && ax == 4.0)
                     || (spx.y == 7.0 && ax <= 3.0);

    // ===== WINDOW (cyan porthole) =====
    bool window_dot   = (spx.y == 14.0 || spx.y == 13.0) && (spx.x == -1.0 || spx.x == 0.0);
    bool window_ring  = (spx.y == 15.0 && ax <= 1.0)
                     || (spx.y == 12.0 && ax <= 1.0)
                     || (spx.y == 13.0 && (spx.x == -2.0 || spx.x == 1.0))
                     || (spx.y == 14.0 && (spx.x == -2.0 || spx.x == 1.0));

    // ===== ACCENT STRIPE across body =====
    bool stripe = spx.y == 11.0 && ax <= 3.0;

    // ===== FINS (red triangles at bottom corners) =====
    bool in_fin_L = (spx.y == 7.0 && spx.x >= -5.0 && spx.x <= -4.0)
                 || (spx.y == 6.0 && spx.x >= -6.0 && spx.x <= -4.0)
                 || (spx.y == 5.0 && spx.x >= -7.0 && spx.x <= -4.0)
                 || (spx.y == 4.0 && spx.x >= -7.0 && spx.x <= -4.0);
    bool in_fin_R = (spx.y == 7.0 && spx.x >= 4.0 && spx.x <= 5.0)
                 || (spx.y == 6.0 && spx.x >= 4.0 && spx.x <= 6.0)
                 || (spx.y == 5.0 && spx.x >= 4.0 && spx.x <= 7.0)
                 || (spx.y == 4.0 && spx.x >= 4.0 && spx.x <= 7.0);

    // ===== FLAME (when phase > 0) =====
    bool in_flame_core = false;
    bool in_flame_mid  = false;
    bool in_flame_outer = false;
    if (phase > 0.5 && spx.y < 4.0 && flame_len > 0.5) {
        float ny = 4.0 - spx.y;     // depth into flame (positive going down)
        if (ny <= flame_len) {
            float taper = 1.0 - ny / flame_len;
            float width_outer = 3.5 * taper;
            // Hash flicker.
            float flick = hash11(floor(iTime * 14.0) * 7.0 + spx.x * 11.0 + ny * 13.0);
            float jitter = (flick - 0.5) * 1.5;
            float w_outer = max(width_outer + jitter, 0.5);
            float w_mid   = w_outer * 0.65;
            float w_core  = w_outer * 0.30;
            if (ax <= w_core)       in_flame_core = true;
            else if (ax <= w_mid)   in_flame_mid = true;
            else if (ax <= w_outer) in_flame_outer = true;
        }
    }

    // ===== SMOKE puffs (only during pre-launch + early ascent) =====
    bool in_smoke = false;
    if (phase > 0.5 && phase < 1.8) {
        for (int s = 0; s < 6; s++) {
            float fs = float(s);
            float dir = (fs < 3.0) ? -1.0 : 1.0;
            float lateral = 5.0 + hash11(fs * 3.7) * 4.0;
            float drift_t = mod(iTime * 1.2 + fs * 0.5, 3.0);
            vec2 puff = vec2(dir * (lateral + drift_t),
                             1.0 - drift_t * 1.2 + sin(iTime * 2.0 + fs) * 0.5);
            if (len2(spx - puff) <= 2.56) in_smoke = true;
        }
    }

    if (in_smoke)         return vec4(smoke_col, 1.0);
    if (in_flame_core)    return vec4(flame1, 1.0);
    if (in_flame_mid)     return vec4(flame2, 1.0);
    if (in_flame_outer)   return vec4(flame3, 1.0);
    if (window_dot)       return vec4(window_col, 1.0);
    if (window_ring)      return vec4(outline, 1.0);
    if (stripe)           return vec4(nose_col * 0.85, 1.0);
    if (nose_outline)     return vec4(outline, 1.0);
    if (in_nose)          return vec4(nose_col, 1.0);
    if (body_outline)     return vec4(outline, 1.0);
    if (in_body)          return vec4(body, 1.0);
    if (in_fin_L || in_fin_R) return vec4(fin_col, 1.0);
    return vec4(0.0);
}

// ----- Anthropic splat sprite -----
// Abstract 4-lobe rotating shape, drifts slowly across screen.
// No eyes/feet — pure brand shape.  Returns RGBA, alpha=0 outside.
vec4 sampleSplat(vec2 fragPos, vec2 center, float ang, vec3 body_col, vec3 outline_col) {
    vec2 to_p = fragPos - center;
    float r2 = len2(to_p);
    float a = atan(to_p.y, to_p.x) - ang;
    // 4-petal rosette: r boundary varies with angle (cos of 2x angle).
    float lobe = abs(cos(a * 2.0));
    float lobe_r = 22.0 + lobe * 26.0;
    if (r2 <= lobe_r * lobe_r) return vec4(body_col, 1.0);
    float outline_r = lobe_r + 3.0;
    if (r2 <= outline_r * outline_r) return vec4(outline_col, 1.0);
    return vec4(0.0);
}

// ----- Pixel-art cat sprite (Pusheen-ish: BIG round head, dot eyes, pink nose) -----
// pose: 0=sleeping, 1=wake/stretch, 2=walking, 3=climb-wall.
// frame: 0/1 walk-cycle alternation.  dir: +1/-1 facing.
vec4 sampleCat(vec2 fragPos, vec2 anchor, float scale, float pose, float frame, float dir,
               vec3 body, vec3 outline, vec3 paw_pink) {
    vec2 lp = (fragPos - anchor) / scale;
    lp.x *= dir;
    vec2 spx = floor(lp + 0.5);

    // -------- SLEEPING (curled chibi cat) --------
    if (pose < 0.5) {
        if (abs(spx.x) > 9.0 || spx.y < -1.0 || spx.y > 12.0) return vec4(0.0);

        // Body curled into low oval.
        vec2 to_body = spx - vec2(0.0, 3.0);
        float bd2 = len2(vec2(to_body.x / 7.0, to_body.y / 2.7));
        bool in_body  = bd2 <= 1.0;
        bool out_body = bd2 > 1.0 && bd2 <= 1.44;

        // ONE visible triangular ear on top-LEFT.
        bool in_ear_L = (spx.y == 6.0 && (spx.x == -5.0 || spx.x == -4.0))
                     || (spx.y == 7.0 && spx.x == -5.0);
        bool ear_pink_L = (spx.y == 6.0 && spx.x == -4.0);

        // Closed eye slit on the head side (left).
        bool eye_slit = (spx.y == 4.0 && (spx.x == -6.0 || spx.x == -5.0));

        // Tail wrapped around: x=4..8 at y=2, plus tip at y=4.
        bool in_tail = (spx.y == 2.0 && spx.x >= 4.0 && spx.x <= 8.0)
                    || (spx.x == 8.0 && spx.y == 3.0);

        // Z's drifting upward.
        float zoff = floor(mod(iTime * 1.3, 4.0));
        bool zee_p = false;
        for (float zi = 0.0; zi < 3.0; zi += 1.0) {
            if (spx.x == (-2.0 + zi) && spx.y == (8.0 + zi + zoff)) zee_p = true;
        }

        if (eye_slit)            return vec4(outline, 1.0);
        if (in_ear_L)            return vec4(outline, 1.0);
        if (ear_pink_L)          return vec4(paw_pink, 1.0);
        if (out_body)            return vec4(outline, 1.0);
        if (in_body || in_tail)  return vec4(body, 1.0);
        if (zee_p)               return vec4(0.85, 0.85, 0.96, 1.0);
        return vec4(0.0);
    }

    // -------- WAKE / STRETCH --------
    if (pose < 1.5) {
        float stretch = 1.0 + 0.25 * abs(sin(iTime * 3.5));
        lp.y /= stretch;
        spx = floor(lp + 0.5);
        pose = 2.0;
    }

    // -------- HEAD-ONLY chibi cat (front view, just the head) --------
    // Sprite extents: x in [-7, 7], y in [0, 14].
    bool closed_eyes = (pose > 2.0);
    if (abs(spx.x) > 8.0 || spx.y < -1.0 || spx.y > 17.0) return vec4(0.0);
    float ax = abs(spx.x);

    // ============================================================
    // HEAD: rounded square shape.
    // ============================================================
    bool in_head =
        (spx.y == 11.0 && ax <= 4.0)
     || (spx.y == 10.0 && ax <= 5.0)
     || (spx.y ==  9.0 && ax <= 6.0)
     || (spx.y ==  8.0 && ax <= 6.0)
     || (spx.y ==  7.0 && ax <= 6.0)
     || (spx.y ==  6.0 && ax <= 6.0)
     || (spx.y ==  5.0 && ax <= 6.0)
     || (spx.y ==  4.0 && ax <= 5.0)
     || (spx.y ==  3.0 && ax <= 4.0)
     || (spx.y ==  2.0 && ax <= 3.0);
    bool out_head =
        (spx.y == 11.0 && ax == 5.0)
     || (spx.y == 10.0 && ax == 6.0)
     || (spx.y ==  9.0 && ax == 7.0)
     || (spx.y ==  8.0 && ax == 7.0)
     || (spx.y ==  7.0 && ax == 7.0)
     || (spx.y ==  6.0 && ax == 7.0)
     || (spx.y ==  5.0 && ax == 7.0)
     || (spx.y ==  4.0 && ax == 6.0)
     || (spx.y ==  3.0 && ax == 5.0)
     || (spx.y ==  2.0 && ax == 4.0)
     || (spx.y ==  1.0 && ax <= 3.0)
     || (spx.y == 12.0 && ax <= 4.0);
    out_head = out_head && !in_head;

    // ============================================================
    // EARS: big triangles on each side of the top of the head.
    // ============================================================
    bool ear_L =
        (spx.y == 14.0 && spx.x == -5.0)
     || (spx.y == 13.0 && (spx.x == -6.0 || spx.x == -5.0 || spx.x == -4.0))
     || (spx.y == 12.0 && (spx.x == -6.0 || spx.x == -5.0 || spx.x == -4.0 || spx.x == -3.0));
    bool ear_R =
        (spx.y == 14.0 && spx.x == 5.0)
     || (spx.y == 13.0 && (spx.x == 6.0 || spx.x == 5.0 || spx.x == 4.0))
     || (spx.y == 12.0 && (spx.x == 6.0 || spx.x == 5.0 || spx.x == 4.0 || spx.x == 3.0));
    bool ear_pink_L = (spx.y == 13.0 && spx.x == -5.0)
                   || (spx.y == 12.0 && (spx.x == -5.0 || spx.x == -4.0));
    bool ear_pink_R = (spx.y == 13.0 && spx.x == 5.0)
                   || (spx.y == 12.0 && (spx.x == 5.0 || spx.x == 4.0));

    // ============================================================
    // FOREHEAD STRIPES: 3 short tabby marks (subtle).
    // ============================================================
    bool stripe = (spx.y == 11.0 || spx.y == 10.0)
               && (spx.x == -3.0 || spx.x == 0.0 || spx.x == 3.0);

    // ============================================================
    // EYES: SQUARE 2x2 black (open) or single-row slits (closed).
    // ============================================================
    bool in_eye_L = (spx.x == -3.0 || spx.x == -2.0)
                 && (spx.y == 7.0 || spx.y == 8.0);
    bool in_eye_R = (spx.x ==  3.0 || spx.x ==  2.0)
                 && (spx.y == 7.0 || spx.y == 8.0);
    bool eye_slit_L = closed_eyes && spx.y == 7.0 && (spx.x == -3.0 || spx.x == -2.0);
    bool eye_slit_R = closed_eyes && spx.y == 7.0 && (spx.x ==  3.0 || spx.x ==  2.0);

    // ============================================================
    // CHEEK BLUSH: pink oval on each cheek.
    // ============================================================
    bool blush_L = (spx.y == 6.0 && (spx.x == -5.0 || spx.x == -4.0));
    bool blush_R = (spx.y == 6.0 && (spx.x ==  5.0 || spx.x ==  4.0));

    // ============================================================
    // NOSE: small pink triangle.
    // ============================================================
    bool in_nose = (spx.y == 6.0 && (spx.x == 0.0 || spx.x == -1.0))
                || (spx.y == 5.0 && spx.x == 0.0);

    // ============================================================
    // MOUTH: tiny dark line below nose.
    // ============================================================
    bool in_mouth = (spx.y == 4.0 && (spx.x == -1.0 || spx.x == 1.0));

    // ============================================================
    // WHISKERS: 1-pixel marks extending outward from the cheeks.
    // ============================================================
    bool whisker_L = (spx.y == 7.0 && spx.x == -7.0)
                  || (spx.y == 6.0 && spx.x == -7.0)
                  || (spx.y == 5.0 && spx.x == -7.0);
    bool whisker_R = (spx.y == 7.0 && spx.x ==  7.0)
                  || (spx.y == 6.0 && spx.x ==  7.0)
                  || (spx.y == 5.0 && spx.x ==  7.0);

    // ============================================================
    // LAYER ORDER (front → back).
    // ============================================================
    if (eye_slit_L || eye_slit_R)               return vec4(outline, 1.0);
    if (!closed_eyes && (in_eye_L || in_eye_R)) return vec4(outline, 1.0);
    if (in_nose)                                return vec4(paw_pink, 1.0);
    if (in_mouth)                               return vec4(outline, 1.0);
    if (whisker_L || whisker_R)                 return vec4(outline, 1.0);
    if (blush_L || blush_R)                     return vec4(mix(paw_pink, vec3(1.0), 0.20), 1.0);
    if (stripe)                                 return vec4(mix(outline, body, 0.55), 1.0);
    if (ear_pink_L || ear_pink_R)               return vec4(paw_pink, 1.0);
    if (ear_L || ear_R)                         return vec4(body, 1.0);
    if (out_head)                               return vec4(outline, 1.0);
    if (in_head)                                return vec4(body, 1.0);
    return vec4(0.0);
}

// ----- Pixel-art tree sprite -----
// Anchor = bottom-center of trunk; scale = screen-px per sprite-px;
// sway_t = phase argument for slow canopy sway.
// Returns RGBA; alpha=0 means no tree pixel here.
vec4 sampleTree(vec2 fragPos, vec2 anchor, float scale, float sway_t) {
    float sway = sin(sway_t) * 1.0;
    vec2 lp_trunk = (fragPos - anchor) / scale;
    vec2 lp_canopy = vec2(lp_trunk.x - sway, lp_trunk.y);
    vec2 trunk_spx  = floor(lp_trunk + 0.5);
    vec2 canopy_spx = floor(lp_canopy + 0.5);

    // Canopy = union of 5 disks at varied radii.
    float d1 = len2(canopy_spx - vec2( 0.0, 14.0));
    float d2 = len2(canopy_spx - vec2(-4.0, 11.0));
    float d3 = len2(canopy_spx - vec2( 4.0, 11.0));
    float d4 = len2(canopy_spx - vec2(-2.0,  8.0));
    float d5 = len2(canopy_spx - vec2( 3.0,  8.0));
    bool in_canopy  = d1 <= 25.0 || d2 <= 20.25 || d3 <= 20.25 || d4 <= 12.25 || d5 <= 12.25;
    bool out_canopy = (d1 <= 33.64 || d2 <= 28.09 || d3 <= 28.09 || d4 <= 18.49 || d5 <= 18.49) && !in_canopy;

    bool in_trunk  = abs(trunk_spx.x) <= 1.0 && trunk_spx.y >= 0.0 && trunk_spx.y <= 6.0;
    bool out_trunk = abs(trunk_spx.x) <= 2.0 && trunk_spx.y >= -1.0 && trunk_spx.y <= 7.0 && !in_trunk;

    if (out_canopy || out_trunk) return vec4(0.06, 0.11, 0.06, 1.0);
    if (in_trunk)                return vec4(0.42, 0.27, 0.16, 1.0);
    if (in_canopy) {
        bool inner = d1 <= 9.0 || d2 <= 6.25 || d3 <= 6.25;
        return inner ? vec4(0.30, 0.66, 0.30, 1.0)
                     : vec4(0.18, 0.44, 0.18, 1.0);
    }
    return vec4(0.0);
}

// ----- Pixel-art hot air balloon -----
// Anchor = bottom-center of basket; scale = screen-px per sprite-px;
// c1/c2 = alternating stripe colors of the balloon body.
vec4 sampleBalloon(vec2 fragPos, vec2 anchor, float scale, vec3 c1, vec3 c2) {
    vec2 lp = (fragPos - anchor) / scale;
    vec2 lpx = floor(lp + 0.5);
    float body_d2 = len2(lpx - vec2(0.0, 9.0));
    bool in_body      = body_d2 <= 20.25 && lpx.y >= 4.0;
    bool out_body     = body_d2 > 20.25 && body_d2 <= 28.09 && lpx.y >= 4.0;
    bool in_taper     = abs(lpx.x) <= 1.0 && lpx.y >= 2.0 && lpx.y <= 4.0;
    bool in_basket    = abs(lpx.x) <= 2.0 && lpx.y >= 0.0 && lpx.y <= 1.5;
    bool out_basket   = (abs(lpx.x) == 3.0 && lpx.y >= 0.0 && lpx.y <= 1.5)
                     || (abs(lpx.x) <= 3.0 && (lpx.y == -0.5 || lpx.y == 2.0));
    out_basket = out_basket && !in_basket;

    vec3 dark = vec3(0.20, 0.10, 0.18);
    if (out_body || out_basket) return vec4(dark, 1.0);
    if (in_body) {
        float band = mod(lpx.y - 4.0, 2.0);
        return (band < 1.0) ? vec4(c1, 1.0) : vec4(c2, 1.0);
    }
    if (in_taper)  return vec4(dark, 1.0);
    if (in_basket) return vec4(0.55, 0.35, 0.20, 1.0);
    return vec4(0.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 term = texture(iChannel0, fragCoord.xy / iResolution.xy);
    vec3 col = term.rgb;
    // text_amt: 0 where the terminal pixel matches the theme bg (no text),
    //          1 where it differs (text / UI / cursor / tmux status bar tabs).
    // Tight smoothstep so any clearly non-bg pixel jumps to 1.0 — prevents
    // ambient effects from appearing semi-transparent over colored status
    // bar tabs while still allowing a thin anti-aliasing band at text edges.
    // text_amt: 0 where pixel matches theme bg, 1 where it differs enough
    // to count as text/UI/cursor/status bar.
    // Ghostty samples the framebuffer in linear-RGB while BG_COL is given
    // in raw sRGB hex, so we gamma-correct (sRGB → linear via pow 2.2) before
    // comparing.  Threshold is smaller because linear values are compressed.
    vec3 bg_lin = pow(BG_COL, vec3(2.2));
    float text_amt = step(0.000144, len3(term.rgb - bg_lin));

    // ============================================================
    // 1. AMBIENT BLOCK (per theme — inserted by render-mascot.sh).
    // ============================================================
{
    // Drifting rose petals — small pink/cream pixels swirling in the wind.
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float dx_base = hash11(fi * 4.71) * iResolution.x;
        float life = 36.0 + 10.0 * hash11(fi * 1.13);
        float t01 = fract((iTime + hash11(fi * 5.7) * life) / life);
        float dy_pos = mix(iResolution.y + 12.0, -12.0, t01);
        // Two-axis sway (figure-8-ish drift).
        float sway_x = sin(t01 * 12.56 + fi * 2.1) * 32.0
                     + cos(t01 * 6.28 + fi) * 12.0;
        vec2 d = abs(fragCoord.xy - vec2(dx_base + sway_x, dy_pos));
        // 2x2 petal pixel.
        if (d.x <= 1.0 && d.y <= 0.5) {
            float pick = hash11(fi * 9.1);
            vec3 hue = (pick < 0.5) ? vec3(0.92, 0.74, 0.73)    // rose
                                    : vec3(0.97, 0.86, 0.75);    // soft cream
            col += hue * 0.30;
        }
    }

    // === Butterflies fluttering around ===
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 base = vec2(
            0.15 + 0.70 * hash11(fi * 3.1),
            0.30 + 0.50 * hash11(fi * 7.7)
        ) * iResolution.xy;
        float fx = 0.4 + 0.3 * hash11(fi * 11.0);
        float fy = 0.25 + 0.25 * hash11(fi * 13.0);
        vec2 pos = base + vec2(
            sin(iTime * fx + fi) * 60.0,
            cos(iTime * fy + fi * 1.7) * 35.0
        );
        float pick = hash11(fi * 9.1);
        vec3 wing_col;
        if      (pick < 0.33) wing_col = vec3(0.95, 0.65, 0.78);
        else if (pick < 0.67) wing_col = vec3(0.78, 0.65, 0.91);
        else                  wing_col = vec3(0.96, 0.86, 0.65);
        vec4 bf = sampleButterfly(fragCoord.xy, pos, 3.0, wing_col, 7.0, fi * 1.3);
        if (bf.a > 0.5) col = mix(bf.rgb, col, text_amt);
    }
}

    // ============================================================
    // YIELD-TO-TEXT for the BACKGROUND only.
    // After this, the character + bell can draw on top of text.
    // ============================================================
    col = mix(col, term.rgb, text_amt);

    // ============================================================
    // 2. Character.  SPRITE_TYPE selects which renderer to use.
    // ============================================================
#if SPRITE_TYPE_ID == 1
    {
        // --- CAT state machine ---
        // 90s loop:
        //   0-12s   sleep at left
        //   12-14s  wake/stretch
        //   14-26s  walk right
        //   26-32s  climb up right wall (sprite rotated -90°)
        //   32-36s  idle at top
        //   36-42s  climb down
        //   42-54s  walk left
        //   54-60s  pause at left (sit)
        //   60-90s  sleep again
        float cat_loop  = 90.0;
        float cat_phase = mod(iTime, cat_loop);
        float cat_pose  = 2.0;
        float cat_x     = 80.0;
        float cat_y     = 0.0;
        float cat_dir   = 1.0;
        bool  climbing  = false;

        float wall_x      = iResolution.x - 50.0;
        float wall_top_y  = iResolution.y - 120.0;

        if (cat_phase < 12.0) {
            cat_pose = 0.0; cat_x = 80.0;
        } else if (cat_phase < 14.0) {
            cat_pose = 1.0; cat_x = 80.0;       // wake/stretch
        } else if (cat_phase < 26.0) {
            cat_pose = 2.0;
            cat_x = mix(80.0, wall_x, (cat_phase - 14.0) / 12.0);
            cat_dir = 1.0;
        } else if (cat_phase < 32.0) {
            cat_pose = 2.0;
            cat_x = wall_x;
            cat_y = mix(0.0, wall_top_y, (cat_phase - 26.0) / 6.0);
            cat_dir = 1.0;
            climbing = true;
        } else if (cat_phase < 36.0) {
            cat_pose = 2.0; cat_x = wall_x; cat_y = wall_top_y;
            cat_dir = 1.0; climbing = true;
        } else if (cat_phase < 42.0) {
            cat_pose = 2.0;
            cat_x = wall_x;
            cat_y = mix(wall_top_y, 0.0, (cat_phase - 36.0) / 6.0);
            cat_dir = -1.0;            // facing down now
            climbing = true;
        } else if (cat_phase < 54.0) {
            cat_pose = 2.0;
            cat_x = mix(wall_x, 80.0, (cat_phase - 42.0) / 12.0);
            cat_dir = -1.0;
        } else if (cat_phase < 60.0) {
            cat_pose = 2.0; cat_x = 80.0; cat_dir = -1.0;
        } else {
            cat_pose = 0.0; cat_x = 80.0;
        }

        float catFrame = mod(floor(iTime * FPS), 2.0);
        vec2 cat_anchor = vec2(cat_x, cat_y);

        // For wall-climbing, rotate fragPos -90° around the anchor so the cat
        // sprite drawn in its native "head-up" orientation lands head-up on the
        // wall (sideways relative to the floor).  dir flip handles up vs down.
        vec2 cat_fragPos = fragCoord.xy;
        if (climbing) {
            // Rotate sample-space by -90° so the cat sprite (drawn head-up)
            // appears rotated 90° CCW in world: head pointing INTO the screen
            // (left of right wall), feet on the wall.
            vec2 rel = fragCoord.xy - cat_anchor;
            rel = vec2(rel.y, -rel.x);
            cat_fragPos = cat_anchor + rel;
        }
        vec4 cat = sampleCat(cat_fragPos, cat_anchor, PX, cat_pose, catFrame, cat_dir,
                             BODY_COL, OUTLINE_COL, BLUSH_COL);
        if (cat.a > 0.5) col = cat.rgb;
    }
#elif SPRITE_TYPE_ID == 9
    {
        // --- NES WARRIOR state machine (48s loop, platformer escape) ---
        //   0..4s    rise in from below bottom-left, elevator-style
        //   4..30s   walk right, jumping the brick stacks
        //   30..32s  stop at far right and shoot grappling hook upward
        //   32..46s  climb rope and exit off top
        //   46..48s  stay offscreen so the next loop can enter from below
        float w_loop = 48.0;
        float wt = mod(iTime, w_loop);
        float left_x = 220.0;                  // clear first brick stack + approach arc
        float right_x = iResolution.x - 200.0;
        float rope_x = right_x + 14.0;
        float wx;
        float wy = 0.0;
        float wdir = -1.0;
        float walking = 1.0;
        float climbing = 0.0;
        if (wt < 4.0) {
            float enter_t = smoothstep(0.0, 1.0, wt / 4.0);
            wx = left_x;
            wy = mix(-96.0, 0.0, enter_t);
            wdir = -1.0;
            walking = 0.0;
        } else if (wt < 30.0) {
            wx = mix(left_x, right_x, (wt - 4.0) / 26.0);
            wdir = -1.0;
        } else if (wt < 32.0) {
            wx = right_x;
            wdir = -1.0;
            walking = 0.0;
        } else if (wt < 46.0) {
            float climb_t = smoothstep(0.0, 1.0, (wt - 32.0) / 14.0);
            wx = rope_x - 8.0;
            wy = mix(0.0, iResolution.y + 110.0, climb_t);
            wdir = -1.0;
            walking = 0.0;
            climbing = 1.0;
        } else {
            wx = rope_x - 8.0;
            wy = iResolution.y + 110.0;
            wdir = -1.0;
            walking = 0.0;
        }
        float wframe = (walking > 0.5) ? mod(floor(iTime * 3.5), 2.0) : 0.0;
        float wbob   = (walking > 0.5 && wframe > 0.5) ? 3.0 : 0.0;

        // Brick-jump: plateau function so the warrior actually CLEARS the
        // stacks instead of just hopping near them.  Positions/widths/heights
        // must match the pixel-corsair ambient hash formula exactly.
        float brick_jump = 0.0;
        float approach_dist = 35.0;
        if (walking > 0.5) {
            for (int bi = 0; bi < 7; bi++) {
                float bfi = float(bi);
                float bbase   = 0.08 + 0.13 * bfi;
                float bjit    = (hash11(bfi * 7.7) - 0.5) * 0.08;
                float bstack_x = (bbase + bjit) * iResolution.x;
                float wp = hash11(bfi * 5.3);
                float w_blocks;
                if      (wp < 0.30) w_blocks = 1.0;
                else if (wp < 0.55) w_blocks = 2.0;
                else if (wp < 0.78) w_blocks = 3.0;
                else if (wp < 0.92) w_blocks = 4.0;
                else                w_blocks = 6.0;
                float hp = hash11(bfi * 9.1);
                float h_blocks;
                if      (hp < 0.35) h_blocks = 1.0;
                else if (hp < 0.75) h_blocks = 2.0;
                else                h_blocks = 3.0;
                float bstack_w_px = w_blocks * 16.0;
                float bstack_h_px = h_blocks * 12.0;
                float x_left  = bstack_x;
                float x_right = bstack_x + bstack_w_px;
                float clear_h = bstack_h_px + 10.0;   // clearance above brick top

                float my_jump = 0.0;
                if (wx >= x_left - approach_dist && wx <= x_right + approach_dist) {
                    if (wx < x_left) {
                        float tt = (wx - (x_left - approach_dist)) / approach_dist;
                        my_jump = sin(tt * 1.5708) * clear_h;
                    } else if (wx > x_right) {
                        float tt = ((x_right + approach_dist) - wx) / approach_dist;
                        my_jump = sin(tt * 1.5708) * clear_h;
                    } else {
                        // Over the brick — flat plateau at clearance height.
                        my_jump = clear_h;
                    }
                }
                brick_jump = max(brick_jump, my_jump);
            }
        }
        vec2 w_anchor = vec2(wx, wy + wbob + brick_jump);
        vec3 w_tunic = BODY_COL;
        vec3 w_out   = OUTLINE_COL;
        vec3 w_skin  = vec3(0.96, 0.62, 0.51);    // pink-coral skin
        vec3 w_band  = vec3(0.96, 0.78, 0.57);    // cream headband
        vec3 w_boot  = vec3(0.34, 0.22, 0.13);

        // Grappling hook / rope.  Quantized to chunky 3px cells so it reads
        // as NES pixel art instead of a smooth vector line.  Lighter brown
        // rope pixels get diagonal shadow/highlight bands for coarse texture.
        if (wt >= 30.0 && wt < 46.0) {
            float shoot_t = clamp((wt - 30.0) / 2.0, 0.0, 1.0);
            float rope_top = iResolution.y - 8.0;
            float rope_start = w_anchor.y + 62.0;
            float rope_end = mix(rope_start, rope_top, shoot_t);
            float rope_low = min(rope_start, rope_end);
            float rope_high = max(rope_start, rope_end);
            vec2 rpx = floor(fragCoord.xy / 3.0 + 0.5) * 3.0;
            bool rope_core = abs(rpx.x - rope_x) <= 3.0
                          && rpx.y >= rope_low
                          && rpx.y <= rope_high;
            bool hook_bar = abs(rpx.y - rope_end) <= 3.0
                         && rpx.x >= rope_x - 9.0
                         && rpx.x <= rope_x + 9.0;
            bool hook_tip = abs(rpx.x - (rope_x + 9.0)) <= 3.0
                         && rpx.y >= rope_end - 9.0
                         && rpx.y <= rope_end;
            bool hook_bite = abs(rpx.y - (rope_end - 9.0)) <= 3.0
                          && rpx.x >= rope_x + 3.0
                          && rpx.x <= rope_x + 9.0;
            vec3 rope_base   = vec3(0.62, 0.36, 0.16);
            vec3 rope_light  = vec3(0.78, 0.50, 0.24);
            vec3 rope_shadow = vec3(0.38, 0.20, 0.09);
            float rope_twist = mod(floor((rpx.y + (rpx.x - rope_x) * 2.0) / 9.0), 2.0);
            bool rope_edge = abs(rpx.x - rope_x) > 0.0;
            bool rope_knot = mod(floor((rpx.y - rope_low) / 18.0), 3.0) < 1.0
                          && abs(rpx.x - rope_x) <= 3.0;
            vec3 rope_tex = rope_twist < 0.5 ? rope_light : rope_base;
            if (rope_edge && rope_twist > 0.5) rope_tex = rope_shadow;
            if (rope_knot) rope_tex = mix(rope_tex, rope_shadow, 0.45);

            vec3 hook_tex = rope_base;
            bool hook_pixel = hook_bar || hook_tip || hook_bite;
            if (hook_pixel && mod(floor((rpx.x + rpx.y) / 6.0), 2.0) < 1.0) hook_tex = rope_light;
            if (hook_tip || hook_bite) hook_tex = mix(hook_tex, rope_shadow, 0.25);

            if (rope_core) col = rope_tex;
            if (hook_pixel) col = hook_tex;
        }
        float arm_up = (wt >= 30.0 && wt < 46.0) ? 1.0 : 0.0;
        vec4 wr = sampleWarrior(fragCoord.xy, w_anchor, 3.0, wframe, wdir, arm_up,
                                w_tunic, w_out, w_skin, w_band, w_boot);
        if (wr.a > 0.5) col = wr.rgb;
    }
#elif SPRITE_TYPE_ID == 8
    {
        // --- SQUIRREL state machine (slow walk + pauses, continuous loop) ---
        // Symmetric so position is identical at t=0 and t=loop_dur (no teleport).
        //   0..18s   walk right (140 → W-200)
        //   18..22s  pause + look around
        //   22..40s  walk left (W-200 → 140)
        //   40..48s  pause + look
        float s_loop  = 48.0;
        float st_t   = mod(iTime, s_loop);
        float sq_x;
        float sq_dir = -1.0;
        float sq_pose = 0.0;
        float walking = 1.0;
        if (st_t < 18.0) {
            sq_x = mix(140.0, iResolution.x - 200.0, st_t / 18.0);
            sq_dir = -1.0;
        } else if (st_t < 22.0) {
            sq_x = iResolution.x - 200.0;
            sq_pose = 1.0;
            sq_dir = -1.0;
            walking = 0.0;
        } else if (st_t < 40.0) {
            sq_x = mix(iResolution.x - 200.0, 140.0, (st_t - 22.0) / 18.0);
            sq_dir = 1.0;
        } else {
            sq_x = 140.0;
            sq_pose = 1.0;
            sq_dir = 1.0;
            walking = 0.0;
        }
        // Walking frame at 4fps + 1-pixel vertical bob on alternating frames
        // so the squirrel reads as walking instead of gliding.
        float sq_frame = mod(floor(iTime * 4.0), 2.0);
        float walk_bob = (walking > 0.5 && sq_frame > 0.5) ? 3.0 : 0.0;
        vec2 sq_anchor = vec2(sq_x, walk_bob);
        vec3 sq_body   = BODY_COL;
        vec3 sq_out    = OUTLINE_COL;
        vec3 sq_belly  = mix(BODY_COL, vec3(1.0), 0.55);
        vec3 sq_tdark  = BODY_COL * 0.55;
        vec3 sq_nose   = vec3(0.96, 0.43, 0.49);
        vec4 sq = sampleSquirrel(fragCoord.xy, sq_anchor, 3.0, sq_pose, sq_frame, sq_dir,
                                  sq_body, sq_out, sq_belly, sq_tdark, sq_nose);
        if (sq.a > 0.5) col = sq.rgb;
    }
#elif SPRITE_TYPE_ID == 7
    {
        // --- BUNNY state machine (60s loop, slow hops + look-arounds) ---
        //   0..18s    hop right (6 hops, each 3s)
        //   18..22s   pause + look up
        //   22..36s   hop left (5 hops, each ~2.8s)
        //   36..40s   pause near left edge
        //   40..54s   hop right again (slowly)
        //   54..60s   sit idle
        float b_loop = 60.0;
        float bt = mod(iTime, b_loop);
        float bn_x;
        float bn_y_off = 0.0;
        float bn_dir = -1.0;   // sprite head-LEFT so dir=-1 makes head face right
        float bn_pose = 0.0;
        float hop_period = 3.0;
        float hop_dist   = 75.0;

        if (bt < 18.0) {
            float hop_i = floor(bt / hop_period);
            float hop_t = fract(bt / hop_period);
            // Smooth forward progress during air-time; eased so motion peaks
            // mid-air and settles on landing.
            float air_t = clamp(hop_t / 0.6, 0.0, 1.0);
            float fwd   = smoothstep(0.0, 1.0, air_t);
            bn_x = 120.0 + (hop_i + fwd) * hop_dist;
            bn_y_off = sin(air_t * 3.14159) * 16.0;
            bn_pose = (air_t < 0.95 && air_t > 0.05) ? 1.0 : 0.0;
            bn_dir = -1.0;
        } else if (bt < 22.0) {
            bn_x = 120.0 + 6.0 * hop_dist;
            bn_pose = 2.0;
            bn_dir = -1.0;
        } else if (bt < 36.0) {
            float hop_i = floor((bt - 22.0) / 2.8);
            float hop_t = fract((bt - 22.0) / 2.8);
            float air_t = clamp(hop_t / 0.6, 0.0, 1.0);
            float fwd   = smoothstep(0.0, 1.0, air_t);
            bn_x = 120.0 + 6.0 * hop_dist - (hop_i + fwd) * hop_dist;
            bn_y_off = sin(air_t * 3.14159) * 16.0;
            bn_pose = (air_t < 0.95 && air_t > 0.05) ? 1.0 : 0.0;
            bn_dir = 1.0;
        } else if (bt < 40.0) {
            bn_x = 120.0;
            bn_pose = 2.0;
            bn_dir = 1.0;
        } else if (bt < 54.0) {
            float hop_i = floor((bt - 40.0) / 3.5);
            float hop_t = fract((bt - 40.0) / 3.5);
            float air_t = clamp(hop_t / 0.6, 0.0, 1.0);
            float fwd   = smoothstep(0.0, 1.0, air_t);
            bn_x = 120.0 + (hop_i + fwd) * hop_dist;
            float real_hops = floor(14.0 / 3.5);
            bn_x = min(bn_x, 120.0 + real_hops * hop_dist);
            bn_y_off = sin(air_t * 3.14159) * 16.0;
            bn_pose = (air_t < 0.95 && air_t > 0.05) ? 1.0 : 0.0;
            bn_dir = -1.0;
        } else {
            bn_x = 120.0 + 4.0 * hop_dist;
            bn_pose = 0.0;
            bn_dir = -1.0;
        }

        float bn_frame = mod(floor(iTime * 4.0), 2.0);
        vec2 bn_anchor = vec2(bn_x, bn_y_off);
        vec3 bn_pink  = BLUSH_COL;
        vec3 bn_nose  = BLUSH_COL;
        vec4 bunny = sampleBunny(fragCoord.xy, bn_anchor, 3.0, bn_pose, bn_frame, bn_dir,
                                 BODY_COL, OUTLINE_COL, bn_pink, bn_nose);
        if (bunny.a > 0.5) col = bunny.rgb;
    }
#elif SPRITE_TYPE_ID == 6
    {
        // --- DEER PAIR (mom + fawn) state machine ---
        //   0..18s    walk right slowly
        //   18..22s   pause at right edge
        //   22..40s   walk left back toward berry bush
        //   40..52s   graze at bush (heads dipped)
        //   52..60s   stand idle near bush
        float d_loop = 60.0;
        float dt = mod(iTime, d_loop);
        float mom_x;
        float d_dir = 1.0;
        float graze = 0.0;            // 1.0 while heads are down
        // Berry bush sits at the very left edge; deer graze on its right.
        float bush_x = 50.0;
        // dir convention here: deer sprite is drawn head-LEFT, so dir=-1
        // mirrors to head-RIGHT (= facing right = walking right).
        if (dt < 18.0) {
            mom_x = mix(bush_x + 90.0, iResolution.x - 180.0, dt / 18.0);
            d_dir = -1.0;
        } else if (dt < 22.0) {
            mom_x = iResolution.x - 180.0;
            d_dir = -1.0;
        } else if (dt < 40.0) {
            mom_x = mix(iResolution.x - 180.0, bush_x + 70.0, (dt - 22.0) / 18.0);
            d_dir = 1.0;
        } else if (dt < 52.0) {
            mom_x = bush_x + 70.0;
            d_dir = 1.0;
            graze = 1.0;
        } else {
            mom_x = bush_x + 70.0;
            d_dir = 1.0;
        }
        // Walking frame (4fps for natural deer step).
        float deer_frame = mod(floor(iTime * 4.0), 2.0);

        // Position deer 0 = mom, deer 1 = fawn trails behind in direction of travel.
        // Travel direction in world coords is OPPOSITE of d_dir (since d_dir
        // is the sprite-mirror flag).  d_dir=-1 means head on right = walking
        // right in world, so fawn trails to the LEFT of mom (-50px).
        float travel_sign = -d_dir;   // +1 walking right, -1 walking left
        vec2 mom_anchor  = vec2(mom_x, 0.0);
        vec2 fawn_anchor = vec2(mom_x - 50.0 * travel_sign, 0.0);

        vec3 d_body    = BODY_COL;
        vec3 d_outline = OUTLINE_COL;
        vec3 d_belly   = mix(BODY_COL, vec3(1.0), 0.55);
        vec3 d_antler  = BODY_COL * 0.7;

        // Draw fawn first (so mom can occlude if they overlap).
        vec4 fawn = sampleDeer(fragCoord.xy, fawn_anchor, 2.0, deer_frame, d_dir,
                               false, graze, d_body, d_outline, d_belly, d_antler);
        if (fawn.a > 0.5) col = fawn.rgb;

        vec4 mom = sampleDeer(fragCoord.xy, mom_anchor, 3.0, deer_frame, d_dir,
                              true, graze, d_body, d_outline, d_belly, d_antler);
        if (mom.a > 0.5) col = mom.rgb;
    }
#elif SPRITE_TYPE_ID == 5
    {
        // --- WSB GUY state machine (75s loop, slower + more chill) ---
        //   0..18s   walk right slowly to mid-right
        //   18..23s  pause (look at viewer)
        //   23..27s  finger guns
        //   27..33s  stand idle
        //   33..51s  walk left slowly to mid-left
        //   51..55s  pause
        //   55..59s  finger guns
        //   59..67s  walk right a bit (variety)
        //   67..72s  pause/look
        //   72..75s  finger guns
        float w_loop = 75.0;
        float wt = mod(iTime, w_loop);
        float w_pose = 0.0;
        float w_x;
        float w_dir = 1.0;
        if (wt < 18.0) {
            w_pose = 0.0;
            w_x = mix(120.0, iResolution.x - 200.0, wt / 18.0);
            w_dir = 1.0;
        } else if (wt < 23.0) {
            w_pose = 1.0;
            w_x = iResolution.x - 200.0;
            w_dir = 1.0;
        } else if (wt < 27.0) {
            w_pose = 2.0;
            w_x = iResolution.x - 200.0;
            w_dir = 1.0;
        } else if (wt < 33.0) {
            w_pose = 1.0;     // idle stand looking
            w_x = iResolution.x - 200.0;
            w_dir = 1.0;
        } else if (wt < 51.0) {
            w_pose = 0.0;
            w_x = mix(iResolution.x - 200.0, 200.0, (wt - 33.0) / 18.0);
            w_dir = -1.0;
        } else if (wt < 55.0) {
            w_pose = 1.0;
            w_x = 200.0;
            w_dir = -1.0;
        } else if (wt < 59.0) {
            w_pose = 2.0;
            w_x = 200.0;
            w_dir = -1.0;
        } else if (wt < 67.0) {
            w_pose = 0.0;
            w_x = mix(200.0, iResolution.x * 0.42, (wt - 59.0) / 8.0);
            w_dir = 1.0;
        } else if (wt < 72.0) {
            w_pose = 1.0;
            w_x = iResolution.x * 0.42;
            w_dir = 1.0;
        } else {
            w_pose = 2.0;
            w_x = iResolution.x * 0.42;
            w_dir = 1.0;
        }
        // Slow the walk-cycle frame swap so the strut reads as more deliberate.
        float walk_fps = 4.0;
        // Strut: slower step rhythm than the FPS clock for ambient mascots.
        float w_frame = mod(floor(iTime * walk_fps), 2.0);
        float strut_y = (w_pose < 0.5 && w_frame > 0.5) ? PX : 0.0;
        vec2 w_anchor = vec2(w_x, 0.0 + strut_y);
        // Theme colors (sourced from theme bash).
        vec3 j_jacket = BODY_COL;
        vec3 j_outline = OUTLINE_COL;
        vec3 j_skin    = vec3(0.92, 0.78, 0.62);
        vec3 j_hair    = vec3(0.20, 0.14, 0.10);
        vec3 j_pants   = vec3(0.12, 0.14, 0.20);
        vec3 j_shoes   = vec3(0.05, 0.05, 0.07);
        vec3 j_belt    = vec3(0.30, 0.20, 0.12);
        vec3 j_gold    = vec3(0.85, 0.70, 0.20);
        vec4 wsb = sampleWSB(fragCoord.xy, w_anchor, 3.0, w_pose, w_frame, w_dir,
                             j_jacket, j_outline, j_skin, j_hair,
                             j_pants, j_shoes, j_belt, j_gold);
        if (wsb.a > 0.5) col = wsb.rgb;
    }
#elif SPRITE_TYPE_ID == 4
    {
        // --- ROCKETSHIP state machine (30s loop) ---
        //   0..12s    idle grumble on the ground
        //   12..15s   pre-launch heavy shake + small flame puffs
        //   15..22s   ascent (eases up, off-screen by end)
        //   22..30s   gone (wait)
        float r_loop = 30.0;
        float rt = mod(iTime, r_loop);
        float r_phase = 0.0;          // 0=idle, 1=pre-launch, 2=ascent
        float flame_len = 0.0;
        // Anchor sits so the fin bottom (sprite y=4) lands on platform top (y=36).
        // anchor.y + 4*scale(3) = 36  =>  anchor.y = 24.
        float ground_y  = 24.0;
        float rocket_x  = iResolution.x * 0.72;
        float rocket_y  = ground_y;
        bool  visible   = true;

        if (rt < 12.0) {
            r_phase = 0.0;
            // Gentle idle grumble: small high-freq jitter.
            rocket_x += sin(iTime * 16.0) * 0.6;
            rocket_y += cos(iTime * 13.0) * 0.5;
        } else if (rt < 15.0) {
            r_phase = 1.0;
            float st = (rt - 12.0) / 3.0;
            // Pre-launch shake, intensifying.
            rocket_x += sin(iTime * 45.0) * (1.0 + st * 2.5);
            rocket_y += cos(iTime * 38.0) * (1.0 + st * 2.0);
            flame_len = 4.0 + st * 3.0;
        } else if (rt < 22.0) {
            r_phase = 2.0;
            float at = (rt - 15.0) / 7.0;
            // Quadratic ease-in: slow then accelerating.
            float ease = at * at;
            rocket_y = ground_y + ease * (iResolution.y + 80.0);
            flame_len = 14.0 + at * 8.0;
        } else {
            visible = false;
        }

        if (visible) {
            vec2 r_anchor = vec2(rocket_x, rocket_y);
            vec3 r_body    = vec3(0.92, 0.92, 0.96);
            vec3 r_outline = vec3(0.08, 0.08, 0.13);
            vec3 r_nose    = vec3(0.85, 0.22, 0.20);
            vec3 r_fin     = vec3(0.85, 0.22, 0.20);
            vec3 r_window  = vec3(0.32, 0.78, 0.92);
            vec3 r_flame1  = vec3(1.00, 0.96, 0.45);
            vec3 r_flame2  = vec3(1.00, 0.58, 0.12);
            vec3 r_flame3  = vec3(0.90, 0.22, 0.10);
            vec3 r_smoke   = vec3(0.62, 0.62, 0.66);
            vec4 rocket = sampleRocket(fragCoord.xy, r_anchor, 3.0, r_phase, flame_len,
                                       r_body, r_outline, r_nose, r_fin, r_window,
                                       r_flame1, r_flame2, r_flame3, r_smoke);
            if (rocket.a > 0.5) col = rocket.rgb;
        }
    }
#elif SPRITE_TYPE_ID == 3
    {
        // --- PIRATE CORSAIR (uses same 28s walk loop as the blob) ---
        float t      = floor(iTime * FPS) / FPS;
        float frameF = floor(iTime * FPS);
        float frame2 = mod(frameF, 2.0);
        float loop_dur = 28.0;
        float phase    = mod(iTime, loop_dur);
        float walk_x   = 80.0;
        float dir      = 1.0;
        float walking  = 1.0;
        if (phase < 12.0) {
            walk_x = mix(80.0, iResolution.x - 80.0, phase / 12.0);
        } else if (phase < 14.0) {
            walk_x = iResolution.x - 80.0; walking = 0.0;
        } else if (phase < 26.0) {
            walk_x = mix(iResolution.x - 80.0, 80.0, (phase - 14.0) / 12.0);
            dir = -1.0;
        } else {
            walk_x = 80.0; walking = 0.0; dir = -1.0;
        }
        float pose = walking;
        vec2 corsair_anchor = vec2(walk_x, 0.0);
        // Pixel-corsair palette — vibrant base colors; per-pixel hash shading
        // in sampleCorsair builds the lit/shadow tones around these.
        vec3 coat        = vec3(0.290, 0.620, 0.560);    // saturated sage teal
        vec3 outline     = vec3(0.090, 0.110, 0.140);
        vec3 beard       = vec3(0.890, 0.420, 0.270);    // vivid red-orange beard
        vec3 skin        = vec3(0.880, 0.700, 0.560);    // warm tan
        vec3 hat         = vec3(0.300, 0.470, 0.450);    // muted teal-grey hat
        vec3 gold        = vec3(0.890, 0.700, 0.220);    // brighter gold
        vec3 belt        = vec3(0.580, 0.360, 0.220);    // saddle brown
        vec3 boot        = vec3(0.420, 0.260, 0.160);
        vec3 sword       = vec3(0.84, 0.86, 0.92);       // brighter silver
        vec3 cream       = vec3(0.965, 0.910, 0.757);
        vec3 navy        = vec3(0.135, 0.150, 0.230);    // slightly brighter navy
        vec3 bandana_col = vec3(0.760, 0.180, 0.180);    // vibrant red
        vec3 eye_blue    = vec3(0.42, 0.74, 0.96);
        // Corsair sprite is large; render at smaller cell size to fit nicely.
        float corsair_scale = 2.5;
        vec4 cors = sampleCorsair(fragCoord.xy, corsair_anchor, corsair_scale,
                                  pose, frame2, dir,
                                  coat, outline, beard, skin, hat, gold, belt, boot, sword, cream,
                                  navy, bandana_col, eye_blue);
        if (cors.a > 0.5) col = cors.rgb;
    }
#elif SPRITE_TYPE_ID == 2
    {
        // --- SPLAT: drifting / rotating Anthropic-style 4-lobe shape ---
        float sloop = 40.0;
        float sp = mod(iTime, sloop) / sloop;
        // Drift back and forth across screen.
        float drift = sin(sp * 6.28318);
        vec2 splat_c = vec2(
            iResolution.x * (0.5 + 0.30 * drift),
            iResolution.y * 0.50 + 25.0 * sin(iTime * 0.4)
        );
        float splat_ang = iTime * 0.5;
        vec4 splat = sampleSplat(fragCoord.xy, splat_c, splat_ang, BODY_COL, OUTLINE_COL);
        if (splat.a > 0.5) col = mix(splat.rgb, col, text_amt);   // splat sits behind text
    }
#else
    {
    // --- BLOB (default character) ---
        float t      = floor(iTime * FPS) / FPS;
        float frameF = floor(iTime * FPS);
        float frame2 = mod(frameF, 2.0);

        float loop_dur  = LOOP_DUR;
        float cycle_idx = floor(iTime / loop_dur);
        float phase     = mod(iTime, loop_dur);
        float W         = iResolution.x;

        // Schedule expressed in fractions of loop_dur so themes can stretch
        // it independently:
        //   0 - 0.43   walk right
        //   0.43 - 0.50  pause (right)
        //   0.50 - 0.93  walk left
        //   0.93 - 1.00  pause (left)
        float p_t = phase / loop_dur;
        float walk_x   = 0.0;
        float dir      = 1.0;
        float walking  = 1.0;
        float pause_idx = -1.0;
        float pause_t  = 0.0;
        if (p_t < 0.43) {
            walk_x = mix(80.0, W - 80.0, p_t / 0.43);
            dir = 1.0;
        } else if (p_t < 0.50) {
            walk_x = W - 80.0;
            dir = 1.0;
            walking = 0.0;
            pause_idx = 0.0;
            pause_t = (p_t - 0.43) / 0.07;
        } else if (p_t < 0.93) {
            walk_x = mix(W - 80.0, 80.0, (p_t - 0.50) / 0.43);
            dir = -1.0;
        } else {
            walk_x = 80.0;
            dir = -1.0;
            walking = 0.0;
            pause_idx = 1.0;
            pause_t = (p_t - 0.93) / 0.07;
        }

        // Pause action: 0=blink-stand, 1=wave, 2=jump, 3=kick.
        float action = -1.0;
        if (walking < 0.5) {
            float r = hash11(cycle_idx * 13.7 + pause_idx * 5.3 + 1.1);
            if (r < 0.35) action = 0.0;
            else if (r < 0.60) action = 1.0;
            else if (r < 0.80) action = 2.0;
            else action = 3.0;
        }

        float jump_y = 0.0;
        if (action > 1.5 && action < 2.5) {
            float jt = clamp((pause_t - 0.2) / 0.6, 0.0, 1.0);
            jump_y = sin(jt * 3.14159) * 45.0;
        }

        float step_period = mod(frameF, 4.0);
        float walk_bounce = (walking > 0.5 && step_period >= 2.0) ? PX : 0.0;

        // ---------- Movement personality ----------
        // Per-theme movement style modifies y-offset, rotation, and feet.
        float move_y    = 0.0;
        float move_rot  = 0.0;
        bool  show_feet = FOOT_ON > 0.5;
        bool  flying    = false;

        if (MOVEMENT > 0.5 && MOVEMENT < 1.5) {
            // FLY: swooping flight, no feet, flapping signal for wings accessory.
            move_y = 60.0 + 25.0 * sin(iTime * 0.7)
                          + 40.0 * sin(phase * 0.55 + 1.3);
            show_feet = false;
            flying = true;
            walk_bounce = 0.0;
        } else if (MOVEMENT > 1.5 && MOVEMENT < 2.5) {
            // HOP: discrete bouncy arcs while walking.
            if (walking > 0.5) {
                float hop_t = fract(iTime * 1.3);
                move_y = sin(hop_t * 3.14159) * 28.0;
                walk_bounce = 0.0;
            }
        } else if (MOVEMENT > 2.5 && MOVEMENT < 3.5) {
            // SLIDE: belly-slide; 90° rotation in direction of travel; lower to ground.
            if (walking > 0.5) {
                move_rot = -1.5708 * dir;
                move_y = -PX * 1.5;
                show_feet = false;
                walk_bounce = 0.0;
            }
        } else if (MOVEMENT > 3.5 && MOVEMENT < 4.5) {
            // ROLL: continuous rotation (forward direction).
            if (walking > 0.5) {
                move_rot = -iTime * 4.0 * dir;
                show_feet = false;
                move_y = PX * 0.5;
                walk_bounce = 0.0;
            }
        } else if (MOVEMENT > 4.5 && MOVEMENT < 5.5) {
            // HOVER: floating, gentle bob, no feet.
            move_y = 26.0 + 5.0 * sin(iTime * 1.3) + 3.0 * sin(iTime * 0.5);
            show_feet = false;
            walk_bounce = 0.0;
        } else if (MOVEMENT > 5.5 && MOVEMENT < 6.5) {
            // MARCH: slow heavy bounce, deliberate.
            if (walking > 0.5) {
                float march_t = fract(iTime * 0.7);
                move_y = abs(sin(march_t * 3.14159)) * 6.0;
                walk_bounce = 0.0;
            }
        } else if (MOVEMENT > 6.5 && MOVEMENT < 7.5) {
            // BOUNCE: continuous high sinusoidal arc while walking.
            if (walking > 0.5) {
                float bounce_t = fract(iTime * 1.5);
                move_y = abs(sin(bounce_t * 3.14159)) * 32.0;
                walk_bounce = 0.0;
            }
        }

        float ground_y = 6.0 * PX;
        vec2 origin = vec2(walk_x, ground_y + jump_y + walk_bounce + move_y);

        vec2 p = (fragCoord.xy - origin) / PX;
        p.x *= dir;
        if (move_rot != 0.0) {
            float rc = cos(move_rot), rs = sin(move_rot);
            p = vec2(rc * p.x - rs * p.y, rs * p.x + rc * p.y);
        }
        vec2 spx = floor(p + 0.5);

        if (abs(spx.x) <= 12.0 && abs(spx.y) <= 12.0) {

            // ---------- Body shape ----------
            bool in_body = false;
            bool in_body_outline = false;
            if (SHAPE_SQUARE > 0.5) {
                in_body = abs(spx.x) <= SHAPE_W && abs(spx.y - 0.5) <= SHAPE_H;
                bool outer = abs(spx.x) <= SHAPE_W + 1.0 && abs(spx.y - 0.5) <= SHAPE_H + 1.0;
                in_body_outline = outer && !in_body;
            } else {
                vec2 bn = vec2(spx.x / SHAPE_W, spx.y / SHAPE_H);
                float bd2 = len2(bn);
                in_body = bd2 <= 1.0;
                in_body_outline = bd2 > 1.0 && bd2 <= 1.3924;
            }

            // ---------- Eyes (style-dependent) ----------
            bool in_eye = false;
            bool eye_hl = false;
            if (EYE_STYLE < 0.5) {
                // 0: vertical-oval with highlight (Kirby).
                bool eL = inRect(spx, vec2(-3.0, 1.0), vec2(-2.0, 3.0));
                bool eR = inRect(spx, vec2( 2.0, 1.0), vec2( 3.0, 3.0));
                bool hL = samePx(spx, -3.0, 3.0);
                bool hR = samePx(spx,  2.0, 3.0);
                in_eye = eL || eR;
                eye_hl = hL || hR;
            } else if (EYE_STYLE < 1.5) {
                // 1: round-dot.
                in_eye = samePx(spx, -2.0, 2.0) || samePx(spx, 2.0, 2.0);
            } else if (EYE_STYLE < 2.5) {
                // 2: slit-band.
                in_eye = (spx.y == 2.0) && (abs(spx.x) >= 1.0 && abs(spx.x) <= 3.0);
            } else if (EYE_STYLE < 3.5) {
                // 3: red-glow (single dot per eye, glow added later via color).
                in_eye = samePx(spx, -2.0, 2.0) || samePx(spx, 2.0, 2.0);
            } else {
                // 4: X-eyes (dead/spooky look).
                in_eye = (samePx(spx, -3.0, 1.0) || samePx(spx, -3.0, 3.0)
                       || samePx(spx, -2.0, 2.0)
                       || samePx(spx, 2.0, 2.0)
                       || samePx(spx, 3.0, 1.0) || samePx(spx, 3.0, 3.0));
            }

            // Blink behavior.
            float blink_phase_walk = fract(iTime / 3.2);
            bool blink_walk = blink_phase_walk < 0.04;
            float blink_phase_idle = fract(pause_t * 5.0);
            bool blink_idle = (action > -0.5 && action < 0.5) && blink_phase_idle < 0.45;
            bool blinking = blink_walk || blink_idle;

            // ---------- Blush ----------
            bool in_blush = false;
            if (BLUSH_ON > 0.5) {
                in_blush = inRect(spx, vec2(-5.0, -1.0), vec2(-4.0, -1.0))
                       ||  inRect(spx, vec2( 4.0, -1.0), vec2( 5.0, -1.0));
            }

            // ---------- Feet ----------
            vec2 f1_lo, f1_hi, f2_lo, f2_hi;
            if (action > 1.5 && action < 2.5) {
                f1_lo = vec2(-2.0, -5.0); f1_hi = vec2(-1.0, -4.0);
                f2_lo = vec2( 1.0, -5.0); f2_hi = vec2( 2.0, -4.0);
            } else if (action > 2.5) {
                f1_lo = vec2(-3.0, -6.0); f1_hi = vec2(-2.0, -5.0);
                f2_lo = vec2( 5.0, -2.0); f2_hi = vec2( 7.0, -1.0);
            } else if (walking > 0.5) {
                if (frame2 < 0.5) {
                    f1_lo = vec2(-4.0, -6.0); f1_hi = vec2(-2.0, -5.0);
                    f2_lo = vec2( 1.0, -6.0); f2_hi = vec2( 3.0, -5.0);
                } else {
                    f1_lo = vec2(-3.0, -6.0); f1_hi = vec2(-1.0, -5.0);
                    f2_lo = vec2( 2.0, -6.0); f2_hi = vec2( 4.0, -5.0);
                }
            } else {
                f1_lo = vec2(-3.0, -6.0); f1_hi = vec2(-1.0, -5.0);
                f2_lo = vec2( 1.0, -6.0); f2_hi = vec2( 3.0, -5.0);
            }
            bool in_foot = show_feet && (inRect(spx, f1_lo, f1_hi) || inRect(spx, f2_lo, f2_hi));
            bool foot_outline = show_feet &&
                                (inRect(spx, f1_lo - 1.0, f1_hi + 1.0)
                              || inRect(spx, f2_lo - 1.0, f2_hi + 1.0)) && !in_foot;

            // ---------- Wave hand ----------
            bool in_hand = false;
            bool hand_outline = false;
            if (action > 0.5 && action < 1.5) {
                float flap_t = fract(pause_t * 3.0);
                float hand_y = mix(2.0, 4.0, step(flap_t, 0.5));
                vec2 h_lo = vec2(5.0, hand_y);
                vec2 h_hi = vec2(6.0, hand_y + 1.0);
                in_hand = inRect(spx, h_lo, h_hi);
                hand_outline = inRect(spx, h_lo - 1.0, h_hi + 1.0) && !in_hand;
            }

            // ---------- Accessory ----------
            bool in_acc = false;
            bool in_acc2 = false;
            bool acc_outline = false;
            if (ACCESSORY > 0.5 && ACCESSORY < 1.5) {
                // Leaf-hat: 3 pixels at top, drooping to one side.
                in_acc = samePx(spx, -1.0, 6.0) || samePx(spx, 0.0, 6.0)
                      || samePx(spx, 0.0, 7.0)  || samePx(spx, 1.0, 7.0);
            } else if (ACCESSORY > 1.5 && ACCESSORY < 2.5) {
                // Fangs: two white pixels below mouth area.
                in_acc = samePx(spx, -1.0, 0.0) || samePx(spx, 1.0, 0.0);
            } else if (ACCESSORY > 2.5 && ACCESSORY < 3.5) {
                // Flower-crown: pixels of two colors arranged like petals.
                in_acc  = samePx(spx, -2.0, 6.0) || samePx(spx, 0.0, 7.0) || samePx(spx, 2.0, 6.0);
                in_acc2 = samePx(spx, -1.0, 6.0) || samePx(spx, 1.0, 6.0);
            } else if (ACCESSORY > 3.5 && ACCESSORY < 4.5) {
                // Ninja-band: horizontal band across the eye row, with knot trail.
                in_acc = (spx.y == 2.0 && abs(spx.x) <= 5.0)
                      || (spx.y == 3.0 && spx.x >= 4.0 && spx.x <= 6.0);
            } else if (ACCESSORY > 4.5 && ACCESSORY < 5.5) {
                // Beak: orange triangle below eyes.
                in_acc = samePx(spx, 0.0, 0.0) || samePx(spx, -1.0, -1.0) || samePx(spx, 1.0, -1.0);
            } else if (ACCESSORY > 5.5 && ACCESSORY < 6.5) {
                // Tongue: red pixel below mouth, extends forward 2px in front.
                in_acc = samePx(spx, 0.0, -1.0) || samePx(spx, 1.0, -1.0) || samePx(spx, 2.0, -2.0);
            } else if (ACCESSORY > 6.5 && ACCESSORY < 7.5) {
                // Wings: flap when flying, fixed angled outline otherwise.
                float flap = flying ? mod(floor(iTime * 8.0), 2.0) : 0.0;
                float wy = flap;
                in_acc = (samePx(spx, -7.0, 1.0 + wy) || samePx(spx, -6.0, 2.0 + wy) || samePx(spx, -7.0, 3.0 + wy)
                       || samePx(spx,  7.0, 1.0 + wy) || samePx(spx,  6.0, 2.0 + wy) || samePx(spx,  7.0, 3.0 + wy));
            } else if (ACCESSORY > 7.5 && ACCESSORY < 8.5) {
                // Leaf-stem (citrus): tiny stem + leaf at top of head.
                in_acc = samePx(spx, 0.0, 6.0) || samePx(spx, 1.0, 7.0) || samePx(spx, 2.0, 7.0);
            } else if (ACCESSORY > 8.5 && ACCESSORY < 9.5) {
                // Belly-patch (penguin): white oval in lower body.
                in_acc = (abs(spx.x) <= 2.0) && (spx.y >= -3.0 && spx.y <= 1.0)
                       && !samePx(spx, -2.0, 1.0) && !samePx(spx, 2.0, 1.0);
            } else if (ACCESSORY > 9.5 && ACCESSORY < 10.5) {
                // Crescent moon hovering above head.
                in_acc = (samePx(spx, 0.0, 7.0) || samePx(spx, 1.0, 7.0)
                       || samePx(spx, 0.0, 8.0) || samePx(spx, -1.0, 8.0)
                       || samePx(spx, 0.0, 9.0));
            } else if (ACCESSORY > 10.5 && ACCESSORY < 11.5) {
                // Witch hat: tall pointed triangle on top.
                in_acc = (samePx(spx, 0.0, 10.0))
                      || (spx.y == 9.0 && abs(spx.x) <= 1.0)
                      || (spx.y == 8.0 && abs(spx.x) <= 2.0)
                      || (spx.y == 7.0 && abs(spx.x) <= 3.0)
                      || (spx.y == 6.0 && abs(spx.x) <= 4.0);  // brim
            } else if (ACCESSORY > 11.5 && ACCESSORY < 12.5) {
                // Skull-bone cross beneath body (2 crossbones).
                in_acc = (spx.y == -7.0 && abs(spx.x) <= 3.0)
                      || (spx.y == -6.0 && (spx.x == -3.0 || spx.x == 3.0))
                      || (spx.y == -5.0 && (spx.x == -3.0 || spx.x == 3.0));
            } else if (ACCESSORY > 12.5 && ACCESSORY < 13.5) {
                // Antenna (vertical line + ball on top), for retro TV / robot.
                in_acc = (spx.x == 0.0 && spx.y >= 7.0 && spx.y <= 9.0)
                      || (spx.y == 10.0 && abs(spx.x) <= 1.0);
            }

            // ---------- Layered draw ----------
            if (in_acc2)         col = ACC2_COL;
            if (foot_outline)    col = OUTLINE_COL;
            if (in_foot)         col = FOOT_COL;
            if (hand_outline)    col = OUTLINE_COL;
            if (in_hand)         col = BODY_COL;
            if (in_body_outline) col = OUTLINE_COL;
            if (in_body)         col = BODY_COL;
            if (in_blush)        col = BLUSH_COL;
            if (in_acc)          col = ACC_COL;
            if (in_eye) {
                if (blinking)   col = OUTLINE_COL;
                else            col = EYE_COL;
                if (!blinking && eye_hl) col = EYE_HL_COL;
            }
        }
        // Red-glow eye halo: computed OUTSIDE the sprite cull so the glow
        // fades smoothly to zero in every direction (no hard bounding box).
        if (EYE_STYLE > 2.5) {
            vec2 eye_world  = origin + vec2(-2.0 * PX * dir, 2.0 * PX);
            vec2 eye_world2 = origin + vec2( 2.0 * PX * dir, 2.0 * PX);
            float ed1_2 = len2(fragCoord.xy - eye_world);
            float ed2_2 = len2(fragCoord.xy - eye_world2);
            // Gaussian falloff: much wider spread so the halo dims to nothing
            // before its bounding region ends.
            float glow = exp(-ed1_2 * 0.0006) + exp(-ed2_2 * 0.0006);
            col += EYE_COL * glow * 0.40;
        }
    }
#endif

    // ============================================================
    // 3. 8-bit pixel-art bell (only when SHOW_BELL = 1.0).
    // ============================================================
#if SHOW_BELL_ID == 1
    {
        float bf = floor(iTime * BELL_FPS);
        float rock = mod(bf, 4.0);
        float tilt_x = (rock < 2.0) ? 1.0 : -1.0;
        float clap_x = (mod(bf + 2.0, 4.0) < 2.0) ? 1.0 : -1.0;

        vec2 b_anchor = vec2(iResolution.x - 12.0 * BELL_PX, iResolution.y - 16.0 * BELL_PX);
        vec2 bp = (fragCoord.xy - b_anchor) / BELL_PX;
        vec2 bspx = floor(bp + 0.5);

        vec2 body_spx = bspx - vec2(tilt_x, 0.0);
        vec2 clap_spx = bspx - vec2(clap_x, 0.0);

        float by = body_spx.y;
        float bx = abs(body_spx.x);

        bool in_bell = false;
        if      (by == 0.0) in_bell = bx <= 1.0;
        else if (by == 1.0) in_bell = bx <= 1.0;
        else if (by == 2.0) in_bell = bx <= 2.0;
        else if (by == 3.0) in_bell = bx <= 3.0;
        else if (by == 4.0) in_bell = bx <= 4.0;
        else if (by == 5.0) in_bell = bx <= 5.0;
        else if (by == 6.0) in_bell = bx <= 5.0;
        else if (by == 7.0) in_bell = bx <= 5.0;
        else if (by == 8.0) in_bell = bx <= 6.0;
        else if (by == 9.0) in_bell = bx <= 6.0;

        bool in_clapper = false;
        float cy = clap_spx.y;
        float cx = abs(clap_spx.x);
        if (cy == 11.0 || cy == 12.0) in_clapper = cx <= 1.0;

        // Outline: 1px ring outside bell silhouette.
        bool bell_outline = false;
        if (!in_bell) {
            float ay = body_spx.y, ax = abs(body_spx.x);
            float prev_y = ay - 1.0;
            bool top_in = false;
            if      (prev_y == 0.0) top_in = ax <= 1.0;
            else if (prev_y == 1.0) top_in = ax <= 1.0;
            else if (prev_y == 2.0) top_in = ax <= 2.0;
            else if (prev_y == 3.0) top_in = ax <= 3.0;
            else if (prev_y == 4.0) top_in = ax <= 4.0;
            else if (prev_y == 5.0) top_in = ax <= 5.0;
            else if (prev_y == 6.0) top_in = ax <= 5.0;
            else if (prev_y == 7.0) top_in = ax <= 5.0;
            else if (prev_y == 8.0) top_in = ax <= 6.0;
            else if (prev_y == 9.0) top_in = ax <= 6.0;
            float next_y = ay + 1.0;
            bool bot_in = false;
            if      (next_y == 0.0) bot_in = ax <= 1.0;
            else if (next_y == 1.0) bot_in = ax <= 1.0;
            else if (next_y == 2.0) bot_in = ax <= 2.0;
            else if (next_y == 3.0) bot_in = ax <= 3.0;
            else if (next_y == 4.0) bot_in = ax <= 4.0;
            else if (next_y == 5.0) bot_in = ax <= 5.0;
            else if (next_y == 6.0) bot_in = ax <= 5.0;
            else if (next_y == 7.0) bot_in = ax <= 5.0;
            else if (next_y == 8.0) bot_in = ax <= 6.0;
            else if (next_y == 9.0) bot_in = ax <= 6.0;
            float side_x = ax - 1.0;
            bool side_in = false;
            if      (ay == 0.0) side_in = side_x <= 1.0;
            else if (ay == 1.0) side_in = side_x <= 1.0;
            else if (ay == 2.0) side_in = side_x <= 2.0;
            else if (ay == 3.0) side_in = side_x <= 3.0;
            else if (ay == 4.0) side_in = side_x <= 4.0;
            else if (ay == 5.0) side_in = side_x <= 5.0;
            else if (ay == 6.0) side_in = side_x <= 5.0;
            else if (ay == 7.0) side_in = side_x <= 5.0;
            else if (ay == 8.0) side_in = side_x <= 6.0;
            else if (ay == 9.0) side_in = side_x <= 6.0;
            bell_outline = (top_in || bot_in || side_in)
                         && ay >= -1.0 && ay <= 11.0 && ax <= 8.0;
        }

        if (bell_outline) col = BELL_OUTLINE;
        if (in_bell)      col = BELL_COL;
        if (in_clapper)   col = BELL_OUTLINE;
    }
#endif

    // ============================================================
    // 4. AMBIENT OVERLAY: drawn LAST, on top of text + character +
    //    everything else.  Used for semi-transparent washes (sunrises,
    //    fog, color tints) that should sit above the entire scene but
    //    still let underlying content read through via alpha blending.
    // ============================================================
{ }

    fragColor = vec4(col, term.a);
}
