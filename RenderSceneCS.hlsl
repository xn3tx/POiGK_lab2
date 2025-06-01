// CasualPathtracing technique, shader RenderSceneCS
/*$(ShaderResources)*/

// A port of my shadertoy https://www.shadertoy.com/view/ttfyzN

static const float c_pi = 3.14159265359f;
static const float c_twopi = 2.0f * c_pi;

// The minimunm distance a ray must travel before we consider an intersection.
// This is to prevent a ray from intersecting a surface it just bounced off of.
static const float c_minimumRayHitTime = 0.01f;

// after a hit, it moves the ray this far along the normal away from a surface.
// Helps prevent incorrect intersections when rays bounce off of objects.
static const float c_rayPosNormalNudge = 0.01f;

// the farthest we look for ray hits
static const float c_superFar = 10000.0f;

// camera FOV
static const float c_FOVDegrees = 90.0f;

// number of ray bounces allowed max
#define c_numBounces /*$(Variable:NumBounces)*/

// a multiplier for the skybox brightness
#define c_skyboxBrightnessMultiplier /*$(Variable:SkyboxBrightness)*/

// a pixel value multiplier of light before tone mapping and sRGB
#define c_exposure pow(2.0f, /*$(Variable:Exposure)*/)

// how many renders per frame - make this larger to get around the vsync limitation, and get a better image faster.
#define c_numRendersPerFrame /*$(Variable:RaysPerPixel)*/

// 0 = transparent orange spheres of increasing surface roughness
// 1 = transparent spheres of increasing IOR
// 2 = opaque spheres of increasing IOR
// 3 = transparent spheres of increasing absorption
// 4 = transparent spheres of various heights, to show hot spot focus/defocus
// 5 = transparent spheres becoming increasingly diffuse
// 6 = transparent spheres of increasing surface roughness
//#define SCENE 0

float3 LessThan(float3 f, float value)
{
    return float3(
        (f.x < value) ? 1.0f : 0.0f,
        (f.y < value) ? 1.0f : 0.0f,
        (f.z < value) ? 1.0f : 0.0f);
}

float3 LinearToSRGB(float3 rgb)
{
    rgb = clamp(rgb, 0.0f, 1.0f);

    return lerp(
        pow(rgb, (1.0f / 2.4f).xxx) * 1.055f - 0.055f,
        rgb * 12.92f,
        LessThan(rgb, 0.0031308f)
    );
}

float3 SRGBToLinear(float3 rgb)
{
    rgb = clamp(rgb, 0.0f, 1.0f);

    return lerp(
        pow(((rgb + 0.055f) / 1.055f), (2.4f).xxx),
        rgb / 12.92f,
        LessThan(rgb, 0.04045f)
	);
}

// ACES tone mapping curve fit to go from HDR to LDR
// https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
float3 ACESFilm(float3 x)
{
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

uint wang_hash(inout uint seed)
{
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

float RandomFloat01(inout uint state)
{
    return float(wang_hash(state)) / 4294967296.0;
}

float3 RandomUnitVector(inout uint state)
{
    float z = RandomFloat01(state) * 2.0f - 1.0f;
    float a = RandomFloat01(state) * c_twopi;
    float r = sqrt(1.0f - z * z);
    float x = r * cos(a);
    float y = r * sin(a);
    return float3(x, y, z);
}

struct SMaterialInfo
{
    // Note: diffuse chance is 1.0f - (specularChance+refractionChance)
    float3 albedo;             // the color used for diffuse lighting
    float3  emissive;            // how much the surface glows
    float specularChance;      // percentage chance of doing a specular reflection
    float specularRoughness;   // how rough the specular reflections are
    float3  specularColor;       // the color tint of specular reflections
    float IOR;                 // index of refraction. used by fresnel and refraction.
    float refractionChance;    // percent chance of doing a refractive transmission
    float refractionRoughness; // how rough the refractive transmissions are
    float3  refractionColor;     // absorption for beer's law    
};

SMaterialInfo GetZeroedMaterial()
{
    SMaterialInfo ret;
    ret.albedo = float3(0.0f, 0.0f, 0.0f);
    ret.emissive = float3(0.0f, 0.0f, 0.0f);
    ret.specularChance = 0.0f;
    ret.specularRoughness = 0.0f;
    ret.specularColor = float3(0.0f, 0.0f, 0.0f);
    ret.IOR = 1.0f;
    ret.refractionChance = 0.0f;
    ret.refractionRoughness = 0.0f;
    ret.refractionColor = float3(0.0f, 0.0f, 0.0f);
    return ret;
}

struct SRayHitInfo
{
    bool fromInside;
    float dist;
    float3 normal;
    SMaterialInfo material;
};

float ScalarTriple(float3 u, float3 v, float3 w)
{
    return dot(cross(u, v), w);
}

bool TestQuadTrace(in float3 rayPos, in float3 rayDir, inout SRayHitInfo info, in float3 a, in float3 b, in float3 c, in float3 d)
{
    // calculate normal and flip vertices order if needed
    float3 normal = normalize(cross(c - a, c - b));
    if (dot(normal, rayDir) > 0.0f)
    {
        normal *= -1.0f;

        float3 temp = d;
        d = a;
        a = temp;

        temp = b;
        b = c;
        c = temp;
    }

    float3 p = rayPos;
    float3 q = rayPos + rayDir;
    float3 pq = q - p;
    float3 pa = a - p;
    float3 pb = b - p;
    float3 pc = c - p;

    // determine which triangle to test against by testing against diagonal first
    float3 m = cross(pc, pq);
    float v = dot(pa, m);
    float3 intersectPos;
    if (v >= 0.0f)
    {
        // test against triangle a,b,c
        float u = -dot(pb, m);
        if (u < 0.0f) return false;
        float w = ScalarTriple(pq, pb, pa);
        if (w < 0.0f) return false;
        float denom = 1.0f / (u + v + w);
        u *= denom;
        v *= denom;
        w *= denom;
        intersectPos = u * a + v * b + w * c;
    }
    else
    {
        float3 pd = d - p;
        float u = dot(pd, m);
        if (u < 0.0f) return false;
        float w = ScalarTriple(pq, pa, pd);
        if (w < 0.0f) return false;
        v = -v;
        float denom = 1.0f / (u + v + w);
        u *= denom;
        v *= denom;
        w *= denom;
        intersectPos = u * a + v * d + w * c;
    }

    float dist;
    if (abs(rayDir.x) > 0.1f)
    {
        dist = (intersectPos.x - rayPos.x) / rayDir.x;
    }
    else if (abs(rayDir.y) > 0.1f)
    {
        dist = (intersectPos.y - rayPos.y) / rayDir.y;
    }
    else
    {
        dist = (intersectPos.z - rayPos.z) / rayDir.z;
    }

    if (dist > c_minimumRayHitTime && dist < info.dist)
    {
        info.fromInside = false;
        info.dist = dist;
        info.normal = normal;
        return true;
    }

    return false;
}

float FresnelReflectAmount(float n1, float n2, float3 normal, float3 incident, float f0, float f90)
{
    // Schlick aproximation
    float r0 = (n1 - n2) / (n1 + n2);
    r0 *= r0;
    float cosX = -dot(normal, incident);
    if (n1 > n2)
    {
        float n = n1 / n2;
        float sinT2 = n * n * (1.0 - cosX * cosX);
        // Total internal reflection
        if (sinT2 > 1.0)
            return f90;
        cosX = sqrt(1.0 - sinT2);
    }
    float x = 1.0 - cosX;
    float ret = r0 + (1.0 - r0) * x * x * x * x * x;

    // adjust reflect multiplier for object reflectivity
    return lerp(f0, f90, ret);
}

bool TestSphereTrace(in float3 rayPos, in float3 rayDir, inout SRayHitInfo info, in float4 sphere)
{
    // get the vector from the center of this sphere to where the ray begins.
    float3 m = rayPos - sphere.xyz;

    // get the dot product of the above vector and the ray's vector
    float b = dot(m, rayDir);

    float c = dot(m, m) - sphere.w * sphere.w;

    // exit if r's origin outside s (c > 0) and r pointing away from s (b > 0)
    if (c > 0.0 && b > 0.0)
        return false;

    // calculate discriminant
    float discr = b * b - c;

    // a negative discriminant corresponds to ray missing sphere
    if (discr < 0.0)
        return false;

    // ray now found to intersect sphere, compute smallest t value of intersection
    bool fromInside = false;
    float dist = -b - sqrt(discr);
    if (dist < 0.0f)
    {
        fromInside = true;
        dist = -b + sqrt(discr);
    }

    if (dist > c_minimumRayHitTime && dist < info.dist)
    {
        info.fromInside = fromInside;
        info.dist = dist;
        info.normal = normalize((rayPos + rayDir * dist) - sphere.xyz) * (fromInside ? -1.0f : 1.0f);
        return true;
    }

    return false;
}

float mod(float x, float y)
{
    return x - y * floor(x / y);
}

void TestSceneTrace(in float3 rayPos, in float3 rayDir, inout SRayHitInfo hitInfo)
{
    // floor
    {
        float3 A = float3(-25.0f, -12.5f, 5.0f);
        float3 B = float3(25.0f, -12.5f, 5.0f);
        float3 C = float3(25.0f, -12.5f, -5.0f);
        float3 D = float3(-25.0f, -12.5f, -5.0f);
        if (TestQuadTrace(rayPos, rayDir, hitInfo, A, B, C, D))
        {
            hitInfo.material = GetZeroedMaterial();
            hitInfo.material.albedo = float3(0.7f, 0.7f, 0.7f);
        }
    }

    // striped background
    {
        float3 A = float3(-25.0f, -1.5f, 5.0f);
        float3 B = float3(25.0f, -1.5f, 5.0f);
        float3 C = float3(25.0f, -10.5f, 5.0f);
        float3 D = float3(-25.0f, -10.5f, 5.0f);
        if (TestQuadTrace(rayPos, rayDir, hitInfo, A, B, C, D))
        {
            hitInfo.material = GetZeroedMaterial();

            float3 hitPos = rayPos + rayDir * hitInfo.dist;

            float shade = floor(mod(hitPos.x, 1.0f) * 2.0f);
            hitInfo.material.albedo = float3(shade, shade, shade);
        }
    }

    // cieling piece above light
    {
        float3 A = float3(-7.5f, 12.5f, 5.0f);
        float3 B = float3(7.5f, 12.5f, 5.0f);
        float3 C = float3(7.5f, 12.5f, -5.0f);
        float3 D = float3(-7.5f, 12.5f, -5.0f);
        if (TestQuadTrace(rayPos, rayDir, hitInfo, A, B, C, D))
        {
            hitInfo.material = GetZeroedMaterial();
            hitInfo.material.albedo = float3(0.7f, 0.7f, 0.7f);
        }
    }

    // light
    {
        float3 A = float3(-5.0f, 12.4f, 2.5f);
        float3 B = float3(5.0f, 12.4f, 2.5f);
        float3 C = float3(5.0f, 12.4f, -2.5f);
        float3 D = float3(-5.0f, 12.4f, -2.5f);
        if (TestQuadTrace(rayPos, rayDir, hitInfo, A, B, C, D))
        {
            hitInfo.material = GetZeroedMaterial();
            hitInfo.material.emissive = /*$(Variable:MainLightCol)*/ * /*$(Variable:MainLightPow)*/;
        }
    }

    if (/*$(Variable:Scene)*/ == 0)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 00.0f, 2.8f)))
			{
				float r = float(sphereIndex) / float(c_numSpheres - 1) * 0.5f;

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = r;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = 1.1f;
				hitInfo.material.refractionChance = 1.0f;
				hitInfo.material.refractionRoughness = r;
				hitInfo.material.refractionColor = float3(0.0f, 0.5f, 1.0f);
			}
		}
    }
    else if (/*$(Variable:Scene)*/ == 1)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 0.0f, 2.8f)))
			{
				float ior = 1.0f + 0.5f * float(sphereIndex) / float(c_numSpheres - 1);

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = 0.0f;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = ior;
				hitInfo.material.refractionChance = 1.0f;
				hitInfo.material.refractionRoughness = 0.0f;
			}
        }
    }
    else if (/*$(Variable:Scene)*/ == 2)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 0.0f, 2.8f)))
			{
				float ior = 1.0f + 1.0f * float(sphereIndex) / float(c_numSpheres - 1);

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = 0.0f;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = ior;
				hitInfo.material.refractionChance = 0.0f;
			}
        }
    }
    else if (/*$(Variable:Scene)*/ == 3)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 0.0f, 2.8f)))
			{
				float absorb = float(sphereIndex) / float(c_numSpheres - 1);

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = 0.0f;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = 1.1f;
				hitInfo.material.refractionChance = 1.0f;
				hitInfo.material.refractionRoughness = 0.0f;
				hitInfo.material.refractionColor = float3(1.0f, 2.0f, 3.0f) * absorb;
			}
        }
    }
    else if (/*$(Variable:Scene)*/ == 4)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -9.0f + 0.75f * float(sphereIndex), 0.0f, 2.8f)))
			{
				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = 0.0f;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = 1.5f;
				hitInfo.material.refractionChance = 1.0f;
				hitInfo.material.refractionRoughness = 0.0f;
			}
        }
    }
    else if (/*$(Variable:Scene)*/ == 5)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -9.0f, 0.0f, 2.8f)))
			{
				float transparency = float(sphereIndex) / float(c_numSpheres - 1);

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.9f, 0.25f, 0.25f);
				hitInfo.material.emissive = float3(0.0f, 0.0f, 0.0f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = 0.0f;
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;
				hitInfo.material.IOR = 1.1f;
				hitInfo.material.refractionChance = 1.0f - transparency;
				hitInfo.material.refractionRoughness = 0.0f;
			}
		}
    }
    else if (/*$(Variable:Scene)*/ == 6)                  //tą scene edytujemy i dodajemy kod do przycisków tworzonych w gigiedit
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 00.0f, 2.8f)))
			{
				float r = float(sphereIndex) / float(c_numSpheres - 1) * 0.5f;

				hitInfo.material = GetZeroedMaterial();
				//hitInfo.material.albedo = float3(0.05f, 0.95f, 0.05f);
				hitInfo.material.emissive = float3(0.2f, 0.98f, 0.2f)*0.25f;  //float3(0.1f, 0.1f, 0.8f);
				hitInfo.material.specularChance = 0.02f;
				hitInfo.material.specularRoughness = r;
				hitInfo.material.specularColor = float3(0.8f, 0.4f, 0.2f) * 0.5f;
				hitInfo.material.IOR = 1.1f;
				hitInfo.material.refractionChance = 1.0f;
				hitInfo.material.refractionRoughness = r;
				hitInfo.material.refractionColor = float3(0.95f, 0.05f, 0.95f);
			}
        }
    }
    else if (/*$(Variable:Scene)*/ == 7)
    {
		const int c_numSpheres = 7;
		for (int sphereIndex = 0; sphereIndex < c_numSpheres; ++sphereIndex)
		{
			if (TestSphereTrace(rayPos, rayDir, hitInfo, float4(-18.0f + 6.0f * float(sphereIndex), -8.0f, 00.0f, 2.8f)))
			{
				float r = float(sphereIndex) / float(c_numSpheres - 1) * 0.5f;

				hitInfo.material = GetZeroedMaterial();
				hitInfo.material.albedo = float3(0.0f, 0.0f, 0.0f); // jak bardzo odbija swiatlo biale (bazowy kolor obiektu, -kolor czegos bez oswietlenia na nim) (dla diaelektrykow nie metali to jest kolor ,ale dla metali aby być fizycznie poprawnym to 0 0 0, ) 
				hitInfo.material.emissive = float3(0.2f, 0.2f, 0.8f) * 1000.0f;  // bylo 0 0 0  a teraz blue, 0 0 1  to jak laser
				hitInfo.material.specularChance = 0.02f;  // szansa na odbicie połyskowe (świecące)
				hitInfo.material.specularRoughness = r;  // szorstkośc powierzchni 0-1  (0.1/0.5 dobre wartosci)
				hitInfo.material.specularColor = float3(1.0f, 1.0f, 1.0f) * 0.8f;  // kolor odbicia połyskowego (realistycznie szary - te same wartosci i duzo silnikow ma * 0.25f) Dla metali to okresla kolor metalu czyli zloto zoltawe, a srebne to bardziej szare
				hitInfo.material.IOR = 1.1f;    // indeks refrakcji (wspolczynik zalamania swiatla)
				hitInfo.material.refractionChance = 1.0f;   // szansa, ze promien bedzie zalamany i spenetruje powierzchniue obiektu 
				hitInfo.material.refractionRoughness = r;  // szorstkosc ośroda (w środku jaka jest ) - moze sie zmieniac w raz z dystansem (tutaj uproszczone)
 				hitInfo.material.refractionColor = float3(0.1f, 0.1f, 0.9f);  // Beer’s Law
			}
        }
    }
}

// from https://learnopengl.com/PBR/IBL/Diffuse-irradiance
float2 SampleSphericalMap(float3 v)
{
    const float2 invAtan = float2(0.1591f, 0.3183f);
    float2 uv = float2(atan2(v.z, v.x), asin(-v.y));
    uv *= invAtan;
    uv += 0.5;
    return uv;
}

float3 GetColorForRay(in float3 startRayPos, in float3 startRayDir, inout uint rngState)
{
    // initialize
    float3 ret = float3(0.0f, 0.0f, 0.0f);
    float3 throughput = float3(1.0f, 1.0f, 1.0f);
    float3 rayPos = startRayPos;
    float3 rayDir = startRayDir;

    for (int bounceIndex = 0; bounceIndex <= c_numBounces; ++bounceIndex)
    {
        // shoot a ray out into the world
        SRayHitInfo hitInfo;
        hitInfo.material = GetZeroedMaterial();
        hitInfo.dist = c_superFar;
        hitInfo.fromInside = false;
        TestSceneTrace(rayPos, rayDir, hitInfo);

        //hitInfo.material.emissive = (0.1f, 0.2f,0.8f)*0.2f;
        // if the ray missed, we are done
        if (hitInfo.dist == c_superFar)
        {
            float2 uv = SampleSphericalMap(rayDir);
            ret += /*$(Image:Arches_E_PineTree_3k.png:RGBA8_Unorm_sRGB:float4:false)*/.SampleLevel(texSampler, uv, 0).rgb * c_skyboxBrightnessMultiplier * throughput;
            break;
        }

        // do absorption if we are hitting from inside the object
        if (hitInfo.fromInside)
            throughput *= exp(-hitInfo.material.refractionColor * hitInfo.dist);

        // get the pre-fresnel chances
        float specularChance = hitInfo.material.specularChance;
        float refractionChance = hitInfo.material.refractionChance;
        // float diffuseChance = max(0.0f, 1.0f - (refractionChance + specularChance));

        // take fresnel into account for specularChance and adjust other chances.
        // specular takes priority.
        // chanceMultiplier makes sure we keep diffuse / refraction ratio the same.
        float rayProbability = 1.0f;
        if (specularChance > 0.0f)
        {
            specularChance = FresnelReflectAmount(
                hitInfo.fromInside ? hitInfo.material.IOR : 1.0,
                !hitInfo.fromInside ? hitInfo.material.IOR : 1.0,
                rayDir, hitInfo.normal, hitInfo.material.specularChance, 1.0f);

            float chanceMultiplier = (1.0f - specularChance) / (1.0f - hitInfo.material.specularChance);
            refractionChance *= chanceMultiplier;
            // diffuseChance *= chanceMultiplier;
        }

        // calculate whether we are going to do a diffuse, specular, or refractive ray
        float doSpecular = 0.0f;
        float doRefraction = 0.0f;
        float raySelectRoll = RandomFloat01(rngState);
        if (specularChance > 0.0f && raySelectRoll < specularChance)
        {
            doSpecular = 1.0f;
            rayProbability = specularChance;
        }
        else if (refractionChance > 0.0f && raySelectRoll < specularChance + refractionChance)
        {
            doRefraction = 1.0f;
            rayProbability = refractionChance;
        }
        else
        {
            rayProbability = 1.0f - (specularChance + refractionChance);
        }

        // numerical problems can cause rayProbability to become small enough to cause a divide by zero.
        rayProbability = max(rayProbability, 0.001f);

        // update the ray position
        if (doRefraction == 1.0f)
        {
            rayPos = (rayPos + rayDir * hitInfo.dist) - hitInfo.normal * c_rayPosNormalNudge;
        }
        else
        {
            rayPos = (rayPos + rayDir * hitInfo.dist) + hitInfo.normal * c_rayPosNormalNudge;
        }

        // Calculate a new ray direction.
        // Diffuse uses a normal oriented cosine weighted hemisphere sample.
        // Perfectly smooth specular uses the reflection ray.
        // Rough (glossy) specular lerps from the smooth specular to the rough diffuse by the material roughness squared
        // Squaring the roughness is just a convention to make roughness feel more linear perceptually.
        float3 diffuseRayDir = normalize(hitInfo.normal + RandomUnitVector(rngState));

        float3 specularRayDir = reflect(rayDir, hitInfo.normal);
        specularRayDir = normalize(lerp(specularRayDir, diffuseRayDir, hitInfo.material.specularRoughness * hitInfo.material.specularRoughness));

        float3 refractionRayDir = refract(rayDir, hitInfo.normal, hitInfo.fromInside ? hitInfo.material.IOR : 1.0f / hitInfo.material.IOR);
        refractionRayDir = normalize(lerp(refractionRayDir, normalize(-hitInfo.normal + RandomUnitVector(rngState)), hitInfo.material.refractionRoughness * hitInfo.material.refractionRoughness));

        rayDir = lerp(diffuseRayDir, specularRayDir, doSpecular);
        rayDir = lerp(rayDir, refractionRayDir, doRefraction);

        // add in emissive lighting
        ret += hitInfo.material.emissive * throughput;

        // update the colorMultiplier. refraction doesn't alter the color until we hit the next thing, so we can do light absorption over distance.
        if (doRefraction == 0.0f)
            throughput *= lerp(hitInfo.material.albedo, hitInfo.material.specularColor, doSpecular);

        // since we chose randomly between diffuse, specular, refract,
        // we need to account for the times we didn't do one or the other.
        throughput /= rayProbability;

        // Russian Roulette
        // As the throughput gets smaller, the ray is more likely to get terminated early.
        // Survivors have their value boosted to make up for fewer samples being in the average.
        {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            if (RandomFloat01(rngState) > p)
                break;

            // Add the energy we 'lose' by randomly terminating paths
            throughput *= 1.0f / p;
        }
    }

    // return pixel color
    return ret;
}

/*$(_compute:main)*/(uint3 DTid : SV_DispatchThreadID)
{
    uint2 px = DTid.xy;

    uint2 renderSize;
    Output.GetDimensions(renderSize.x, renderSize.y);

    // initialize a random number state based on frag coord and frame
    uint rngState = uint(px.x * uint(1973) + px.y * uint(9277) + /*$(Variable:FrameIndex)*/ *uint(26699)) | uint(1);

    // calculate subpixel camera jitter for anti aliasing
    float2 jitter = float2(RandomFloat01(rngState), RandomFloat01(rngState)) - 0.5f;

    // Get the world position
    float2 screenPos = (float2(px) + jitter + 0.5f) / float2(renderSize) * 2.0 - 1.0;
    screenPos.y = -screenPos.y;
    float4 world = mul(float4(screenPos, 1.0f, 1.0f), /*$(Variable:InvViewProjMtx)*/);
    world.xyz /= world.w;

    // calculate the ray
    float3 rayPos = /*$(Variable:CameraPos)*/;
    float3 rayDir = normalize(world.xyz - rayPos);

	// raytrace for this pixel
    float3 color = float3(0.0f, 0.0f, 0.0f);
    for (int index = 0; index < c_numRendersPerFrame; ++index)
        color += GetColorForRay(rayPos, rayDir, rngState) / float(c_numRendersPerFrame);

	// average the frames together
    float4 lastFrameColor = Accum[px];
    bool reset = /*$(Variable:FrameIndex)*/ < 2;
    reset = reset || (/*$(Variable:Scene)*/ != /*$(Variable:SceneLastFrame)*/);
    reset = reset || bool(/*$(Variable:Reset)*/);
    reset = reset || bool(/*$(Variable:CameraChanged)*/);
    // float blend = reset ? 1.0f : 1.0f / (1.0f + (1.0f / lastFrameColor.a));
    lastFrameColor.a = reset ? 1.0f : lastFrameColor.a + 1.0f;
    color = lerp(lastFrameColor.rgb, color, 1.0f / lastFrameColor.a);

    // show the result
    Accum[px] = float4(color, lastFrameColor.a);

    // apply exposure (how long the shutter is open)
    //color *= c_exposure; // 3 zmianione

    // convert unbounded HDR color range to SDR color range
    //color = ACESFilm(color);  // 3 zmianione
 
    // convert from linear to sRGB for display
    //color = LinearToSRGB(color);   // 3 zmianione
    Output[px] = float4(color, 1.0f); 
}

/*
Shader Resources:
	Texture Accum (as UAV)
	Texture Output (as UAV)
*/
