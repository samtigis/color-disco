#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace ColorDiscoShaderMath {

    constant float3 kRec709Luma = float3(0.2126f, 0.7152f, 0.0722f);

    inline float3 rgbToHsl(float3 c) {
        float maxC = max(c.r, max(c.g, c.b));
        float minC = min(c.r, min(c.g, c.b));
        float l = (maxC + minC) * 0.5f;
        float d = maxC - minC;

        if (d < 1e-5f) {
            return float3(0.0f, 0.0f, l);
        }

        float s = (l > 0.5f) ? (d / max(2.0f - maxC - minC, 1e-5f)) : (d / max(maxC + minC, 1e-5f));
        float h = 0.0f;
        if (maxC == c.r) {
            h = (c.g - c.b) / d + (c.g < c.b ? 6.0f : 0.0f);
        } else if (maxC == c.g) {
            h = (c.b - c.r) / d + 2.0f;
        } else {
            h = (c.r - c.g) / d + 4.0f;
        }
        h /= 6.0f;
        return float3(h, s, l);
    }

    inline float hueToRgb(float p, float q, float t) {
        if (t < 0.0f) t += 1.0f;
        if (t > 1.0f) t -= 1.0f;
        if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
        if (t < 1.0f / 2.0f) return q;
        if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
        return p;
    }

    inline float3 hslToRgb(float3 hsl) {
        float h = fract(hsl.x);
        float s = clamp(hsl.y, 0.0f, 1.0f);
        float l = clamp(hsl.z, 0.0f, 1.0f);

        if (s < 1e-5f) {
            return float3(l);
        }

        float q = (l < 0.5f) ? (l * (1.0f + s)) : (l + s - l * s);
        float p = 2.0f * l - q;
        return float3(
            hueToRgb(p, q, h + 1.0f / 3.0f),
            hueToRgb(p, q, h),
            hueToRgb(p, q, h - 1.0f / 3.0f)
        );
    }

    // Smooth Gaussian hue window for artifact-free 8-channel HSL qualification
    inline float gaussianHueWeight(float hue, float centerHue, float sigma) {
        float diff = abs(hue - centerHue);
        diff = min(diff, 1.0f - diff);
        return exp(-(diff * diff) / (2.0f * sigma * sigma));
    }

    // Skin-tone protection mask centered on the vectorscope I-line (~28 deg hue, moderate saturation)
    inline float skinToneProtectionWeight(float3 hsl) {
        float hueDist = abs(hsl.x - 0.078f);
        hueDist = min(hueDist, 1.0f - hueDist);
        float hueMask = exp(-(hueDist * hueDist) / (2.0f * 0.042f * 0.042f));
        float satMask = smoothstep(0.10f, 0.25f, hsl.y) * (1.0f - smoothstep(0.68f, 0.88f, hsl.y));
        float lumaMask = smoothstep(0.12f, 0.28f, hsl.z) * (1.0f - smoothstep(0.82f, 0.96f, hsl.z));
        return clamp(hueMask * satMask * lumaMask, 0.0f, 1.0f);
    }

    // Golden-ratio animated spatial hash for organic film grain & triangular dither
    inline float goldenHash(float2 p, float frameSeed) {
        float2 seedOffset = p + float2(frameSeed * 1.61803398875f, frameSeed * 2.61803398875f);
        float3 p3 = fract(float3(seedOffset.xyx) * 0.1031f);
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.x + p3.y) * p3.z);
    }
}

extern "C" {
    namespace coreimage {

        // MARK: - MSL Kernel 1: 8-Channel HSL Warper with Gaussian Transitions & Skin Tone Protection Lock
        [[ stitchable ]] float4 hslEightChannelWarperKernel(
            sample_t s,
            float centerHue,
            float hueShift,
            float satDelta,
            float lumaDelta,
            float protectSkinFlag
        ) {
            float3 hsl = ColorDiscoShaderMath::rgbToHsl(s.rgb);
            float weight = ColorDiscoShaderMath::gaussianHueWeight(hsl.x, centerHue, 0.055f) * clamp(hsl.y * 2.0f, 0.0f, 1.0f);

            if (protectSkinFlag > 0.5f) {
                float skinWeight = ColorDiscoShaderMath::skinToneProtectionWeight(hsl);
                // Attenuate non-skin hue/saturation pulls by up to 80% inside the human skin locus
                weight *= (1.0f - skinWeight * 0.80f);
            }

            if (weight < 1e-4f) {
                return s;
            }

            hsl.x = fract(hsl.x + hueShift * 0.14f * weight);
            hsl.y = clamp(hsl.y * (1.0f + satDelta * weight), 0.0f, 1.0f);
            hsl.z = clamp(hsl.z + lumaDelta * 0.25f * weight, 0.0f, 1.0f);

            return float4(ColorDiscoShaderMath::hslToRgb(hsl), s.a);
        }

        // MARK: - MSL Kernel 2: Procedural Organic Film Grain & Edge-Detection Halation
        [[ stitchable ]] float4 filmEmulationGrainHalationKernel(
            sample_t s,
            sample_t blurredHighlightSample,
            float halationIntensity,
            float grainIntensity,
            float grainSize,
            float grainRoughness,
            float frameSeed,
            destination dest
        ) {
            float3 rgb = s.rgb;

            // 1. Halation: Warm red/amber scatter from high-contrast specular highlights
            if (halationIntensity > 0.001f) {
                float blurredLuma = dot(blurredHighlightSample.rgb, ColorDiscoShaderMath::kRec709Luma);
                float localLuma = dot(rgb, ColorDiscoShaderMath::kRec709Luma);
                float edgeContrast = max(0.0f, blurredLuma - localLuma * 0.65f);
                float highlightGate = smoothstep(0.55f, 0.95f, blurredLuma);
                float3 halationTint = float3(1.0f, 0.26f, 0.06f);
                rgb += halationTint * (edgeContrast + highlightGate * 0.35f) * halationIntensity * 0.48f;
            }

            // 2. Dynamic Procedural Film Grain: Per-frame organic simplex/golden-ratio emulsion noise
            if (grainIntensity > 0.001f) {
                float2 cellCoord = floor(dest.coord() / max(grainSize, 0.5f));
                float n1 = ColorDiscoShaderMath::goldenHash(cellCoord, frameSeed);
                float n2 = ColorDiscoShaderMath::goldenHash(cellCoord + float2(13.7f, 47.3f), frameSeed);
                float organicNoise = (n1 + mix(0.5f, n2, grainRoughness)) - 1.0f;

                // Film emulsion grain is strongest in midtones and rolls off in deep blacks and clipped whites
                float luma = dot(rgb, ColorDiscoShaderMath::kRec709Luma);
                float emulsionResponse = 4.0f * luma * (1.0f - luma);
                rgb += organicNoise * grainIntensity * 0.14f * max(emulsionResponse, 0.25f);
            }

            return float4(clamp(rgb, 0.0f, 1.0f), s.a);
        }

        // MARK: - MSL Kernel 3: Anti-Banding 0.5 LSB Triangular PDF Micro-Dither & 3-Way Wheels
        [[ stitchable ]] float4 triangularPDFMicroDitherKernel(
            sample_t s,
            float lsbAmplitude,
            destination dest
        ) {
            float2 coord = dest.coord();
            float u1 = ColorDiscoShaderMath::goldenHash(coord, 1.0f);
            float u2 = ColorDiscoShaderMath::goldenHash(coord + float2(19.19f, 73.41f), 2.0f);
            float tpdf = (u1 + u2) - 1.0f;
            float ditherStep = (lsbAmplitude / 255.0f) * tpdf;
            return float4(clamp(s.rgb + ditherStep, 0.0f, 1.0f), s.a);
        }
    }
}

// MARK: - MSL Kernel 4: GPU Compute Pass for Real-Time Waveform, Vectorscope, and RGB Histogram
kernel void computeScopesTelemetryKernel(
    texture2d<float, access::read> sourceTexture [[ texture(0) ]],
    device atomic_uint* waveformBins [[ buffer(0) ]],   // 128 cols x 64 IRE rows
    device atomic_uint* vectorscopeBins [[ buffer(1) ]],// 64 x 64 polar grid
    device atomic_uint* histogramBins [[ buffer(2) ]],  // 4 channels (R,G,B,Luma) x 64 bins
    uint2 gid [[ thread_position_in_grid ]]
) {
    uint width = sourceTexture.get_width();
    uint height = sourceTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 pixel = sourceTexture.read(gid);
    float3 rgb = clamp(pixel.rgb, 0.0f, 1.0f);
    float luma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));

    // 1. Luma Waveform (128 horizontal columns x 64 vertical IRE buckets)
    uint col = min(uint((float(gid.x) / float(max(width, 1u))) * 128.0f), 127u);
    uint ireBucket = min(uint(luma * 63.0f), 63u);
    atomic_fetch_add_explicit(&waveformBins[ireBucket * 128u + col], 1u, memory_order_relaxed);

    // 2. Rec.709 Cb/Cr Vectorscope (64 x 64 grid)
    float cb = -0.1146f * rgb.r - 0.3854f * rgb.g + 0.5000f * rgb.b;
    float cr =  0.5000f * rgb.r - 0.4542f * rgb.g - 0.0458f * rgb.b;
    uint vx = min(max(uint((cb + 0.5f) * 63.0f), 0u), 63u);
    uint vy = min(max(uint((0.5f - cr) * 63.0f), 0u), 63u);
    atomic_fetch_add_explicit(&vectorscopeBins[vy * 64u + vx], 1u, memory_order_relaxed);

    // 3. 4-Channel Histogram (R, G, B, Luma x 64 bins)
    uint rBin = min(uint(rgb.r * 63.0f), 63u);
    uint gBin = min(uint(rgb.g * 63.0f), 63u);
    uint bBin = min(uint(rgb.b * 63.0f), 63u);
    atomic_fetch_add_explicit(&histogramBins[0u * 64u + rBin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogramBins[1u * 64u + gBin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogramBins[2u * 64u + bBin], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogramBins[3u * 64u + ireBucket], 1u, memory_order_relaxed);
}
