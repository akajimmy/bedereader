#version 460 core

#include <flutter/runtime_effect.glsl>

// Enhance, step 2 of 3 (lib/enhance.dart): Lanczos-3 scaling to the size the page is shown at, one axis per pass
// (horizontal, then vertical - 16 taps each instead of 256 at once). When shrinking, the filter is widened by
// 1/scale so fine detail (halftone dots) averages out instead of shimmering.
uniform vec2 uOut;        // this pass's output size, px
uniform vec2 uIn;         // input size, px
uniform float uAxis;      // 0 = horizontal, 1 = vertical
uniform float uStretch;   // >= 1: filter widening when shrinking along this axis
uniform sampler2D uImage;

out vec4 fragColor;

const float PI = 3.14159265;

float lanczos3(float x) {
  x = abs(x);
  if (x < 1e-5) return 1.0;
  if (x >= 3.0) return 0.0;
  float px = PI * x;
  return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  bool horizontal = uAxis < 0.5;
  float outLen = horizontal ? uOut.x : uOut.y;
  float inLen = horizontal ? uIn.x : uIn.y;
  float pos = (horizontal ? frag.x : frag.y) / outLen * inLen - 0.5;  // in input pixels
  float base = floor(pos);
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  for (int i = -7; i <= 8; i++) {  // covers a widening up to ~2.7 (shrinking to 0.37)
    float s = base + float(i);
    float w = lanczos3((s - pos) / uStretch);
    if (w != 0.0) {
      float t = (clamp(s, 0.0, inLen - 1.0) + 0.5) / inLen;
      vec2 uv = horizontal ? vec2(t, frag.y / uIn.y) : vec2(frag.x / uIn.x, t);
      acc += texture(uImage, uv).rgb * w;
      wsum += w;
    }
  }
  fragColor = vec4(clamp(acc / wsum, 0.0, 1.0), 1.0);
}
