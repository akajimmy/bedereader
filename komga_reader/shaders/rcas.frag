#version 460 core

#include <flutter/runtime_effect.glsl>

// Adapted from AMD FidelityFX Super Resolution 1 - Copyright (c) 2021 Advanced Micro Devices, Inc. MIT licence;
// the full notice is in THIRD_PARTY_NOTICES.md (and on the app's licences page).

// Enhance, step 3 of 3 (lib/enhance.dart), at screen resolution: RCAS, the sharpener of AMD FidelityFX FSR 1.
// The sharpening lobe is limited so no pixel is pushed past what its neighbours allow: crisper lines with little
// ringing, and flat areas left mostly alone. Tuned by the user in the image lab (a local tuning page): amount 0.6.
uniform vec2 uSize;     // size, px
uniform float uAmount;  // 0..1, 1 = strongest
uniform sampler2D uImage;

out vec4 fragColor;

vec3 at(vec2 p) { return texture(uImage, p / uSize).rgb; }

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec3 e = at(p);
  vec3 b = at(p + vec2(0.0, -1.0)), d = at(p + vec2(-1.0, 0.0)), f = at(p + vec2(1.0, 0.0)), h = at(p + vec2(0.0, 1.0));
  vec3 mn4 = min(min(b, d), min(f, h));
  vec3 mx4 = max(max(b, d), max(f, h));
  vec3 hitMin = mn4 / (4.0 * max(mx4, vec3(1e-5)));
  vec3 hitMax = (1.0 - mx4) / min(4.0 * mn4 - 4.0, vec3(-1e-5));
  vec3 lobeRGB = max(-hitMin, hitMax);
  float lobe = max(-0.1875, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * exp2(-(1.0 - uAmount) * 2.0);
  fragColor = vec4(clamp((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0), 0.0, 1.0), 1.0);
}
