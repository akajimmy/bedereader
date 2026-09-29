#version 460 core

#include <flutter/runtime_effect.glsl>

// Enhance, step 2 when the page is enlarged (lib/enhance.dart): EASU, the edge-adaptive upscaler of AMD FidelityFX
// FSR 1 (MIT). From 12 page pixels around each screen pixel it finds the local edge direction and stretches its
// filter along it, so enlarged diagonal lines and lettering stay smooth instead of stair-stepped or blurred. One
// pass (Lanczos 3 needs two). Shrunk pages still use Lanczos (shaders/lanczos.frag). Chosen by the user in
// tools/image-lab, 2026-09-29.
uniform vec2 uOut;  // output size, px
uniform vec2 uIn;   // page size, px
uniform sampler2D uImage;

out vec4 fragColor;

vec3 tp(vec2 q) { return texture(uImage, (clamp(q, vec2(0.0), uIn - 1.0) + 0.5) / uIn).rgb; }
float L(vec3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }  // FSR's luma approximation

void easuSet(inout vec2 dir, inout float len, float w, float lA, float lB, float lC, float lD, float lE) {
  float dc = lD - lC, cb = lC - lB;
  float lenX = 1.0 / max(max(abs(dc), abs(cb)), 1e-5);
  float dirX = lD - lB;
  dir.x += dirX * w;
  lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
  len += lenX * lenX * w;
  float ec = lE - lC, ca = lC - lA;
  float lenY = 1.0 / max(max(abs(ec), abs(ca)), 1e-5);
  float dirY = lE - lA;
  dir.y += dirY * w;
  lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
  len += lenY * lenY * w;
}

void easuTap(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len2, float lob, float clp, vec3 c) {
  vec2 v = vec2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len2;
  float d2 = min(v.x * v.x + v.y * v.y, clp);
  float wB = 2.0 / 5.0 * d2 - 1.0;
  float wA = lob * d2 - 1.0;
  wB *= wB;
  wA *= wA;
  wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
  float w = wB * wA;
  aC += c * w;
  aW += w;
}

void main() {
  vec2 pp = FlutterFragCoord().xy / uOut * uIn - 0.5;  // page pixel coordinates (centres at integers)
  vec2 fp = floor(pp);
  vec2 f = pp - fp;
  //    b c
  //  e f g h
  //  i j k l
  //    n o
  vec3 b = tp(fp + vec2(0.0, -1.0)), c = tp(fp + vec2(1.0, -1.0));
  vec3 e = tp(fp + vec2(-1.0, 0.0)), ff = tp(fp), g = tp(fp + vec2(1.0, 0.0)), h = tp(fp + vec2(2.0, 0.0));
  vec3 i = tp(fp + vec2(-1.0, 1.0)), j = tp(fp + vec2(0.0, 1.0)), k = tp(fp + vec2(1.0, 1.0)), l = tp(fp + vec2(2.0, 1.0));
  vec3 n = tp(fp + vec2(0.0, 2.0)), o = tp(fp + vec2(1.0, 2.0));
  float bL = L(b), cL = L(c), eL = L(e), fL = L(ff), gL = L(g), hL = L(h);
  float iL = L(i), jL = L(j), kL = L(k), lL = L(l), nL = L(n), oL = L(o);

  vec2 dir = vec2(0.0);
  float len = 0.0;
  easuSet(dir, len, (1.0 - f.x) * (1.0 - f.y), bL, eL, fL, gL, jL);
  easuSet(dir, len, f.x * (1.0 - f.y), cL, fL, gL, hL, kL);
  easuSet(dir, len, (1.0 - f.x) * f.y, fL, iL, jL, kL, nL);
  easuSet(dir, len, f.x * f.y, gL, jL, kL, lL, oL);

  vec2 dir2 = dir * dir;
  float dirR = dir2.x + dir2.y;
  bool zro = dirR < 1.0 / 32768.0;
  dirR = zro ? 1.0 : inversesqrt(dirR);
  dir.x = zro ? 1.0 : dir.x;
  dir *= dirR;
  len = len * 0.5;
  len *= len;
  float stretch = (dir.x * dir.x + dir.y * dir.y) / max(abs(dir.x), abs(dir.y));
  vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
  float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
  float clp = 1.0 / lob;

  vec3 aC = vec3(0.0);
  float aW = 0.0;
  easuTap(aC, aW, vec2(0.0, -1.0) - f, dir, len2, lob, clp, b);
  easuTap(aC, aW, vec2(1.0, -1.0) - f, dir, len2, lob, clp, c);
  easuTap(aC, aW, vec2(-1.0, 1.0) - f, dir, len2, lob, clp, i);
  easuTap(aC, aW, vec2(0.0, 1.0) - f, dir, len2, lob, clp, j);
  easuTap(aC, aW, vec2(0.0, 0.0) - f, dir, len2, lob, clp, ff);
  easuTap(aC, aW, vec2(-1.0, 0.0) - f, dir, len2, lob, clp, e);
  easuTap(aC, aW, vec2(1.0, 1.0) - f, dir, len2, lob, clp, k);
  easuTap(aC, aW, vec2(2.0, 1.0) - f, dir, len2, lob, clp, l);
  easuTap(aC, aW, vec2(2.0, 0.0) - f, dir, len2, lob, clp, h);
  easuTap(aC, aW, vec2(1.0, 0.0) - f, dir, len2, lob, clp, g);
  easuTap(aC, aW, vec2(1.0, 2.0) - f, dir, len2, lob, clp, o);
  easuTap(aC, aW, vec2(0.0, 2.0) - f, dir, len2, lob, clp, n);
  // no ringing past the 2x2 around it
  vec3 mn = min(min(ff, g), min(j, k));
  vec3 mx = max(max(ff, g), max(j, k));
  fragColor = vec4(clamp(aC / aW, mn, mx), 1.0);
}
