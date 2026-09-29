#version 460 core

#include <flutter/runtime_effect.glsl>

// "3D page curl" page turn (lib/page_curl.dart): the page's image - only the comic page, not the black bars around
// it - taken from a snapshot of the screen and bent around a cylinder lying along the fold line. Its flat part is
// drawn as is; the part going over the cylinder and the part lying flipped on top show the back of the paper (the
// print faintly, mirrored, as through thin paper); where the page has lifted away the screen underneath shows, with
// a soft shadow along the curl. Transparent wherever none of the page is.
// The fold is given in the page's own coordinates (origin at its top-left corner in reading direction).
uniform vec2 uSize;    // area size, logical px (the snapshot covers all of it)
uniform vec4 uRect;    // the page's image within the area: x, y, width, height
uniform vec2 uFold;    // a point on the fold line (page coordinates)
uniform vec2 uNormal;  // unit normal of the fold line, pointing to the side that lifts
uniform float uRadius; // cylinder radius
uniform float uMirror; // 1 = right-to-left book: page coordinates run from the page's right edge
uniform sampler2D uSheet;

out vec4 fragColor;

const float PI = 3.14159265;

bool inside(vec2 q) { return q.x >= 0.0 && q.y >= 0.0 && q.x <= uRect.z && q.y <= uRect.w; }

vec3 sheet(vec2 q) {  // q in page coordinates
  if (uMirror > 0.5) q.x = uRect.z - q.x;
  return texture(uSheet, (q + uRect.xy) / uSize).rgb;
}

vec3 backOf(vec2 q) { return mix(sheet(q), vec3(0.97, 0.96, 0.94), 0.82); }  // paper, the print showing through

void main() {
  vec2 p = FlutterFragCoord().xy - uRect.xy;  // page coordinates
  if (uMirror > 0.5) p.x = uRect.z - p.x;
  float d = dot(p - uFold, uNormal);  // distance from the fold line, + on the lifting side
  vec4 o = vec4(0.0);

  if (d > uRadius) {
    // the page has lifted away here: whatever is underneath, darkened near the curl (only across the page's height)
    if (p.y >= 0.0 && p.y <= uRect.w) {
      float shade = (1.0 - clamp((d - uRadius) / (uRadius * 2.0 + 8.0), 0.0, 1.0)) * 0.35;
      o = vec4(0.0, 0.0, 0.0, shade);
    }
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
    }
  } else {
    // flat: the part already turned over lies on top here (its back), else the page itself - if this is the page
    vec2 qOver = p + uNormal * (PI * uRadius - 2.0 * d);
    if (inside(qOver)) {
      float edge = 1.0 - 0.12 * clamp(1.0 + d / (uRadius * 2.0), 0.0, 1.0);
      o = vec4(backOf(qOver) * edge, 1.0);
    } else if (inside(p)) {
      float nearFold = 1.0 - 0.18 * clamp(1.0 + d / (uRadius * 1.5), 0.0, 1.0);  // the fold's own shadow
      o = vec4(sheet(p) * nearFold, 1.0);
    }
  }
  fragColor = vec4(o.rgb * o.a, o.a);  // premultiplied
}
