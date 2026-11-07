#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace ColorDiscoMetal {

    // ITU-R BT.709 luminance coefficients
    constant float3 kRec709Luma = float3(0.2126f, 0.7152f, 0.0722f);

    // Converts RGB [0,1] to HSV/HSL domain
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
        float r = hueToRgb(p, q, h + 1.0f / 3.0f);
        float g = hueToRgb(p, q, h);
        float b = hueToRgb(p, q, h - 1.0f / 3.0f);
        return float3(r, g, b);
    }

    // Cosine bell weight for smooth 8-band HSL qualification without hard mattes
    inline float hueBandWeight(float hue, float centerHue, float width) {
        float diff = abs(hue - centerHue);
        diff = min(diff, 1.0f - diff);
        if (diff >= width) return 0.0f;
        float normalized = diff / width;
        return 0.5f * (1.0f + cos(normalized * M_PI_F));
    }

    // Deterministic spatial hash for zero-mean Triangular PDF micro-dither
    inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031f);
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.x + p3.y) * p3.z);
    }
}

extern "C" {
    namespace coreimage {

        /// Stitchable Metal kernel: 3-Way Color Corrector (Lift, Gamma, Gain) in linear/working space.
        [[ stitchable ]] float4 threeWayColorWheelsKernel(
            sample_t s,
            float4 liftRGBA,
            float4 gammaRGBA,
            float4 gainRGBA
        ) {
            float3 rgb = s.rgb;
            float luma = dot(rgb, ColorDiscoMetal::kRec709Luma);

            float shadowMask = clamp(1.0f - luma * 1.5f, 0.0f, 1.0f);
            float highlightMask = clamp((luma - 0.35f) * 1.5f, 0.0f, 1.0f);
            float midtoneMask = clamp(1.0f - abs(luma - 0.5f) * 2.0f, 0.0f, 1.0f);

            float3 liftOffset = (liftRGBA.rgb + liftRGBA.w) * 0.22f;
            float3 gainScale = max(float3(0.05f), 1.0f + gainRGBA.rgb + gainRGBA.w);
            float3 gammaPower = clamp(1.0f - (gammaRGBA.rgb + gammaRGBA.w) * 0.65f, 0.25f, 2.5f);

            rgb = rgb * mix(float3(1.0f), gainScale, highlightMask) + liftOffset * shadowMask;
            rgb = max(rgb, float3(0.0f));
            rgb = mix(rgb, pow(max(rgb, float3(1e-5f)), gammaPower), midtoneMask);

            return float4(clamp(rgb, 0.0f, 1.0f), s.a);
        }

        /// Stitchable Metal kernel: 8-Band HSL Secondary Qualifier (Hue, Saturation, Luminance shift).
        /// Center Hue is normalized in [0, 1] (e.g., 0.0 = Red, 0.08 = Orange/Skin, 0.60 = Blue).
        [[ stitchable ]] float4 hslBandAdjustKernel(
            sample_t s,
            float centerHue,
            float hueShift,
            float satDelta,
            float lumaDelta
        ) {
            float3 hsl = ColorDiscoMetal::rgbToHsl(s.rgb);
            float weight = ColorDiscoMetal::hueBandWeight(hsl.x, centerHue, 0.11f) * clamp(hsl.y * 2.0f, 0.0f, 1.0f);
            if (weight < 1e-4f) {
                return s;
            }

            hsl.x = fract(hsl.x + hueShift * 0.15f * weight);
            hsl.y = clamp(hsl.y * (1.0f + satDelta * weight), 0.0f, 1.0f);
            hsl.z = clamp(hsl.z + lumaDelta * 0.25f * weight, 0.0f, 1.0f);

            float3 outRgb = ColorDiscoMetal::hslToRgb(hsl);
            return float4(outRgb, s.a);
        }

        /// Stitchable Metal kernel: HDR (PQ SMPTE ST 2084 / HLG BT.2100) to Rec. 709 100-nit SDR Tonemap.
        [[ stitchable ]] float4 hdrToRec709TonemapKernel(
            sample_t s,
            float headroomKnee
        ) {
            float3 c = max(s.rgb, float3(0.0f));
            // BT.2020 to Rec.709 gamut compression approximation + Reinhard knee roll-off
            float luma = dot(c, float3(0.2627f, 0.6780f, 0.0593f));
            float mappedLuma = (luma * (1.0f + luma / max(headroomKnee * headroomKnee, 1.0f))) / (1.0f + luma);
            float scale = (luma > 1e-5f) ? (mappedLuma / luma) : 1.0f;
            float3 mapped = c * scale;
            return float4(clamp(mapped, 0.0f, 1.0f), s.a);
        }

        /// Stitchable Metal kernel: Zero-mean Triangular PDF 0.5 LSB Anti-Banding Micro-Dither.
        [[ stitchable ]] float4 triangularPDFDitherKernel(
            sample_t s,
            float lsbAmplitude,
             destination dest
        ) {
            float2 coord = dest.coord();
            float u1 = ColorDiscoMetal::hash12(coord);
            float u2 = ColorDiscoMetal::hash12(coord + float2(19.19f, 73.41f));
            // Sum of two independent uniform distributions in [0,1] minus 1 produces a Triangular PDF in [-1, 1]
            float tpdf = (u1 + u2) - 1.0f;
            float ditherStep = (lsbAmplitude / 255.0f) * tpdf;
            return float4(clamp(s.rgb + ditherStep, 0.0f, 1.0f), s.a);
        }
    }
}
