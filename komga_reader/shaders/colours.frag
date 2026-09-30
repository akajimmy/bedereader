#version 460 core

#include <flutter/runtime_effect.glsl>

// "Enhance colours" (lib/enhance.dart), at the page's own resolution, one read per pixel:
//   1. Auto-levels - each channel stretched between the book's black and white point (lib/page_image.dart Levels)
//   2. Whiten paper - pale, low-colour areas (yellowed paper) towards white
//   3. Deepen ink - dark, low-colour areas (faded blacks) towards black
// The user's pick in the image lab (a local tuning page), 2026-09-29: auto-levels + whiten 1.0 + ink 1.0.
uniform vec2 uSize;
uniform vec3 uLo;
uniform vec3 uHi;
uniform float uWhiten;
uniform float uInk;
uniform sampler2D uImage;

out vec4 fragColor;

void main() {
  vec3 c = texture(uImage, FlutterFragCoord().xy / uSize).rgb;
  c = clamp((c - uLo) / max(uHi - uLo, vec3(1e-3)), 0.0, 1.0);
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
  float paper = smoothstep(0.55, 0.92, l) * (1.0 - smoothstep(0.10, 0.30, sat));
  c = mix(c, vec3(1.0), uWhiten * paper);
  float dark = (1.0 - smoothstep(0.08, 0.40, l)) * (1.0 - smoothstep(0.15, 0.35, sat));
  c = c * (1.0 - uInk * dark * 0.85);
  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
