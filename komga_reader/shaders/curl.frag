#version 460 core

#include <flutter/runtime_effect.glsl>

// "3D page curl" page turn (lib/page_curl.dart): a snapshot of the page, bent around a cylinder lying along the fold
// line. The page's own flat part is drawn as is; the part going over the cylinder and the part lying flipped on top
// show the back of the paper (the print faintly, mirrored, as through thin paper); where the page has lifted away
// the page underneath shows, with a soft shadow along the curl. Transparent where nothing of this page is.
uniform vec2 uSize;    // area size, logical px
uniform vec2 uFold;    // a point on the fold line
uniform vec2 uNormal;  // unit normal of the fold line, pointing to the side that lifts
uniform float uRadius; // cylinder radius
uniform float uMirror; // 1 = right-to-left book: the geometry is worked out mirrored
uniform sampler2D uSheet;

out vec4 fragColor;

const float PI = 3.14159265;

bool inside(vec2 q) { return q.x >= 0.0 && q.y >= 0.0 && q.x <= uSize.x && q.y <= uSize.y; }

vec3 sheet(vec2 q) {
  if (uMirror > 0.5) q.x = uSize.x - q.x;
  return texture(uSheet, q / uSize).rgb;
}

vec3 backOf(vec2 q) { return mix(sheet(q), vec3(0.97, 0.96, 0.94), 0.82); }  // paper, the print showing through

void main() {
  vec2 p = FlutterFragCoord().xy;
  if (uMirror > 0.5) p.x = uSize.x - p.x;
  float d = dot(p - uFold, uNormal);  // distance from the fold line, + on the lifting side
  vec4 o = vec4(0.0);

  if (d > uRadius) {
    // the page has lifted away here: the page underneath, darkened near the curl
    float shade = (1.0 - clamp((d - uRadius) / (uRadius * 2.0 + 8.0), 0.0, 1.0)) * 0.35;
    o = vec4(0.0, 0.0, 0.0, shade);
  } else if (d >= 0.0) {
    // on the cylinder: the back of the sheet coming over the top if there is any, else its front going up
    float th = asin(clamp(d / uRadius, -1.0, 1.0));
    vec2 qBack = p + uNormal * ((PI * uRadius - uRadius * th) - d);
    vec2 qFront = p + uNormal * (uRadius * th - d);
    if (inside(qBack)) {
      float light = 0.78 + 0.22 * cos(th);
      o = vec4(backOf(qBack) * light, 1.0);
    } else if (inside(qFront)) {
      float dark = 1.0 - 0.45 * (d / uRadius) * (d / uRadius);
      o = vec4(sheet(qFront) * dark, 1.0);
    } else {
      o = vec4(0.0, 0.0, 0.0, 0.25);
    }
  } else {
    // flat: the part already turned over lies on top here (its back), else the page itself
    vec2 qOver = p + uNormal * (PI * uRadius - 2.0 * d);
    if (inside(qOver)) {
      float edge = 1.0 - 0.12 * clamp(1.0 + d / (uRadius * 2.0), 0.0, 1.0);
      o = vec4(backOf(qOver) * edge, 1.0);
    } else {
      float nearFold = 1.0 - 0.18 * clamp(1.0 + d / (uRadius * 1.5), 0.0, 1.0);  // the fold's own shadow
      o = vec4(sheet(p) * nearFold, 1.0);
    }
  }
  fragColor = vec4(o.rgb * o.a, o.a);  // premultiplied
}
