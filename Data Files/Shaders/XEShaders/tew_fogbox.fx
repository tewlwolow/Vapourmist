int mgeflags = 9;
// Adapted to MGEXE by G7 and Safebox, modified by tewlwolow

// lua variables - single fog volume (mistShader.lua only ever registers
// one fog ID against this shader, so no need for a multi-slot array)
float3 fogCenter;
float3 fogRadius;
float3 fogColor;
float fogDensity;

float fognearstart;
float fognearrange;

float3 eyepos;
float4x4 mview;
float4x4 mproj;
float time;

// Sun direction/color, confirmed against Sunshafts.fx (same standalone
// post-process convention as this shader - plain uniforms, not the
// "shared" ones from XE_Common.fx). sunpos points from sun toward the
// camera, so -normalize(sunpos) is the direction toward the sun. sunvis
// is 0-1 sun visibility (occluded by horizon/weather/etc).
float3 sunpos;
float3 suncol;
float sunvis;

texture lastshader;
texture depthframe;

sampler s0 = sampler_state { texture = <lastshader>; addressu = clamp; addressv = clamp; magfilter = point; minfilter = point; };
sampler s2 = sampler_state { texture = <depthframe>; addressu = clamp; addressv = clamp; magfilter = linear; minfilter = linear; };

float4 sample0(sampler2D s, float2 t) {
    return tex2Dlod(s, float4(t, 0, 0));
}

float3 toWorld(float2 tex) {
    float3 v = float3(mview[0][2], mview[1][2], mview[2][2]);
    v += (+1/mproj[0][0] * (2*tex.x-1)).xxx * float3(mview[0][0], mview[1][0], mview[2][0]);
    v += (-1/mproj[1][1] * (2*tex.y-1)).xxx * float3(mview[0][1], mview[1][1], mview[2][1]);
    return v;
}

// -------------------------------------------------------------- //

//
// https://www.shadertoy.com/view/Ml3GR8
//
float boxDensity(float3 wpos, float3 wdir, float3 p, float3 r, float dbuffer, out float tNear) {
    tNear = 0.0;

    float3 d = wdir;
    float3 o = wpos - p;

    // ray-box intersection in box space
    float3 m = 1.0/d;
    float3 n = m*o;
    float3 k = abs(m)*r;
    float3 ta = -n - k;
    float3 tb = -n + k;
    float tN = max(max(ta.x, ta.y), ta.z);
    float tF = min(min(tb.x, tb.y), tb.z);
    if (tN > tF || tF < 0.0) return 0.0;

    // not visible (behind camera or behind dbuffer)
    if (tF < 0.0 || tN > dbuffer) return 0.0;

    // clip integration segment from camera to dbuffer
    tN = max(tN, 0.0);
    tNear = tN; // distance to where the ray enters the box - used to sample world position for the drift noise

    float waterlevel = -5.0;
    float3 waterProbe = wpos + wdir * tF;
    if (wpos.z > waterlevel && waterProbe.z < waterlevel)
        tF = (1.0 - (waterlevel-waterProbe.z) / (wpos.z-waterProbe.z)) * tF;

    tF = min(tF, dbuffer);

    // move ray to the intersection point
    o += tN*d; tF=tF-tN; tN=0.0;

    // density calculation. density is of the form
    //
    // d(x,y,z) = [1-(x/rx)^2] * [1-(y/ry)^2] * [1-(z/rz)^2];
    //
    // this can be analytically integrable (it's a degree 6 polynomial):

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

    return f;
}

// -------------------------------------------------------------- //

// Static 3-layer stack, derived from the single lua-supplied fogCenter/
// fogRadius/fogDensity. No lua/array changes needed - each layer is a
// fixed offset/scale of the same base volume, giving a low dense layer,
// a mid layer, and a thin wispy top layer instead of one uniform block.
// (Restores the old 3-slot loop shape, minus the time-based breathing -
// these offsets are static, not animated.)
static const float LAYER_CENTER_Z_FRAC[3] = { -0.5, 0.0, 0.6 };  // fraction of radius.z
static const float LAYER_RADIUS_Z_SCALE[3] = { 0.5, 0.85, 1.3 };

// Exponential height falloff (replaces the old fixed per-layer density
// weights): fog thins out the higher above the base fogCenter.z it sits,
// like real ground fog, rather than each layer having an arbitrary fixed
// opacity. Bigger = thinner fog, faster falloff with height. Tune to taste
// against your world's Z scale.
static const float HEIGHT_FALLOFF_RATE = 0.0015;

// Slow noise-driven drift. Scrolls linearly with time (not sin/cos), so it
// doesn't produce the uniform screen-wide brightness pulsing that caused
// the original flicker - it's spatial noise sliding past, not a global
// oscillation. DRIFT_SPEED is in world units/sec (same units as position),
// and gets scaled into noise-space together with position below - it must
// NOT be added post-scale, or the pattern scrolls a full noise cell every
// fraction of a second.
static const float NOISE_SCALE = 0.00035;
static const float2 DRIFT_SPEED = float2(40.0, 22.0); // world units/sec - gentle drift
static const float DRIFT_MIN = 0.8;
static const float DRIFT_MAX = 1.2;

// Cheap forward-scatter approximation: fog brightens/warms when looking
// toward the sun, like real dawn/dusk mist. Uses the actual sun color
// (suncol) rather than a guessed tint. Exponent controls the halo's
// tightness - lower = broader, softer glow (more like sunshafts falloff),
// higher = a tighter hotspot right around the sun.
static const float SUN_GLOW_EXPONENT = 4.0;
static const float SUN_GLOW_STRENGTH = 0.6;

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

// Interleaved gradient noise - per-pixel pseudo-random dither that never
// tiles visibly (unlike a small ordered/Bayer matrix, which becomes its
// own visible pattern over large flat fog regions). Same cost as the old
// matrix lookup, no extra texture needed.
// http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare
float interleavedGradientNoise(float2 vpos) {
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return frac(magic.z * frac(dot(vpos, magic.xy)));
}

float4 draw(float2 tex : TEXCOORD, float2 vpos : VPOS) : COLOR0 {
    float3 color = tex2D(s0, tex);
    float depth = sample0(s2, tex);

    float3 pos = eyepos;
    float3 dir = toWorld(tex);

    // gamma -> linear
    color = pow(color, 2.2);

    // sun-relative glow: computed once per pixel, same for every layer,
    // since it only depends on view direction vs sun direction.
    // normalize(sunpos) is the direction toward the sun. dir must be
    // normalized before the dot product too - toWorld() returns a
    // direction whose length varies across the screen (perspective), and
    // dotting an unnormalized vector against sunDir stretches the glow
    // asymmetrically with aspect ratio, turning a round halo into a
    // horizontal streak once raised to a high power. sunvis fades the
    // glow out when the sun is occluded (below horizon, weather, etc).
    float3 dirN = normalize(dir);
    float3 sunDir = (dot(sunpos, sunpos) > 0.0001) ? normalize(sunpos) : float3(0, 0, 1);
    float sunDot = saturate(dot(dirN, sunDir));
    float sunGlow = pow(sunDot, SUN_GLOW_EXPONENT) * SUN_GLOW_STRENGTH * saturate(sunvis);
    float3 litFogColor = saturate(fogColor + suncol * sunGlow);

    // draw the fog as 3 stacked static layers (low/dense, mid, high/wispy)
    // built from the single lua-supplied fogCenter/fogRadius/fogDensity
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
                // apply lua config
                float fogScalar = 1.0 / sqrt(dot(radius, radius));
                density = density * fogScalar * fogDensity;

                // exponential height falloff above the base fogCenter.z
                float heightAboveBase = max(0.0, center.z - fogCenter.z);
                density *= exp(-heightAboveBase * HEIGHT_FALLOFF_RATE);

                // slow drifting noise, sampled at the world XY where the
                // ray enters this layer, scrolled linearly by time - both
                // position and drift are scaled into noise-space together
                float3 entryPos = pos + dir * tNear;
                float2 driftUV = (entryPos.xy + time * DRIFT_SPEED) * NOISE_SCALE;
                float n = noise2D(driftUV);
                density *= lerp(DRIFT_MIN, DRIFT_MAX, n);

                // do the fog stuff
                color = lerp(litFogColor * litFogColor, color, exp(-0.5 * density));
            }
        }
    }


    // linear -> gamma
    color = pow(color, 1/2.2);

    // dithering!
    float dithering = (interleavedGradientNoise(vpos) - 0.5) / 128.0;
    color += dithering;

    return float4(color, 1.0);
}

technique T0<string MGEinterface = "MGE XE 0"; string category = "atmosphere";> {
    pass { PixelShader = compile ps_3_0 draw(); }
}
