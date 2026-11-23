// by zayd/cold @ zayd.wtf

/// The Flash screen's shader, as source.
///
/// It is compiled on the phone the first time a color Flash opens (`FlashArtRenderer`), not by
/// Xcode: a `.metal` file in the target needs the separate Metal Toolchain download on every
/// Mac that builds Zone, and a build without it fails. Kept as text, the app builds anywhere,
/// and `scripts/flash-art-preview.swift` can draw the same scenes on a Mac.
enum FlashArtShader {
    static let source = #"""
// The Flash screen in color: one full-screen scene, drawn every refresh, with the code as a
// window in it. `FlashArtStage.swift` fills in the numbers; `LinkFlashSchedule` (ZoneCore)
// says when the window holds data and when the scene takes it over.
//
// Three rules this file keeps:
// - In a data slot (`exact`), a pixel of the code is its module's color from the picture and
//   nothing else, and a pixel of the quiet zone is the palette's light color and nothing else.
//   No scene, no glow and no smoothing reaches inside the window.
// - The scenes hold no squares and no grid of modules: gradients, curves, thin lines and
//   small round sparks only, so nothing in them can be taken for a code.
// - Large areas change brightness slowly. Sparks and stars twinkle; nothing big blinks.

#include <metal_stdlib>
using namespace metal;

// Every field is four floats, so the Swift struct lays out the same without padding rules.
struct FlashUniforms {
    float4 portal;   // x, y of the window's top left, its side, one module: all in pixels
    float4 code;     // modules across the picture, pixels from the window's edge to the picture, bezel, corner radius
    float4 clock;    // scene seconds, seed (0 to 1), how far through an interlude (0 outside one), pixels per point
    float4 state;    // presence (1 whole code, 0 none), reveal (0 wordmark, 1 code), frame (1 pale window, 0 glass), fade (0 black, 1 scene)
    float4 scenes;   // scene, next scene, wipe from one to the other (0 to 1), exact (1 in a data slot)
    float4 screen;   // width, height, bottom of the top text, top of the bottom text: pixels
    float4 dark;     // the palette's all-dark color
    float4 light;    // the palette's all-light color
};

struct FlashVertexOut {
    float4 position [[position]];
};

// One triangle that covers the screen.
vertex FlashVertexOut flashVertex(uint vertexID [[vertex_id]]) {
    FlashVertexOut out;
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n * 17.17 + 3.1));
}

// Small round points, a few of which twinkle slowly.
static float stars(float2 uv, float t, float density) {
    float2 grid = uv * density;
    float2 cell = floor(grid);
    float2 r = hash22(cell);
    float d = length(fract(grid) - (0.15 + 0.7 * r));
    float lit = step(0.80, hash21(cell + 7.7));
    float twinkle = 0.62 + 0.38 * sin(t * (0.7 + r.x * 1.4) + r.y * 30.0);
    return lit * twinkle * smoothstep(0.075, 0.0, d);
}

// What a scene is drawn from: `uv` is the pixel in screen widths (x from 0 to 1, y from 0 down),
// `center` and `reach` are the window's center and half its side in the same unit.
struct SceneIn {
    float2 uv;
    float2 center;
    float reach;
    float aspect;
    float t;
    float seed;
    float beat;
};

// Dusk: a striped sun setting behind the window, its lowest bars showing under it, a sky from
// deep purple to orange, and a grid running to the horizon.
static float3 duskScene(SceneIn s) {
    float horizon = min(s.center.y + s.reach + 0.135, s.aspect - 0.26);
    float radius = 0.34;
    float2 sun = float2(s.center.x, horizon - radius * 0.78);
    float3 col;
    if (s.uv.y < horizon) {
        float k = saturate(s.uv.y / horizon);
        col = mix(float3(0.035, 0.0, 0.11), float3(0.23, 0.01, 0.36), smoothstep(0.0, 0.6, k));
        col = mix(col, float3(0.86, 0.08, 0.46), smoothstep(0.55, 0.96, k) * 0.9);
        col = mix(col, float3(1.0, 0.52, 0.26), smoothstep(0.9, 1.0, k) * 0.85);
        col += float3(0.85, 0.8, 1.0) * stars(s.uv, s.t, 26.0) * (1.0 - smoothstep(0.3, 0.75, k));
        // Long thin clouds, drifting.
        float bar = sin(s.uv.y * 55.0 + sin(s.uv.x * 3.0 + s.t * 0.1 + s.seed * 6.0) * 1.5);
        col *= 1.0 - 0.2 * smoothstep(0.75, 0.95, bar) * smoothstep(0.35, 0.8, k);

        float2 fromSun = s.uv - sun;
        float d = length(fromSun);
        float sy = fromSun.y / radius;
        float disk = smoothstep(radius, radius - 0.004, d);
        // Gaps of sky across the lower part of the sun, wider toward the bottom, sliding down.
        float lane = fract(sy * 5.5 - s.t * 0.12);
        float gap = mix(0.10, 0.62, saturate((sy + 0.1) / 1.1));
        float bars = sy > -0.1 ? smoothstep(gap, gap + 0.06, lane) * (1.0 - smoothstep(0.94, 1.0, lane)) : 1.0;
        float3 sunColor = mix(float3(1.0, 0.86, 0.36), float3(1.0, 0.16, 0.52), saturate(sy * 0.55 + 0.5));
        col = mix(col, sunColor, disk * bars);
        col += float3(1.0, 0.25, 0.5) * 0.30 * exp(-max(d - radius, 0.0) * 7.0);
        // An interlude sends one slow comet across the sun.
        if (s.beat > 0.0) {
            float2 head = float2(s.center.x - 0.55 + 1.1 * s.beat, sun.y - 0.20 + 0.10 * s.beat);
            float2 rel = s.uv - head;
            float along = dot(rel, normalize(float2(-1.0, -0.09)));
            float across = length(rel - along * normalize(float2(-1.0, -0.09)));
            float tail = step(0.0, along) * exp(-along * 9.0) * exp(-across * across * 30000.0);
            col += float3(1.0, 0.92, 0.85) * (tail + exp(-dot(rel, rel) * 60000.0)) * sin(s.beat * 3.14159);
        }
    } else {
        float depth = s.uv.y - horizon;
        float z = 0.1 / (depth + 0.002);
        float gx = (s.uv.x - s.center.x) * z * 7.0;
        float gz = z * 2.2 + s.t * 1.1;
        float wx = fwidth(gx), wz = fwidth(gz);
        float lx = abs(fract(gx + 0.5) - 0.5);
        float lz = abs(fract(gz + 0.5) - 0.5);
        // Lines that grow too fine to draw cleanly near the horizon fade out there.
        float ax = (1.0 - smoothstep(0.0, wx * 1.5 + 0.02, lx)) * saturate(1.2 - wx * 2.5);
        float az = (1.0 - smoothstep(0.0, wz * 1.5 + 0.02, lz)) * saturate(1.2 - wz * 2.5);
        float near = smoothstep(0.0, 0.05, depth);
        col = mix(float3(0.16, 0.0, 0.22), float3(0.03, 0.0, 0.08), smoothstep(0.0, 0.25, depth));
        col += float3(1.0, 0.15, 0.62) * ax * 0.75 * near;
        col += float3(0.2, 0.75, 1.0) * az * 0.65 * near;
        col += float3(1.0, 0.35, 0.35) * 0.35 * exp(-depth * 14.0) * exp(-abs(s.uv.x - s.center.x) * 2.5);
    }
    return col;
}

// Aurora: three curtains of light over a ridge of hills, mirrored in still water.
static float3 auroraScene(SceneIn s) {
    float horizon = min(s.center.y + s.reach + 0.11, s.aspect - 0.26);
    float2 uv = s.uv;
    float water = 0.0;
    if (uv.y > horizon) {
        float depth = uv.y - horizon;
        water = 1.0;
        uv.x += sin(s.uv.y * 38.0 + s.t * 1.1) * 0.004 * (0.3 + depth * 5.0);
        uv.y = horizon - depth * 1.25;
    }
    float k = saturate(uv.y / horizon);
    float3 col = mix(float3(0.0, 0.015, 0.07), float3(0.0, 0.09, 0.17), smoothstep(0.2, 1.0, k));
    col += float3(0.8, 0.95, 1.0) * stars(uv, s.t, 30.0) * (1.0 - 0.6 * water);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float x = uv.x * (1.1 + 0.45 * fi) + s.seed * (3.1 + fi) + fi * 1.7;
        float drift = s.t * (0.10 + 0.04 * fi) * (i == 1 ? -1.0 : 1.0);
        float n = sin(x * 2.3 + drift * 2.0) + 0.5 * sin(x * 5.1 - drift * 3.1 + 1.3) + 0.25 * sin(x * 10.7 + drift * 4.3);
        // The lower hem of the curtain; its light rises from there and thins out.
        float hem = horizon * (0.52 + 0.16 * fi) + 0.07 * n;
        float above = hem - uv.y;
        float body = smoothstep(-0.012, 0.012, above) * exp(-max(above, 0.0) * (1.9 + 0.8 * fi));
        float rays = 0.62 + 0.38 * (1.0 - 0.75 * water) * sin(x * 64.0 + n * 6.0 + s.t * 0.7);
        float swell = 0.6 + 0.4 * sin(x * 1.1 + s.t * 0.31 + fi * 2.1);
        // An interlude sends one brighter fold along the curtains.
        float fold = s.beat > 0.0 ? 0.45 * exp(-pow((uv.x - (s.beat * 1.6 - 0.3)) / 0.22, 2.0)) * sin(s.beat * 3.14159) : 0.0;
        float3 tint = mix(float3(0.10, 1.0, 0.42), float3(0.55, 0.18, 1.0), saturate(above * 2.6 + 0.12 * fi));
        col += tint * body * rays * (swell + fold) * (0.9 - 0.15 * fi);
    }
    // The hills, and their reflection.
    float ridge = horizon - 0.03 - 0.022 * sin(uv.x * 6.0 + s.seed * 5.0) - 0.012 * sin(uv.x * 15.0 + 1.0);
    col = mix(col, float3(0.0, 0.01, 0.035), smoothstep(ridge, ridge + 0.004, uv.y));
    if (water > 0.0) {
        float depth = s.uv.y - horizon;
        col = col * 0.55 + float3(0.0, 0.035, 0.05);
        // Thin glints lying on the water.
        float glint = sin(s.uv.y * 120.0 + sin(s.uv.x * 7.0 + s.t * 0.5) * 2.2);
        col += float3(0.25, 0.6, 0.6) * smoothstep(0.9, 1.0, glint) * 0.07 * smoothstep(0.0, 0.08, depth);
    }
    return col;
}

// Ember: slow plasma in browns, reds and golds, a warm heart behind the window, and sparks rising.
static float3 emberScene(SceneIn s) {
    float2 q = s.uv - s.center;
    float2 w = q * 3.0 + s.seed * 4.0;
    w += 0.35 * float2(sin(w.y * 1.7 + s.t * 0.35), cos(w.x * 1.3 - s.t * 0.28));
    float v = sin(w.x * 1.9 + s.t * 0.4) + sin(w.y * 2.3 - s.t * 0.3) + sin((w.x + w.y) * 1.4 + s.t * 0.22)
        + sin(length(w) * 2.6 - s.t * 0.5);
    v = pow(saturate(v * 0.125 + 0.5), 1.5);
    float3 col = mix(float3(0.07, 0.012, 0.0), float3(0.36, 0.04, 0.015), smoothstep(0.0, 0.35, v));
    col = mix(col, float3(0.92, 0.22, 0.04), smoothstep(0.3, 0.7, v));
    col = mix(col, float3(1.0, 0.72, 0.22), smoothstep(0.68, 1.0, v));
    // Bright veins winding through it, like cracks in cooling lava.
    float vein = 1.0 - abs(sin(w.x * 1.3 + w.y * 0.9 + 1.4 * sin(w.y * 1.1 - w.x * 0.6 + s.t * 0.2)));
    col += float3(1.0, 0.62, 0.18) * pow(vein, 9.0) * (0.25 + 0.75 * v);
    col += float3(1.0, 0.42, 0.08) * 0.32 * exp(-length(q) * 2.2);
    // An interlude sends one ring out from the heart.
    if (s.beat > 0.0) {
        float ring = (length(q) - s.beat * 0.62) / 0.035;
        col += float3(1.0, 0.8, 0.45) * exp(-ring * ring) * 0.38 * (1.0 - s.beat) * smoothstep(0.0, 0.15, s.beat);
    }
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float density = 7.0 + 5.0 * fi;
        float2 grid = float2(s.uv.x + fi * 0.37, s.uv.y + s.t * (0.11 - 0.025 * fi)) * density;
        float2 cell = floor(grid);
        float2 r = hash22(cell + fi * 19.0);
        float2 at = 0.22 + 0.56 * r;
        at.x += 0.14 * sin(s.t * (0.8 + r.y) + r.x * 6.283);
        float d = length(fract(grid) - at) / density;
        float size = 0.0026 + 0.0042 * hash21(cell + 3.3) - 0.0006 * fi;
        float lit = step(0.5, hash21(cell + 9.1 + fi));
        float glow = 0.65 + 0.35 * sin(s.t * (0.9 + 1.6 * r.x) + r.y * 40.0);
        col += float3(1.0, 0.82, 0.5) * lit * glow * smoothstep(size, size * 0.25, d) * (0.9 - 0.2 * fi);
    }
    return col;
}

static float3 sceneColor(float which, SceneIn s) {
    if (which < 0.5) { return duskScene(s); }
    if (which < 1.5) { return auroraScene(s); }
    return emberScene(s);
}

static float roundedBox(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

fragment float4 flashFragment(FlashVertexOut in [[stage_in]],
                              constant FlashUniforms &u [[buffer(0)]],
                              texture2d<float> codeTexture [[texture(0)]],
                              texture2d<float> markTexture [[texture(1)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 pixel = in.position.xy;
    float side = u.portal.z;
    float module = u.portal.w;
    float count = u.code.x;
    float quiet = u.code.y;
    float2 inPortal = pixel - u.portal.xy;
    float2 inCode = (inPortal - quiet) / module;
    bool onCode = all(inCode >= 0.0) && all(inCode < count);

    // A data slot: the window is the picture and its quiet zone, exactly.
    if (u.scenes.w > 0.5 && all(inPortal >= 0.0) && all(inPortal < side)) {
        if (onCode) { return float4(codeTexture.read(uint2(inCode)).rgb, 1.0); }
        return float4(u.light.rgb, 1.0);
    }

    // The scene.
    float width = u.screen.x;
    SceneIn s;
    s.uv = pixel / width;
    s.center = (u.portal.xy + side * 0.5) / width;
    s.reach = side * 0.5 / width;
    s.aspect = u.screen.y / width;
    s.t = u.clock.x;
    s.seed = u.clock.y;
    s.beat = u.clock.z;
    float3 col;
    float wipe = u.scenes.z;
    if (wipe <= 0.0) {
        col = sceneColor(u.scenes.x, s);
    } else {
        // An act ends: the next scene opens out of the window. Only a thin ring draws both.
        float spread = length(s.uv - s.center) / length(float2(0.5, s.aspect * 0.5) + abs(s.center - float2(0.5, s.aspect * 0.5)));
        float edge = (wipe * 1.2 - spread) / 0.06;
        if (edge >= 1.0) {
            col = sceneColor(u.scenes.y, s);
        } else if (edge <= 0.0) {
            col = sceneColor(u.scenes.x, s);
        } else {
            col = mix(sceneColor(u.scenes.x, s), sceneColor(u.scenes.y, s), smoothstep(0.0, 1.0, edge));
        }
    }
    // Darker at the corners, and behind the words at the top and the bottom.
    float2 fromMiddle = (s.uv - float2(0.5, s.aspect * 0.5)) * float2(1.0, 0.55);
    col *= 1.0 - 0.38 * smoothstep(0.35, 0.95, length(fromMiddle));
    float feather = 70.0 * u.clock.w;
    col *= mix(0.42, 1.0, smoothstep(u.screen.z - feather, u.screen.z + feather * 0.4, pixel.y));
    col *= mix(0.42, 1.0, 1.0 - smoothstep(u.screen.w - feather * 0.4, u.screen.w + feather, pixel.y));
    col *= u.state.w;

    // The window: a pale frame with rounded corners, the picture's quiet zone inside it.
    float frame = u.state.z;
    float3 light = u.light.rgb;
    float edgeDistance = roundedBox(pixel - (u.portal.xy + side * 0.5), float2(side * 0.5 + u.code.z), u.code.w);
    col += light * 0.20 * frame * u.state.w * exp(-max(edgeDistance, 0.0) / (0.05 * width));
    // With the frame gone its outline stays, so the window is still there while the scene shows through.
    float line = saturate(1.0 - abs(edgeDistance + u.clock.w) / u.clock.w);
    col = mix(col, light, line * 0.5 * (1.0 - frame) * u.state.w);
    float3 base = mix(col, light, saturate(0.5 - edgeDistance) * frame);
    if (!onCode) { return float4(saturate(base), 1.0); }

    // The wordmark on the frame, where the code has not formed yet.
    float presence = u.state.x;
    float gone = 1.0 - presence;
    float mark = markTexture.sample(linearSampler, inCode / count).r;

    // On the way to and from the scene the modules drift, each scene its own way.
    float2 at = inCode;
    float drift = gone * gone;
    if (u.scenes.x < 0.5) {
        // Dusk: rows slide apart, like the bars of its sun.
        float row = floor(inCode.y / 3.0);
        at.x += drift * 26.0 * (hash21(float2(row, 4.2)) - 0.5);
    } else if (u.scenes.x < 1.5) {
        // Aurora: columns lift, like its curtains.
        at.y += drift * (9.0 + 7.0 * sin(inCode.x * 0.21 + u.clock.x * 2.0));
    } else {
        // Ember: everything flies outward from the heart.
        float2 outward = inCode - count * 0.5;
        at -= normalize(outward + 0.001) * drift * 11.0 * (0.5 + length(outward) / count);
    }
    float2 cell = floor(at);
    float2 within = fract(at) - 0.5;
    bool real = all(cell >= 0.0) && all(cell < count);
    float3 tile = real ? codeTexture.read(uint2(cell)).rgb : light;
    float noise = hash21(cell + 0.5);

    // Reveal: the code sweeps in over the wordmark from one corner.
    float order = mix((cell.x + cell.y) / (2.0 * count), noise, 0.3);
    float formed = saturate((u.state.y * 1.16 - order) / 0.16);

    // Dissolve: each module shrinks to a round spark, in an order the scene chooses.
    float when;
    if (u.scenes.x < 0.5) {
        when = cell.y / count;
    } else if (u.scenes.x < 1.5) {
        when = 0.5 + 0.5 * sin(cell.x * 0.27 + u.clock.y * 6.0);
    } else {
        when = length(cell - count * 0.5) / (count * 0.71);
    }
    when = mix(when, noise, u.scenes.x > 0.5 && u.scenes.x < 1.5 ? 0.5 : 0.35);
    float shrink = smoothstep(when * 0.6, when * 0.6 + 0.4, gone);
    float size = 0.5 * (1.0 - shrink) * formed;
    float extent = mix(max(abs(within.x), abs(within.y)), length(within), saturate(shrink * 2.0 + (1.0 - formed)));
    float cover = saturate((size - extent) * module + 0.5) * (1.0 - shrink * shrink);
    tile = mix(tile, light, shrink * 0.35);

    float3 under = mix(base, u.dark.rgb, mark * (1.0 - formed) * frame);
    return float4(saturate(mix(under, tile, cover)), 1.0);
}
"""#
}
