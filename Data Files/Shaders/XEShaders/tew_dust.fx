int mgeflags = 14;

// ============================================================
// Combined underwater/cave dust raymarch + volumetric fogbox
// Dust:    vtastek v0.01a
// Fogbox:  G7 & Safebox, adapted to MGEXE by tewlwolow
// Merge:   dust is resolved first (feeds its result as the
//          "scene color" into the fog pass, exactly the way
//          the original dust shader consumes lastshader).
// ============================================================

// ---------------- shared / lua-exposed params ----------------

float time;
float3 eyepos, eyevec;
float4x4 mview;
float4x4 mproj;
float waterlevel = 0.0;

float fognearstart, fognearrange;

// -- dust params --
float3 sunpos;
float2 rcpres;
float3 fognearcol;
float fov;

// ---------------- dust controls ----------------

// Density:
// 0   = no particles
// 20  = maximum particles
float dustDensity = 1.0;

// Particle size multiplier
float dustSize = 3.0;

// Distance between particle cells
float dustCellSize = 32.0;

// Animation speed
float dustTimeScale = 0.12;

// Movement amplitude
float dustMotionScale = 6.0;

// Particle shape:
// 1 = diamond
// 2 = sphere
// 4+ = cube-like
float dustShape = 1.9;

// Raymarch limits
float dustMaxDistance = 1200.0;
float dustSurfaceDistance = 0.01;

// Fade controls
float dustFadeStart = 20.0;
float dustFadeEnd = 80.0;

// Material threshold
// Lower = more particles visible
// Higher = only brighter particles
float dustMaterialBias = 0.4;

// Dust visibility / brightness
// 0   = invisible
// 1   = old strength
// 0.15-0.35 = natural cave dust
float dustOpacity = 0.17;

// Neutral fallback color used when no fog volume is nearby (avoids dust
// tinting toward black - see dustTint fallback in the main pass).
float3 dustBaseColor = float3(0.85, 0.82, 0.75);

// How much the particle shape exponent (dustShape) varies per-particle.
// 0 = every particle uses exactly dustShape. Higher = more mix of
// diamond/sphere/cube-ish silhouettes for a less uniform look.
float dustShapeVariation = 0.35;

// How much particle opacity varies per-particle, as a fraction of
// dustOpacity. 0 = every particle equally opaque. 1 = some particles
// can fade almost to nothing while others hit full dustOpacity.
float dustOpacityVariation = 0.3;

// Static height falloff: dust thins out with height above the floor,
// scaled against the fog volume's own vertical extent (fogRadius.z)
// rather than a fixed world-unit rate - a fixed rate would be wildly
// too strong or too weak depending on how tall a given interior's fog
// volume actually is, since room sizes vary a lot.
// dustHeightFalloffRange: falloff completes over this many multiples of
// fogRadius.z above the floor. Smaller = falloff happens closer to the
// ground, larger = dust stays visible higher up.
// dustHeightFalloffStrength: how much dust is reduced at the top of
// that range. 1.0 = fully gone, 0.5 = only halved. Capped below 1 by
// default so dust never fully vanishes, just thins.
float dustHeightFalloffRange = 1.5;
float dustHeightFalloffStrength = 0.65;

// Makes particles genuinely bigger (real SDF geometry, not just less
// transparent) near the floor, so dust reads as visibly pooled/settled
// there even when looking straight down - a short vertical raymarch has
// far fewer chances to hit a particle than a long horizontal one, so
// opacity alone can't fix that; the particles themselves need to be
// larger/denser near the ground to be reliably hit at all.
// 0 = no boost, higher = more dramatic pooling near the floor.
float dustPoolingBoost = 1.5;

// -- fogbox params --
// Single fog volume, matching tew_fogbox.fx - interior.lua only ever
// registers one fog ID against this shader, so no array/indexing needed.
float3 fogCenter;
float3 fogRadius;
float3 fogColor;
float fogDensity;

// Overall multiplier on final fog density - an easy dial to make fog
// lighter/heavier without needing to touch the fogDensity data itself.
float fogDensityScale = 0.60;

// ---------------- constants ----------------

static const float2 invproj = 2.0 * tan(0.5 * radians(fov)) * float2(1.0, rcpres.x / rcpres.y);
static const float3 spherePosBase = float3(-24900.0, -13000.0, 0.0);

// Static 3-layer stack, derived from the single fogCenter/fogRadius/
// fogDensity - each layer is a fixed offset/scale of the same base
// volume, giving a low dense layer, a mid layer, and a thin wispy top
// layer instead of one uniform block. No raymarch, no per-frame
// breathing - purely static geometry, animated only via the drift
// noise below.
static const float LAYER_CENTER_Z_FRAC[3] = { -0.6, 0.2, 1.1 };  // fraction of radius.z
static const float LAYER_RADIUS_Z_SCALE[3] = { 0.6, 1.0, 1.8 };

// Exponential height falloff: fog thins out the higher above the base
// fogCenter.z it sits, like real ground fog. Bigger = thinner fog,
// faster falloff with height. Bottom layer (LAYER_CENTER_Z_FRAC[0] is
// negative, i.e. below fogCenter.z) is never affected - only the mid/
// high layers thin out, giving the fog a settled, ground-hugging look.
// At typical interior fogRadius.z, this rate puts the mid layer at
// roughly 70% and the top layer at roughly 15% of base density.
static const float HEIGHT_FALLOFF_RATE = 0.0044;

// Slow noise-driven drift. Scrolls linearly with time (not sin/cos), so
// it doesn't produce a uniform screen-wide pulsing - it's spatial noise
// sliding past, not a global oscillation.
static const float NOISE_SCALE = 0.00035;
static const float2 DRIFT_SPEED = float2(40.0, 22.0); // world units/sec
static const float DRIFT_MIN = 0.8;
static const float DRIFT_MAX = 1.2;

// Interleaved gradient noise - per-pixel pseudo-random dither that never
// tiles visibly (unlike a small ordered/Bayer matrix, which becomes its
// own visible pattern over large flat regions). Same cost as the old
// matrix lookup, no extra texture needed.
// http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare
float interleavedGradientNoise(float2 vpos) {
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return frac(magic.z * frac(dot(vpos, magic.xy)));
}

// ---------------- textures ----------------

texture lastshader;
texture depthframe;

sampler s0 = sampler_state { texture = <lastshader>; addressu = clamp; addressv = clamp; magfilter = point;  minfilter = point;  };
sampler s2 = sampler_state { texture = <depthframe>;  addressu = clamp; addressv = clamp; magfilter = linear; minfilter = linear; };

// ---------------- shared helpers ----------------

float4 sample0(sampler2D s, float2 t) {
    return tex2Dlod(s, float4(t, 0.0, 0.0));
}

float3 toView(float2 tex) {
    float depth = sample0(s2, tex).r;
    float2 xy = depth * (tex - 0.5) * invproj;
    return float3(xy, depth);
}

float3 toWorld(float2 tex) {
    float3 v = float3(mview[0][2], mview[1][2], mview[2][2]);
    v += (1.0/mproj[0][0] * (2.0*tex.x-1.0)).xxx * float3(mview[0][0], mview[1][0], mview[2][0]);
    v += (-1.0/mproj[1][1] * (2.0*tex.y-1.0)).xxx * float3(mview[0][1], mview[1][1], mview[2][1]);
    return v;
}

// Cheap 2D drift noise for fog patchiness - sampled once per layer at
// the point the ray enters the box, not per raymarch step, so this
// stays cheap regardless of box size.
float hash21(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// ---------------- dust: distance field ----------------

float sdSuperShape(float3 p, float r, float n)
{
    return pow(
        pow(abs(p.x), n) +
        pow(abs(p.y), n) +
        pow(abs(p.z), n),
        1.0 / n
    ) - r;
}

// STRIPPED DOWN INNER MATH - No trig, no branches.
float GetDistOnly(float3 p)
{
    float invCell = 1.0 / dustCellSize;
    float3 basePos = float3(-24900.0, -13000.0, 0.0);

    // Define particle identity and local coordinates from the SAME grid.
    // Do not wrap coordinates after applying animated offsets: that makes
    // the seed/shape jump at cell boundaries and can create flickering.
    float3 gridPos = (p + eyepos - basePos - 2.0) * invCell;
    float3 cellIndex = floor(gridPos);
    float3 q = (frac(gridPos) - 0.5) * dustCellSize;

    float3 h = frac(cellIndex * 0.3183099 + 0.1) * 17.0;
    float r1 = frac(h.x * h.y * h.z * (h.x + h.y + h.z));

    // Smooth, deterministic per-particle movement within its own cell.
    float timeFactor = time * dustTimeScale + r1 * 6.2831;
    float3 phase = float3(-12450.0, -5200.0, 0.0)
                 + timeFactor * float3(1.0, 1.3, 0.9);
    float3 sphereOffset =
        (abs(frac(phase * 0.159155) * 4.0 - 2.0) - 1.0)
        * dustMotionScale;
    q -= sphereOffset;

    float radius = (0.1 + 0.4 * frac(r1 * 43.123)) * dustSize;
    float densityScale = saturate(dustDensity / 20.0);
    radius *= densityScale;

    float worldZ = p.z + eyepos.z;
    float heightAboveFloor = max(0.0, worldZ - fogCenter.z);
    float heightRange = max(1.0, fogRadius.z * dustHeightFalloffRange);
    float heightNorm = saturate(heightAboveFloor / heightRange);
    float poolBoost = lerp(1.0 + dustPoolingBoost, 1.0,
                           smoothstep(0.0, 1.0, heightNorm));
    radius *= poolBoost;

    float shapeJitter = (frac(r1 * 29.71) - 0.5) * 2.0 * dustShapeVariation;
    float shapeN = max(1.0, dustShape + shapeJitter);

    float dist = sdSuperShape(q, radius, shapeN);
    return dist;
}

// VISUALS ONLY (Executed ONCE outside the loop)
float GetMaterial(float3 p)
{
    float invCell = 1.0 / dustCellSize;
    float3 basePos = float3(-24900.0, -13000.0, 0.0);
    float3 gridPos = (p + eyepos - basePos - 2.0) * invCell;
    float3 cellIndex = floor(gridPos);

    float3 h = frac(cellIndex * 0.3183099 + 0.1) * 17.0;
    float r1 = frac(h.x * h.y * h.z * (h.x + h.y + h.z));

    // Constant over the particle; no spatial mask, so it cannot create
    // holes inside the mote. The same seed identifies the geometry above.
    return lerp(0.85, 1.0, frac(r1 * 37.719));
}

float RayMarch(float3 ro, float3 rd, float maxRange)
{
    float dO = 0.0;

    [loop]
    for (int i = 0; i < 128; i++)
    {
        float3 p = ro + dO * rd;
        float dS = GetDistOnly(p);

        // A hit is detected before stepping. Conservative stepping reduces
        // overshoot from the approximate super-shape distance estimator.
        if (dS <= dustSurfaceDistance)
            return dO;

        dO += max(dS * 0.5, dustSurfaceDistance * 0.5);
        if (dO > maxRange)
            return dO;
    }

    // If all iterations are used without finding a surface, report a miss.
    // Returning dO here falsely treats the last ray position as a particle
    // hit, which can create a large phantom/moving shape that masks other motes.
    return maxRange + max(1.0, dustSurfaceDistance);
}

// ---------------- fogbox: box density ----------------

// https://www.shadertoy.com/view/Ml3GR8
float boxDensity(float3 wpos, float3 wdir, float3 p, float3 r, float dbuffer, out float tNear) {
    tNear = 0.0;

    float3 d = wdir;
    float3 o = wpos - p;

    float3 m = 1.0/d;
    float3 n = m*o;
    float3 k = abs(m)*r;
    float3 ta = -n - k;
    float3 tb = -n + k;
    float tN = max(max(ta.x, ta.y), ta.z);
    float tF = min(min(tb.x, tb.y), tb.z);
    if (tN > tF || tF < 0.0) return 0.0;

    if (tF < 0.0 || tN > dbuffer) return 0.0;

    tN = max(tN, 0.0);
    tNear = tN; // distance to where the ray enters the box - used to sample world position for the drift noise

    float wl = waterlevel - 5;
    float3 waterProbe = wpos + wdir * tF;
    if (wpos.z > wl && waterProbe.z < wl)
        tF = (1.0 - (wl-waterProbe.z) / (wpos.z-waterProbe.z)) * tF;

    tF = min(tF, dbuffer);

    o += tN*d; tF = tF-tN; tN = 0.0;

    float3 a = 1.0-(o*o)/(r*r);
    float3 b = -2.0*(o*d)/(r*r);
    float3 c = -(d*d)/(r*r);

    float t1 = tF;
    float t2 = t1*t1;
    float t3 = t2*t1;
    float t4 = t2*t2;
    float t5 = t2*t3;
    float t6 = t3*t3;
    float t7 = t3*t4;

    float f = (t1/1.0) * (a.x*a.y*a.z)
            + (t2/2.0) * (a.x*a.y*b.z + a.x*b.y*a.z + b.x*a.y*a.z)
            + (t3/3.0) * (a.x*a.y*c.z + a.x*b.y*b.z + a.x*c.y*a.z + b.x*a.y*b.z + b.x*b.y*a.z + c.x*a.y*a.z)
            + (t4/4.0) * (a.x*b.y*c.z + a.x*c.y*b.z + b.x*a.y*c.z + b.x*b.y*b.z + b.x*c.y*a.z + c.x*a.y*b.z + c.x*b.y*a.z)
            + (t5/5.0) * (a.x*c.y*c.z + b.x*b.y*c.z + b.x*c.y*b.z + c.x*a.y*c.z + c.x*b.y*b.z + c.x*c.y*a.z)
            + (t6/6.0) * (b.x*c.y*c.z + c.x*b.y*c.z + c.x*c.y*b.z)
            + (t7/7.0) * (c.x*c.y*c.z);

    return f * fogDensityScale;
}


// ---------------- combined pass ----------------

float4 dustfog(float2 tex : TEXCOORD0, float2 vpos : VPOS) : COLOR0 {

    float4 scenecol = sample0(s0, tex);
    float3 v = toWorld(tex);           // un-normalized world ray (used by both passes)
    float depth = sample0(s2, tex).r;  // shared depth buffer sample

    // Fog color used to tint dust particles so they match the current
    // fog volume. Falls back to dustBaseColor when there's little/no
    // fog nearby, instead of tinting toward black.
    float fogInfluence = saturate(fogDensity);
    float3 dustTint = lerp(dustBaseColor, fogColor, fogInfluence);
    float3 dustTintLinear = dustTint * dustTint; // approx gamma->linear, matches the fog pass below

    // ================= DUST PASS =================
    float dm = length(toView(tex));
    float3 ro = float3(0.0, 0.0, 0.0);
    float3 rd = normalize(v);

    // Capping the march at dm (the actual visible surface depth) rather
    // than always marching to dustMaxDistance is a free win, not a
    // visual tradeoff: the check below already discards any result with
    // d >= dm (dust behind the wall/floor isn't drawn), so continuing to
    // march past that point was always wasted work - this just stops
    // sooner instead of computing a result that gets thrown away.
    // Especially significant for interiors, where dm (room depth) is
    // usually far smaller than dustMaxDistance (1200).
    float d = RayMarch(ro, rd, min(dustMaxDistance, dm));
    float3 p = ro + rd * d;

    float3 col;
    if (d > dustMaxDistance || dm < d) {
        col = scenecol.rgb;
    }
    else {
        float sp = GetMaterial(p);

        // Per-particle opacity variation: unique deterministic factor
        // from this particle's world position, so neighboring motes
        // don't all render at identical strength.
        float opacityMult = 1.0; // Stable opacity while diagnosing/fixing surface flicker.

        // Static height falloff: thins dust with height above the floor,
        // same reference (fogCenter.z) as the fog volume - concentrates
        // dust near the ground like it's settled there, no animation.
        // Normalized against fogRadius.z so it auto-scales with however
        // tall this interior's fog volume actually is.
        float worldZ = p.z + eyepos.z;
        float heightAboveFloor = max(0.0, worldZ - fogCenter.z);
        float heightRange = max(1.0, fogRadius.z * dustHeightFalloffRange);
        float heightNorm = saturate(heightAboveFloor / heightRange);
        float heightFalloff = lerp(1.0, 1.0 - dustHeightFalloffStrength, smoothstep(0.0, 1.0, heightNorm));

        float dustAmount =
            smoothstep(dustFadeStart,dustFadeEnd,d)
            *
            saturate(sp-dustMaterialBias)
            *
            dustOpacity
            *
            opacityMult
            *
            heightFalloff;

        float3 sceneLinear = pow(scenecol.rgb,2.2);

        float distanceFade =
            1.0 - saturate(d / dustMaxDistance);

        dustAmount *= distanceFade;

        // subtle fog-colored particle tint
        float3 dustColor =
            dustTintLinear * dustAmount;

        // blend dust into scene
        float3 linCol = sceneLinear + dustColor;
        col = pow(linCol, 1.0/2.2); // back to gamma space so it matches scenecol for the fog pass below
    }

    // ================= FOG PASS =================
    float3 color = col;
    float3 pos = eyepos;
    float3 dir = v;

    // gamma -> linear
    color = pow(color, 2.2);

    // Draw the fog as 3 stacked static layers (low/dense, mid, high/wispy)
    // built from the single lua-supplied fogCenter/fogRadius/fogDensity -
    // interior.lua only ever registers one fog volume (FOG_ID "tew_interior").
    if (fogDensity > 0.0) {
        [unroll]
        for (int i = 0; i < 3; i++) {
            float3 center = fogCenter;
            center.z += LAYER_CENTER_Z_FRAC[i] * fogRadius.z;

            float3 radius = fogRadius;
            radius.z *= LAYER_RADIUS_Z_SCALE[i];

            float tNear;
            float density = boxDensity(pos, dir, center, radius, depth, tNear);
            if (density > 0.0) {
                float fogScalar = 1.0 / sqrt(dot(radius, radius));
                density = density * fogScalar * fogDensity;

                // exponential height falloff above the base fogCenter.z
                float heightAboveBase = max(0.0, center.z - fogCenter.z);
                density *= exp(-heightAboveBase * HEIGHT_FALLOFF_RATE);

                // slow drifting noise, sampled at the world XY where the
                // ray enters this layer, scrolled linearly by time
                float3 entryPos = pos + dir * tNear;
                float2 driftUV = (entryPos.xy + time * DRIFT_SPEED) * NOISE_SCALE;
                float n = noise2D(driftUV);
                density *= lerp(DRIFT_MIN, DRIFT_MAX, n);

                color = lerp(fogColor * fogColor, color, exp(-0.5 * density));
            }
        }
    }

    // linear -> gamma
    color = pow(color, 1.0/2.2);

    // dithering
    float dithering = (interleavedGradientNoise(vpos) - 0.5) / 128.0;
    color += dithering;

    return float4(color, 1.0);
}

technique T0 < string MGEinterface = "MGE XE 0"; string category = "atmosphere"; >
{
    pass { PixelShader = compile ps_3_0 dustfog(); }
}
