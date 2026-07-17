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

float fognearstart, fognearrange;

// -- dust params --
float3 sunpos;
float3 suncol;
float3 sunamb;
float2 rcpres;
float3 fognearcol;
float fov;


// ---------------- dust controls ----------------

// Density:
// 0   = no particles
// 20  = maximum particles
float dustDensity = 1.0;

// Particle size multiplier
float dustSize = 1.0;

// Distance between particle cells
float dustCellSize = 30.0;

// Animation speed
float dustTimeScale = 1.0;

// Movement amplitude
float dustMotionScale = 0.1;

// Particle shape:
// 1 = diamond
// 2 = sphere
// 4+ = cube-like
float dustShape = 2.0;

// Raymarch limits
float dustMaxDistance = 1600.0;
float dustSurfaceDistance = 0.01;

// Fade controls
float dustFadeStart = 20.0;
float dustFadeEnd = 30.0;

// Material threshold
float dustMaterialBias = 0.3;

// -- fogbox params --
static const float NUM_FOG_VOLUMES = 3;
float fogCenters[NUM_FOG_VOLUMES][3];
float fogRadi[NUM_FOG_VOLUMES][3];
float fogColors[NUM_FOG_VOLUMES][3];
float fogDensities[NUM_FOG_VOLUMES];

// ---------------- constants ----------------

static const int   MAX_STEPS    = 200;
static const float MAX_DIST     = 1600.0;
static const float SURFACE_DIST = 0.01;

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
    float r2 = frac(r1 * 17.543);


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


    float spawnThreshold =
        saturate(1.0 - dustDensity * 0.05);


    radius *= step(spawnThreshold,r2);


    return sdSuperShape(q,radius,dustShape);
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


    float r2 =
        frac(r1*17.543);


    float spawnThreshold =
        saturate(1.0 - dustDensity*0.05);


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


    return step(spawnThreshold,r2)
        *
        smoothstep(
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
    float3 fogColorSum = float3(0.0, 0.0, 0.0);
    float fogWeightSum = 0.0001; // avoid divide by zero when all fog densities are 0
    [unroll]
    for (int fc = 0; fc < NUM_FOG_VOLUMES; fc++) {
        fogColorSum += float3(fogColors[fc]) * fogDensities[fc];
        fogWeightSum += fogDensities[fc];
    }
    float3 dustTint = fogColorSum / fogWeightSum;
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
        float l = max(0.0, dot(eyevec, -normalize(sunpos)));
        float3 linCol = lerp(pow(scenecol.rgb, 2.2),
                            dustTintLinear,
                            smoothstep(dustFadeStart,dustFadeEnd,d)*saturate(sp-dustMaterialBias));
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

        float3 radius = float3(fogRadi[i]);
        radius.z += (((i + 2) * 150) - 60) * sin(time/25);

        float density = boxDensity(pos, dir, center, radius, depth);
        if (density > 0.0) {
            float fogScalar = 1.0 / sqrt(dot(radius, radius));
            density = density * fogScalar * fogDensities[i];

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
