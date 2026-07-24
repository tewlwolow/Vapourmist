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

// ---------------- dust controls ----------------

// Density:
// 0   = no particles
// 20  = maximum particles
float dustDensity = 5.5;

// Particle size multiplier
float dustSize = 2.9;

// Distance between particle cells
float dustCellSize = 43.0;

// Animation speed
float dustTimeScale = 0.12;

// Movement amplitude
float dustMotionScale = 6.0;

// Particle shape:
// 1 = diamond
// 2 = sphere
// 4+ = cube-like
float dustShape = 1.5;

// Raymarch limits
float dustMaxDistance = 1200.0;
float dustSurfaceDistance = 0.01;

// Fade controls
float dustFadeStart = 20.0;
float dustFadeEnd = 80.0;

// Material threshold
// Lower = more particles visible
// Higher = only brighter particles
float dustMaterialBias = 0.25;

// Dust visibility / brightness
// 0   = invisible
// 1   = old strength
// 0.15-0.35 = natural cave dust
float dustOpacity = 0.18;

// Neutral fallback color used when no fog volume is nearby (avoids dust
// tinting toward black - see dustTint fallback in the main pass).
float3 dustBaseColor = float3(0.85, 0.82, 0.75);

// How much the particle shape exponent (dustShape) varies per-particle.
// 0 = every particle uses exactly dustShape. Higher = more mix of
// diamond/sphere/cube-ish silhouettes for a less uniform look.
float dustShapeVariation = 0.7;

// How much particle opacity varies per-particle, as a fraction of
// dustOpacity. 0 = every particle equally opaque. 1 = some particles
// can fade almost to nothing while others hit full dustOpacity.
float dustOpacityVariation = 0.7;

// -- fogbox params --
// Single fog volume, matching tew_fogbox.fx - interior.lua only ever
// registers one fog ID against this shader, so no array/indexing needed.
float3 fogCenter;
float3 fogRadius;
float3 fogColor;
float fogDensity;

// Ground-hugging mist: thins fog toward the top of its volume so it
// pools near the floor like real cave mist, rather than sitting as a
// uniform density block top to bottom.
// 0 = uniform density (old behavior), 1 = fully thins out at the top.
float fogHeightFalloff = 0.8;

// Cheap 3D value noise breaks up the smooth analytic box gradient into
// wispy/patchy variation, sampled once per pixel at the actual visible
// surface position (reconstructed from the depth buffer), and slowly
// scrolled over time so the patchiness itself drifts like real fog would.
// Overall multiplier on final fog density - an easy dial to make fog
// lighter/heavier without needing to touch the fogDensity data itself.
float fogDensityScale = 0.60;

// 0 = perfectly smooth (old behavior), higher = patchier/wispier.
// Biased toward thinning rather than symmetric thicken/thin - real fog
// reads as mostly-thin with occasional denser wisps, not oscillating
// evenly above and below a baseline.
float fogNoiseStrength = 0.55;
float fogNoiseScale = 0.018;   // world-space frequency - lower = larger wisps

// Organic swirling drift for the fog's internal noise pattern - built
// from several independent sine terms at different speeds/phases so it
// changes direction over time instead of scrolling in one straight line.
// Depends only on `time`, never on eyepos/camera position, so it can't
// read as tied to player movement.
float fogFlowStrength = 800.0;  // world-unit-equivalent amplitude of the swirl
float fogFlowSpeed = 0.06;     // how fast the swirl evolves

// ---------------- constants ----------------

static const float2 invproj = 2.0 * tan(0.5 * radians(fov)) * float2(1.0, rcpres.x / rcpres.y);
static const float3 spherePosBase = float3(-24900.0, -13000.0, 0.0);

// Ordered dithering matrix
static const float DITHERING[4][4] = {
    0.001176, 0.001961, -0.001176, -0.001699,
    -0.000654, -0.000915, 0.000392, 0.000131,
    -0.000131, -0.001961, 0.000654, 0.000915,
    0.001699, 0.001438, -0.000392, -0.001438
};

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

// Cheap value noise for fog patchiness - trilinear interpolation over
// 8 hashed cell corners. Only evaluated 3x per pixel (once per fog
// volume), not per raymarch step, so this stays affordable.
float hashFog(float3 p) {
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noiseFog(float3 p) {
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float n000 = hashFog(i + float3(0,0,0));
    float n100 = hashFog(i + float3(1,0,0));
    float n010 = hashFog(i + float3(0,1,0));
    float n110 = hashFog(i + float3(1,1,0));
    float n001 = hashFog(i + float3(0,0,1));
    float n101 = hashFog(i + float3(1,0,1));
    float n011 = hashFog(i + float3(0,1,1));
    float n111 = hashFog(i + float3(1,1,1));

    float nx00 = lerp(n000, n100, f.x);
    float nx10 = lerp(n010, n110, f.x);
    float nx01 = lerp(n001, n101, f.x);
    float nx11 = lerp(n011, n111, f.x);

    float nxy0 = lerp(nx00, nx10, f.y);
    float nxy1 = lerp(nx01, nx11, f.y);

    return lerp(nxy0, nxy1, f.z);
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

    float3 cellIndex = floor((p + eyepos) * invCell);

    float3 h = frac(cellIndex * 0.3183099 + 0.1) * 17.0;

    float r1 = frac(h.x * h.y * h.z * (h.x + h.y + h.z));


    float timeFactor = time * dustTimeScale + r1 * 6.2831;

    float3 phase =
        float3(
            -24900.0 * 0.5,
            -13000.0 * 0.4,
            0.0
        )
        +
        timeFactor * float3(1.0,1.3,0.9);


    float3 sphereOffset =
        (abs(frac(phase * 0.159155) * 4.0 - 2.0) - 1.0)
        * dustMotionScale;


    float3 basePos = float3(-24900.0,-13000.0,0.0);

    float3 q =
        p -
        (basePos + 2.0 + sphereOffset)
        +
        eyepos;


    q = frac(q * invCell) * dustCellSize
        - dustCellSize * 0.5;


    float radius =
        (0.1 + 0.4 * frac(r1 * 43.123))
        * dustSize;


    // Continuous density: scales particle size smoothly rather than
    // gating whole cells on/off, so raising/lowering dustDensity reads
    // as a genuine density gradient instead of patches popping in/out.
    float densityScale = saturate(dustDensity / 20.0);
    radius *= densityScale;

    // Per-particle shape variation: jitter the superellipsoid exponent
    // around dustShape so particles aren't all identical silhouettes.
    float shapeJitter = (frac(r1 * 29.71) - 0.5) * 2.0 * dustShapeVariation;
    float shapeN = max(1.0, dustShape + shapeJitter);

    return sdSuperShape(q,radius,shapeN);
}

// VISUALS ONLY (Executed ONCE outside the loop)
float GetMaterial(float3 p)
{
    float invCell = 1.0 / dustCellSize;

    float3 cellIndex =
        floor((p + eyepos) * invCell);


    float3 h =
        frac(cellIndex * 0.3183099 + 0.1)
        * 17.0;


    float r1 =
        frac(h.x*h.y*h.z*(h.x+h.y+h.z));


    float timeFactor =
        time*dustTimeScale + r1*6.2831;


    float3 phase =
        float3(-24900.0*0.5,
               -13000.0*0.4,
               0.0)
        +
        timeFactor*float3(1.0,1.3,0.9);


    float3 sphereOffset =
        abs(frac(phase*0.159155)*4.0-2.0)-1.0;


    return smoothstep(
            0.0,
            1.0,
            sphereOffset.x+
            sphereOffset.y+
            sphereOffset.z
        );
}

float RayMarch(float3 ro,float3 rd)
{
    float dO=0;

    [loop]
    for(int i=0;i<200;i++)
    {
        float3 p=ro+dO*rd;

        float dS=GetDistOnly(p);

        dO+=dS;

        if(dS<dustSurfaceDistance ||
           dO>dustMaxDistance)
            break;
    }

    return dO;
}

// ---------------- fogbox: box density ----------------

// https://www.shadertoy.com/view/Ml3GR8 (ray-box intersection only - the
// original closed-form density integral below was replaced with a short
// raymarch, see comment further down for why)
float boxDensity(float3 wpos, float3 wdir, float3 p, float3 r, float dbuffer) {
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

    float wl = waterlevel - 5;
    float3 waterProbe = wpos + wdir * tF;
    if (wpos.z > wl && waterProbe.z < wl)
        tF = (1.0 - (wl-waterProbe.z) / (wpos.z-waterProbe.z)) * tF;

    tF = min(tF, dbuffer);

    if (tF <= tN) return 0.0;

    // Short raymarch through the box interval instead of the old smooth
    // closed-form integral: that approach could only ever multiply a
    // single flat noise value onto the whole ray's aggregate density,
    // which can't actually break up a shape that's still a hard analytic
    // box underneath - it just flickered the box's overall opacity.
    // Sampling noise (and an edge falloff) at several actual positions
    // along the ray gives real per-position variation, and rounding the
    // box's corners via distance-from-center falloff keeps it from
    // reading as a rigid rectangle.
    static const int FOG_SAMPLES = 6;
    float stepSize = (tF - tN) / FOG_SAMPLES;

    // Swirling flow offset - purely a function of time, so it's identical
    // regardless of where the camera is standing or looking. Several
    // sine terms at different speeds/phases per axis avoid a straight-
    // line drift, giving an organic, direction-changing "swerve" instead.
    float ft = time * fogFlowSpeed;
    float3 flowOffset = float3(
        sin(ft * 1.0 + 1.3) * 0.7 + cos(ft * 0.63 + 4.1) * 0.5,
        cos(ft * 0.81 + 2.7) * 0.7 + sin(ft * 0.45 + 0.6) * 0.5,
        sin(ft * 0.54 + 3.9) * 0.4
    ) * fogFlowStrength;

    float accum = 0.0;
    [unroll]
    for (int s = 0; s < FOG_SAMPLES; s++) {
        float t = tN + stepSize * (s + 0.5);
        float3 samplePos = wpos + wdir * t;

        // Position relative to box center - small, stable magnitude
        // (unlike raw wpos/samplePos, which can be tens of thousands of
        // world units and suffer float precision loss when hashed, which
        // reads as noise "swimming" with camera movement).
        float3 localSamplePos = samplePos - p;

        // Position within the box in -1..1 local space, used to round the
        // silhouette off into more of a soft blob than a hard rectangle.
        float3 localPos = localSamplePos / r;
        float edgeFalloff = saturate(1.0 - dot(localPos, localPos));

        float noiseVal = noiseFog((localSamplePos + flowOffset) * fogNoiseScale);
        // Biased toward thinning (never exceeds baseline) rather than
        // symmetric thicken/thin - reads as patchy wisps, not pulsing.
        float localDensity = lerp(1.0 - fogNoiseStrength, 1.0, noiseVal) * edgeFalloff;

        // Ground-hugging mist: thin toward the top of the volume.
        float heightNorm = saturate((samplePos.z - (p.z - r.z)) / max(0.01, r.z * 2.0));
        localDensity *= lerp(1.0, 1.0 - fogHeightFalloff, heightNorm);

        accum += localDensity * stepSize;
    }

    accum *= fogDensityScale;

    return accum;
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

    float d = RayMarch(ro, rd);
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
        float opacitySeed = frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
        float opacityMult = lerp(1.0 - dustOpacityVariation, 1.0, opacitySeed);

        float dustAmount =
            smoothstep(dustFadeStart,dustFadeEnd,d)
            *
            saturate(sp-dustMaterialBias)
            *
            dustOpacity
            *
            opacityMult;

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

    // Single fog volume - interior.lua only ever registers one (FOG_ID
    // "tew_interior").
    if (fogDensity > 0.0) {
        float density = boxDensity(pos, dir, fogCenter, fogRadius, depth);
        if (density > 0.0) {
            float fogScalar = 1.0 / sqrt(dot(fogRadius, fogRadius));
            density = density * fogScalar * fogDensity;

            color = lerp(fogColor * fogColor, color, exp(-0.5 * density));
        }
    }

    // linear -> gamma
    color = pow(color, 1.0/2.2);

    // dithering
    float dithering = DITHERING[vpos.x % 4][vpos.y % 4];
    color += dithering;

    return float4(color, 1.0);
}

technique T0 < string MGEinterface = "MGE XE 0"; string category = "atmosphere"; >
{
    pass { PixelShader = compile ps_3_0 dustfog(); }
}
