#version 460 core

#include <flutter/runtime_effect.glsl>

// Page adjustments for the reader (lib/page_image.dart): unsharp mask, then per-channel scale + offset
// (auto-levels, contrast and brightness folded together on the Dart side).
uniform vec2 uSize;    // drawn size, logical px
uniform vec2 uTexel;   // 1 / image size
uniform vec3 uScale;
uniform vec3 uOffset;
uniform float uSharpen;
uniform sampler2D uImage;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec3 c = texture(uImage, uv).rgb;
  vec3 n = texture(uImage, uv + vec2(uTexel.x, 0.0)).rgb
         + texture(uImage, uv - vec2(uTexel.x, 0.0)).rgb
         + texture(uImage, uv + vec2(0.0, uTexel.y)).rgb
         + texture(uImage, uv - vec2(0.0, uTexel.y)).rgb;
  c = c + uSharpen * (4.0 * c - n);
  fragColor = vec4(clamp(c * uScale + uOffset, 0.0, 1.0), 1.0);
}
