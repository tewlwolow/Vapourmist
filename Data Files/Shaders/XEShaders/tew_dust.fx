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
float dustDensity = 6.0;

// Particle size multiplier
float dustSize = 1.5;

// Distance between particle cells
float dustCellSize = 40.0;

// Animation speed
float dustTimeScale = 0.15;

// Movement amplitude
float dustMotionScale = 6.0;

// Particle shape:
// 1 = diamond
// 2 = sphere
// 4+ = cube-like
float dustShape = 1.85;

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
float dustOpacity = 0.25;

// Neutral fallback color used when no fog volume is nearby (avoids dust
// tinting toward black - see dustTint fallback in the main pass).
float3 dustBaseColor = float3(0.85, 0.82, 0.75);

// How much the particle shape exponent (dustShape) varies per-particle.
// 0 = every particle uses exactly dustShape. Higher = more mix of
// diamond/sphere/cube-ish silhouettes for a less uniform look.
float dustShapeVariation = 0.9;

// How much particle opacity varies per-particle, as a fraction of
// dustOpacity. 0 = every particle equally opaque. 1 = some particles
// can fade almost to nothing while others hit full dustOpacity.
float dustOpacityVariation = 0.5;

// Wind gusts: periodically sweeps ALL particles together in a shared
// direction (layered on top of each particle's own independent drift),
// and briefly stirs up extra density while a gust is active - distinct
// from the per-particle jitter, which never moves particles as a group.
float3 dustWindDir = float3(1.0, 0.3, 0.0); // world-space direction, doesn't need to be normalized
float dustGustStrength = 30.0;              // world units of displacement at peak gust
float dustGustSpeed = 0.7;                  // how fast gusts cycle
float dustGustDensityBoost = 0.9;           // extra density multiplier at peak gust (stirred-up dust)

// -- fogbox params --
static const float NUM_FOG_VOLUMES = 3;
float fogCenters[NUM_FOG_VOLUMES][3];
float fogRadi[NUM_FOG_VOLUMES][3];
float fogColors[NUM_FOG_VOLUMES][3];
float fogDensities[NUM_FOG_VOLUMES];

// Horizontal gust drift on top of the existing vertical bob (center.z
// already oscillates via cos/sin above) - makes the fog feel pushed
// around by wind instead of just breathing up and down in place.
// Bounded oscillation like the existing motion, not unbounded drift.
float fogGustAmount = 40.0;   // world units of horizontal sway
float fogGustSpeed = 0.15;    // how fast the sway cycles

// Cheap 3D value noise breaks up the smooth analytic box gradient into
// wispy/patchy variation, sampled once per fog volume at roughly where
// the camera ray enters that volume, and slowly scrolled over time so
// the patchiness itself drifts like real fog would.
// 0 = perfectly smooth (old behavior), higher = patchier/wispier.
float fogNoiseStrength = 0.24;
float fogNoiseScale = 0.042;   // world-space frequency - lower = larger wisps
float fogNoiseSpeed = 8;    // how fast the noise pattern scrolls

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

    // Shared wind gust envelope - deliberately NOT derived from r1, so
    // every particle feels the exact same gust at the same time (unlike
    // the per-particle jitter below, which is deliberately decorrelated).
    // Two off-beat sine waves avoid a too-regular, metronomic pulse.
    float gustPhase1 = time * dustGustSpeed;
    float gustPhase2 = time * dustGustSpeed * 0.37 + 1.7;
    float gust = saturate(sin(gustPhase1) * 0.6 + sin(gustPhase2) * 0.4);
    gust = pow(gust, 3.0); // sharpen into brief gusts rather than a smooth back-and-forth
    float3 gustOffset = normalize(dustWindDir) * gust * dustGustStrength;


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
        (basePos + 2.0 + sphereOffset + gustOffset)
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
    // Also stirred up briefly by gusts (wind kicking up more visible dust).
    float densityScale = saturate(dustDensity / 20.0) * (1.0 + gust * dustGustDensityBoost);
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

// https://www.shadertoy.com/view/Ml3GR8
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

    float3 waterProbe = wpos + wdir * tF;
    if (wpos.z > waterlevel && waterProbe.z < waterlevel)
        tF = (1.0 - (waterlevel-waterProbe.z) / (wpos.z-waterProbe.z)) * tF;


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

    return f - (f * 0.41 * sin(time/45));
}

// ---------------- combined pass ----------------

float4 dustfog(float2 tex : TEXCOORD0, float2 vpos : VPOS) : COLOR0 {

    float4 scenecol = sample0(s0, tex);
    float3 v = toWorld(tex);           // un-normalized world ray (used by both passes)
    float depth = sample0(s2, tex).r;  // shared depth buffer sample

    // Density-weighted average of the fog colors - used to tint dust particles
    // so they match whichever fog volume currently dominates the scene.
    // Falls back to dustBaseColor when little/no fog is nearby, instead of
    // dividing by a near-zero weight and going black.
    float3 fogColorSum = float3(0.0, 0.0, 0.0);
    float fogDensitySum = 0.0;
    [unroll]
    for (int fc = 0; fc < NUM_FOG_VOLUMES; fc++) {
        fogColorSum += float3(fogColors[fc]) * fogDensities[fc];
        fogDensitySum += fogDensities[fc];
    }
    float3 fogAvgColor = fogColorSum / max(fogDensitySum, 0.0001);
    float fogInfluence = saturate(fogDensitySum);
    float3 dustTint = lerp(dustBaseColor, fogAvgColor, fogInfluence);
    float3 dustTintLinear = dustTint * dustTint; // approx gamma->linear, matches the fog loop below

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

    [loop]
    for (int i = 0; i < NUM_FOG_VOLUMES; i++) {

        float3 center = float3(fogCenters[i]);
        center.z -= (((i + 2) * 320) - 250) * cos(time/60);
        // horizontal gust sway, decorrelated per volume via the i-based phase offset
        center.x += fogGustAmount * sin(time * fogGustSpeed + i * 2.1);
        center.y += fogGustAmount * cos(time * fogGustSpeed * 0.8 + i * 1.3);

        float3 radius = float3(fogRadi[i]);
        radius.z += (((i + 2) * 150) - 60) * sin(time/25);

        float density = boxDensity(pos, dir, center, radius, depth);
        if (density > 0.0) {
            float fogScalar = 1.0 / sqrt(dot(radius, radius));
            density = density * fogScalar * fogDensities[i];

            // Break up the smooth analytic gradient with drifting patchiness.
            // Sampled at roughly where this ray enters the volume, so
            // different screen pixels see different wisps rather than a
            // uniform per-volume tint.
            float3 rdN = normalize(dir);
            float tEstimate = max(0.0, dot(center - pos, rdN));
            float3 samplePoint = pos + rdN * tEstimate;
            float3 windScroll = normalize(dustWindDir) * time * fogNoiseSpeed;
            float noiseVal = noiseFog((samplePoint + windScroll) * fogNoiseScale);
            density *= lerp(1.0 - fogNoiseStrength, 1.0 + fogNoiseStrength, noiseVal);

            float3 fogColor = float3(fogColors[i]);
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
