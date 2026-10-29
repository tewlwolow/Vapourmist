
int mgeflags = 9;
// Adapted to MGEXE by G7 and Safebox, modified by tewlwolow

// lua variables - single fog volume
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

// Sun direction/color
float3 sunpos;
float3 suncol;
float sunvis;

texture lastshader;
texture depthframe;

sampler s0 = sampler_state
{
    texture = <lastshader>;
    addressu = clamp;
    addressv = clamp;
    magfilter = point;
    minfilter = point;
};

sampler s2 = sampler_state
{
    texture = <depthframe>;
    addressu = clamp;
    addressv = clamp;
    magfilter = linear;
    minfilter = linear;
};

float4 sample0(sampler2D s, float2 t)
{
    return tex2Dlod(s, float4(t, 0, 0));
}

float3 toWorld(float2 tex)
{
    float3 v = float3(
        mview[0][2],
        mview[1][2],
        mview[2][2]
    );

    v += (+1 / mproj[0][0] * (2 * tex.x - 1)).xxx
       * float3(mview[0][0], mview[1][0], mview[2][0]);

    v += (-1 / mproj[1][1] * (2 * tex.y - 1)).xxx
       * float3(mview[0][1], mview[1][1], mview[2][1]);

    return v;
}

// -------------------------------------------------------------- //

float boxDensity(
    float3 wpos,
    float3 wdir,
    float3 p,
    float3 r,
    float dbuffer,
    out float tNear
)
{
    tNear = 0.0;

    float3 d = wdir;
    float3 o = wpos - p;

    // Ray-box intersection
    float3 m = 1.0 / d;
    float3 n = m * o;
    float3 k = abs(m) * r;

    float3 ta = -n - k;
    float3 tb = -n + k;

    float tN = max(max(ta.x, ta.y), ta.z);
    float tF = min(min(tb.x, tb.y), tb.z);

    if (tN > tF || tF < 0.0)
        return 0.0;

    // Not visible or behind depth buffer
    if (tF < 0.0 || tN > dbuffer)
        return 0.0;

    // Clip segment to camera and depth buffer
    tN = max(tN, 0.0);
    tNear = tN;

    float waterlevel = -5.0;

    float3 waterProbe = wpos + wdir * tF;

    if (wpos.z > waterlevel && waterProbe.z < waterlevel)
    {
        tF = (1.0 - (waterlevel - waterProbe.z)
            / (wpos.z - waterProbe.z)) * tF;
    }

    tF = min(tF, dbuffer);

    // Move ray to the intersection point
    o += tN * d;
    tF = tF - tN;
    tN = 0.0;

    // Analytically integrate the box density
    float3 a = 1.0 - (o * o) / (r * r);
    float3 b = -2.0 * (o * d) / (r * r);
    float3 c = -(d * d) / (r * r);

    float t1 = tF;
    float t2 = t1 * t1;
    float t3 = t2 * t1;
    float t4 = t2 * t2;
    float t5 = t2 * t3;
    float t6 = t3 * t3;
    float t7 = t3 * t4;

    float f =
          (t1 / 1.0) * (a.x * a.y * a.z)

        + (t2 / 2.0) * (
              a.x * a.y * b.z
            + a.x * b.y * a.z
            + b.x * a.y * a.z
        )

        + (t3 / 3.0) * (
              a.x * a.y * c.z
            + a.x * b.y * b.z
            + a.x * c.y * a.z
            + b.x * a.y * b.z
            + b.x * b.y * a.z
            + c.x * a.y * a.z
        )

        + (t4 / 4.0) * (
              a.x * b.y * c.z
            + a.x * c.y * b.z
            + b.x * a.y * c.z
            + b.x * b.y * b.z
            + b.x * c.y * a.z
            + c.x * a.y * b.z
            + c.x * b.y * a.z
        )

        + (t5 / 5.0) * (
              a.x * c.y * c.z
            + b.x * b.y * c.z
            + b.x * c.y * b.z
            + c.x * a.y * c.z
            + c.x * b.y * b.z
            + c.x * c.y * a.z
        )

        + (t6 / 6.0) * (
              b.x * c.y * c.z
            + c.x * b.y * c.z
            + c.x * c.y * b.z
        )

        + (t7 / 7.0) * (
              c.x * c.y * c.z
        );

    return f;
}

// -------------------------------------------------------------- //

// Three static fog layers
static const float LAYER_CENTER_Z_FRAC[3] =
{
    -0.5, 0.0, 0.6
};

static const float LAYER_RADIUS_Z_SCALE[3] =
{
    0.5, 0.85, 1.3
};

// Faster vertical fade
static const float HEIGHT_FALLOFF_RATE = 0.0025;

// Slow drifting noise
static const float NOISE_SCALE = 0.00035;
static const float2 DRIFT_SPEED = float2(40.0, 22.0);

static const float DRIFT_MIN = 0.8;
static const float DRIFT_MAX = 1.2;

// Reduced sunlight glow
static const float SUN_GLOW_EXPONENT = 5.0;
static const float SUN_GLOW_STRENGTH = 0.15;

// Fog opacity multiplier
static const float FOG_OPACITY = 0.8;

// -------------------------------------------------------------- //

float hash21(float2 p)
{
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float noise2D(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);

    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(
        lerp(a, b, u.x),
        lerp(c, d, u.x),
        u.y
    );
}

// Interleaved gradient noise
float interleavedGradientNoise(float2 vpos)
{
    float3 magic = float3(
        0.06711056,
        0.00583715,
        52.9829189
    );

    return frac(
        magic.z * frac(dot(vpos, magic.xy))
    );
}

// -------------------------------------------------------------- //

float4 draw(float2 tex : TEXCOORD, float2 vpos : VPOS) : COLOR0
{
    float3 color = tex2D(s0, tex);
    float depth = sample0(s2, tex);

    float3 pos = eyepos;
    float3 dir = toWorld(tex);

    // Gamma to linear
    color = pow(color, 2.2);

    // Calculate sun glow once per pixel
    float3 dirN = normalize(dir);

    float3 sunDir =
        (dot(sunpos, sunpos) > 0.0001)
        ? normalize(sunpos)
        : float3(0, 0, 1);

    float sunDot = saturate(dot(dirN, sunDir));

    float sunGlow =
        pow(sunDot, SUN_GLOW_EXPONENT)
        * SUN_GLOW_STRENGTH
        * saturate(sunvis);

    // Darker fog with reduced sunlight contribution
    float3 litFogColor = saturate(
        fogColor * 0.65 + suncol * sunGlow
    );

    // Three stacked fog layers
    if (fogDensity > 0.0)
    {
        [unroll]
        for (int i = 0; i < 3; i++)
        {
            float3 center = fogCenter;

            center.z +=
                LAYER_CENTER_Z_FRAC[i] * fogRadius.z;

            float3 radius = fogRadius;

            radius.z *= LAYER_RADIUS_Z_SCALE[i];

            float tNear;

            float density = boxDensity(
                pos,
                dir,
                center,
                radius,
                depth,
                tNear
            );

            if (density > 0.0)
            {
                // Lower density for greater transparency
                float fogScalar =
                    1.0 / sqrt(dot(radius, radius));

                density =
                    density
                    * fogScalar
                    * fogDensity
                    * FOG_OPACITY;

                // Fade fog with height
                float heightAboveBase =
                    max(0.0, center.z - fogCenter.z);

                density *= exp(
                    -heightAboveBase * HEIGHT_FALLOFF_RATE
                );

                // Drifting world-space noise
                float3 entryPos = pos + dir * tNear;

                float2 driftUV =
                    (entryPos.xy + time * DRIFT_SPEED)
                    * NOISE_SCALE;

                float n = noise2D(driftUV);

                density *= lerp(
                    DRIFT_MIN,
                    DRIFT_MAX,
                    n
                );

                // Softer blending and reduced fog coverage
                color = lerp(
                    litFogColor * litFogColor,
                    color,
                    exp(-0.8 * density)
                );
            }
        }
    }

    // Linear to gamma
    color = pow(max(color, 0.0), 1.0 / 2.2);

    // Dithering
    float dithering =
        (interleavedGradientNoise(vpos) - 0.5) / 128.0;

    color += dithering;

    return float4(color, 1.0);
}

// -------------------------------------------------------------- //

technique T0<
    string MGEinterface = "MGE XE 0";
    string category = "atmosphere";
>
{
    pass
    {
        PixelShader = compile ps_3_0 draw();
    }
}
