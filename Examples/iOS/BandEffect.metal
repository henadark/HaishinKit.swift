#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

// Смуга поверх кадру (не змінює висоту виходу)
float4 bandMaskOverlay(
sampler src,
sampler mask,
float widthPx, float heightPx,
float bandY, float bandH,
float bits,
float wR, float wG, float wB,
float bR, float bG, float bB,
float outMinX, float outWidth,
destination dest
                       ) {
    float2 d = dest.coord();
    // Поза смугою — оригінал
    if (d.y < bandY || d.y >= bandY + bandH) {
        return src.sample(src.transform(d));
    }

    // Обчислюємо клітинку за координатою X у вихідному просторі
    float u = clamp((d.x - outMinX) / max(1.0f, outWidth), 0.0f, 0.999999f);
    float i = floor(u * bits);
    float  m = mask.sample(float2((i + 0.5f) / bits, 0.5f)).r; // ~0 або ~1

    float3 white = float3(wR, wG, wB);
    float3 black = float3(bR, bG, bB);
    float3 color = mix(white, black, step(0.5f, m)); // 0 -> white, 1 -> black
    return float4(color, 1.0f);
}

// Смуга під відео (висота виходу = heightPx + bandH, відео зсунуте вгору)
float4 bandMaskUnder(
sampler src,
sampler mask,
float widthPx, float heightPx,
float bandY, float bandH,
float bits,
float wR, float wG, float wB,
float bR, float bG, float bB,
float outMinX, float outWidth,
destination dest
                     ) {
    float2 d = dest.coord();
    // Нижня смуга
    if (d.y < bandH) {
        float u = clamp((d.x - outMinX) / max(1.0f, outWidth), 0.0f, 0.999999f);
        float i = floor(u * bits);
        float  m      = mask.sample(float2((i + 0.5f) / bits, 0.5f)).r;

        float3 white = float3(wR, wG, wB);
        float3 black = float3(bR, bG, bB);
        float3 color = mix(white, black, step(0.5f, m));
        return float4(color, 1.0f);
    } else {
        // Відео: семплимо із зсувом вниз на bandH (щоб у виході воно було вище)
        float2 s = src.transform(d + float2(0.0f, -bandH));
        return src.sample(s);
    }
}

}} // extern "C" / namespace coreimage
