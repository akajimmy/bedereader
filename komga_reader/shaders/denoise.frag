#version 460 core

#include <flutter/runtime_effect.glsl>

// Enhance, step 1 of 3 (lib/enhance.dart), at the page's own resolution: edge-preserving smoothing (a bilateral
// filter over 7x7). Colours closer than about uRange are averaged together - JPEG speckle, paper grain - while bigger
// jumps such as ink lines are left alone. Tuned by the user in tools/image-lab: Denoise 0.75 -> uRange 0.15.
uniform vec2 uSize;     // page size, px (this pass draws at that size)
uniform float uRange;
uniform sampler2D uImage;

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;  // pixel centre
  vec3 c = texture(uImage, p / uSize).rgb;
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  float r2 = 2.0 * uRange * uRange;
  for (int y = -3; y <= 3; y++) {
    for (int x = -3; x <= 3; x++) {
      vec3 s = texture(uImage, (p + vec2(float(x), float(y))) / uSize).rgb;
      vec3 dc = s - c;
      float w = exp(-float(x * x + y * y) / 2.0) * exp(-dot(dc, dc) / r2);
      acc += s * w;
      wsum += w;
    }
  }
  fragColor = vec4(acc / wsum, 1.0);
}
