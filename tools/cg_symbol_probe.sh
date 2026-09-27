#!/bin/bash
# Check which CoreGraphics geometry symbols are actually exported by the
# iOS 17.5 CoreGraphics tbd. This is the question the five failed FOV
# attempts never answered: dlsym can only find what the framework exports.
TBD=/home/tduck/theos/sdks/iPhoneOS17.5.sdk/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics.tbd
SYMS="CGPathAddEllipseInRect CGPathAddArc CGPathAddCurveToPoint CGPathAddQuadCurveToPoint CGPathAddLines CGPathAddRects CGPathAddRect CGPathCreateMutable CGPathRelease CGPathClear CGPathReset CGContextStrokePath CGContextAddPath CGContextBeginPath CGContextMoveToPoint CGContextAddLineToPoint CGContextStrokeLineToPoint CGContextStrokeLines CGContextStrokeRects CGContextFillPath CGContextSetLineWidth CGContextSetStrokeColorWithColor"

for s in $SYMS; do
  n=$(grep -c "_$s" "$TBD" 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    printf '%-38s PRESENT (%s)\n' "$s" "$n"
  else
    printf '%-38s ABSENT\n' "$s"
  fi
done
