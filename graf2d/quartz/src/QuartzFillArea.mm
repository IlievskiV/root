// @(#)root/graf2d:$Id$
// Author: Olivier Couet, 23/01/2012

/*************************************************************************
 * Copyright (C) 1995-2011, Rene Brun and Fons Rademakers.               *
 * All rights reserved.                                                  *
 *                                                                       *
 * For the licensing terms see $ROOTSYS/LICENSE.                         *
 * For the list of contributors see $ROOTSYS/README/CREDITS.             *
 *************************************************************************/

#include <algorithm>
#include <cassert>
#include <vector>

#include "QuartzFillArea.h"
#include "TColorGradient.h"
#include "QuartzLine.h"
#include "CocoaUtils.h"
#include "TVirtualX.h"
#include "RStipples.h"
#include "TError.h"
#include "TROOT.h"

//TODO: either use Color_t or use gVirtualX->GetLine/Fill/Color -
//not both, it's a complete mess now!

namespace ROOT {
namespace Quartz {

namespace Util = MacOSX::Util;

namespace {

const CGSize shadowOffset = CGSizeMake(10., 10.);
const CGFloat shadowBlur = 5.;


//ROOT has TColorGradient, TLinearGradient and TRadialGradient -
//they all specify parameters in NDC. But for rendering with
//Quartz I need more specific parameters, I calculate them here.

struct GradientParameters {
   //
   CGPoint fStartPoint;
   CGPoint fEndPoint;

   //Only for radial gradient fill:
   CGFloat fStartRadius;
   CGFloat fEndRadius;
   
   //Something else:...
   
   GradientParameters()
      : fStartRadius(0.), fEndRadius(0.)
   {
   }
   
   GradientParameters(const CGPoint &start, const CGPoint &end)
      : fStartPoint(start), fEndPoint(end), fStartRadius(0.), fEndRadius(0.)
   {
   }


   GradientParameters(const CGPoint &start, const CGPoint &end,
                      CGFloat startRadius, CGFloat endRadius)
      : fStartPoint(start), fEndPoint(end), fStartRadius(startRadius), fEndRadius(endRadius)
   {
   }

};

//______________________________________________________________________________
CGRect FindBoundingBox(Int_t nPoints, const TPoint *xy)
{
   //When calculating gradient parameters for TColorGradient::kObjectBoundingMode
   //we need a bounding rect for a polygon.
   assert(nPoints > 2 && "FindBoundingBox, invalid number of points in a polygon");
   assert(xy != 0 && "FindBoundingBox, parameter 'xy' is null");
   
   CGPoint bottomLeft = {};
   bottomLeft.x = xy[0].fX;
   bottomLeft.y = xy[0].fY;
   
   CGPoint topRight = bottomLeft;
   
   for (Int_t i = 1; i < nPoints; ++i) {
      bottomLeft.x = std::min(bottomLeft.x, CGFloat(xy[i].fX));
      bottomLeft.y = std::min(bottomLeft.y, CGFloat(xy[i].fY));
      //
      topRight.x = std::max(topRight.x, CGFloat(xy[i].fX));
      topRight.y = std::max(topRight.y, CGFloat(xy[i].fY));
   }
   
   return CGRectMake(bottomLeft.x, bottomLeft.y,
                     topRight.x - bottomLeft.x,
                     topRight.y - bottomLeft.y);
}

//______________________________________________________________________________
bool CalculateGradientParameters(const TColorGradient *extendedColor,
                                 const CGSize &sizeOfDrawable,
                                 Int_t n, const TPoint *polygon,
                                 GradientParameters &params)
{
   assert(extendedColor != 0 &&
          "CalculateGradientParameters, parameter 'extendedColor' is null");
   assert(dynamic_cast<const TLinearGradient *>(extendedColor) != 0 &&
          "CalculateGradientParameters, unknown gradient type");
   assert(sizeOfDrawable.width > 0. && sizeOfDrawable.height > 0. &&
          "CalculateGradientParameters, invalid destination drawable size");
   assert(n > 2 && "CalculateGradientPoints, parameter 'n' is not a valid number of points");
   assert(polygon != 0 && "CalculateGradientPoints, parameter 'polygon' is null");
   
   //TODO: check-check-check-chek - it's just a test and can be wrong!!!
   const TLinearGradient * const grad = static_cast<const TLinearGradient *>(extendedColor);
   const TColorGradient::ECoordinateMode mode = grad->GetCoordinateMode();

   CGPoint start = CGPointMake(grad->GetStart().fX, grad->GetStart().fY);
   CGPoint end = CGPointMake(grad->GetEnd().fX, grad->GetEnd().fY);
   
   const CGRect &bbox = FindBoundingBox(n, polygon);

   if (!bbox.size.width || !bbox.size.height)
      return false;//Invalid polygon actually.

   if (mode == TColorGradient::kObjectBoundingMode) {
      //With Quartz we always work with something similar to 'kPadMode',
      //so convert start and end into this space.
      start.x = bbox.size.width * start.x + bbox.origin.x;
      end.x = bbox.size.width * end.x + bbox.origin.x;

      start.y = bbox.size.height * start.y + bbox.origin.y;
      end.y = bbox.size.height * end.y + bbox.origin.y;
   } else {
      start.x *= sizeOfDrawable.width;
      start.y *= sizeOfDrawable.height;
      end.x *= sizeOfDrawable.width;
      end.y *= sizeOfDrawable.height;
   }
   
   params.fStartPoint = start;
   params.fEndPoint = end;
   
   if (const TRadialGradient * const radial = dynamic_cast<const TRadialGradient *>(extendedColor)) {
      CGFloat startRadius = radial->GetR1();
      CGFloat endRadius = radial->GetR2();

      if (mode == TColorGradient::kObjectBoundingMode) {
         const CGFloat scale = bbox.size.width < bbox.size.height ?
                               bbox.size.height : bbox.size.width;
         
         startRadius *= scale;
         endRadius *= scale;
      } else {
         const CGFloat scale = sizeOfDrawable.width < sizeOfDrawable.height ?
                               sizeOfDrawable.height : sizeOfDrawable.width;
         startRadius *= scale;
         endRadius *= scale;
      }
      
      params.fStartRadius = startRadius;
      params.fEndRadius = endRadius;
   }

   return true;
}

}//Unnamed namespace.

//______________________________________________________________________________
Bool_t SetFillColor(CGContextRef ctx, Color_t colorIndex)
{
   assert(ctx != 0 && "SetFillColor, ctx parameter is null");

   const TColor *color = gROOT->GetColor(colorIndex);
   
   //TGX11 selected color 0 (which is white).
   if (!color)
      color = gROOT->GetColor(kWhite);
   //???
   if (!color)
      return kFALSE;

   const CGFloat alpha = color->GetAlpha();

   Float_t rgb[3] = {};
   color->GetRGB(rgb[0], rgb[1], rgb[2]);
   CGContextSetRGBFillColor(ctx, rgb[0], rgb[1], rgb[2], alpha);
   
   return kTRUE;
}

//______________________________________________________________________________
void DrawPattern(void *data, CGContextRef ctx)
{
   assert(data != 0 && "DrawPattern, data parameter is null");
   assert(ctx != 0 && "DrawPattern, ctx parameter is null");

   //Draw a stencil pattern from gStipples
   const unsigned stencilIndex = *static_cast<unsigned *>(data);

   for (int i = 30, y = 0; i >= 0; i -= 2, ++y) {
      int x = 0;
      for (int j = 0; j < 8; ++j, ++x) {
         if (gStipples[stencilIndex][i] & (1 << j))
            CGContextFillRect(ctx, CGRectMake(x, y, 1, 1));
      }
      
      for (int j = 0; j < 8; ++j, ++x) {
         if (gStipples[stencilIndex][i + 1] & (1 << j))
            CGContextFillRect(ctx, CGRectMake(x, y, 1, 1));
      }
   }
}

//______________________________________________________________________________
bool SetFillPattern(CGContextRef ctx, const unsigned *patternIndex)
{
   assert(ctx != 0 && "SetFillPattern, ctx parameter is null");
   assert(patternIndex != 0 && "SetFillPattern, patternIndex parameter is null");

   const TColor *fillColor = gROOT->GetColor(gVirtualX->GetFillColor());
   if (!fillColor)
      fillColor = gROOT->GetColor(kWhite);
   
   if (!fillColor)
      return false;

   CGFloat rgba[] = {fillColor->GetRed(), fillColor->GetGreen(), fillColor->GetBlue(), fillColor->GetAlpha()};


   const Util::CFScopeGuard<CGColorSpaceRef> baseSpace(CGColorSpaceCreateDeviceRGB());
   if (!baseSpace.Get())
      return false;

   const Util::CFScopeGuard<CGColorSpaceRef> patternSpace(CGColorSpaceCreatePattern (baseSpace.Get()));
   if (!patternSpace.Get())
      return false;

   CGContextSetFillColorSpace(ctx, patternSpace.Get());

   CGPatternCallbacks callbacks = {0, &DrawPattern, 0};
   const Util::CFScopeGuard<CGPatternRef> pattern(CGPatternCreate((void*)patternIndex,
                                                  CGRectMake(0, 0, 16, 16),
                                                  CGAffineTransformIdentity, 16, 16,
                                                  kCGPatternTilingConstantSpacing,
                                                  false, &callbacks));

   if (!pattern.Get())
      return false;

   CGContextSetFillPattern(ctx, pattern.Get(), rgba);

   return true;
}

//______________________________________________________________________________
bool SetFillAreaParameters(CGContextRef ctx, unsigned *patternIndex)
{
   assert(ctx != 0 && "SetFillAreaParameters, ctx parameter is null");
   
   const unsigned fillStyle = gVirtualX->GetFillStyle() / 1000;
   
   //2 is hollow, 1 is solid and 3 is a hatch, !solid and !hatch - this is from O.C.'s code.
   if (fillStyle == 2 || (fillStyle != 1 && fillStyle != 3)) {
      if (!SetLineColor(ctx, gVirtualX->GetFillColor())) {
         ::Error("SetFillAreaParameters", "Line color for index %d was not found", int(gVirtualX->GetLineColor()));
         return false;
      }
   } else if (fillStyle == 1) {
      //Solid fill.
      if (!SetFillColor(ctx, gVirtualX->GetFillColor())) {
         ::Error("SetFillAreaParameters", "Fill color for index %d was not found", int(gVirtualX->GetFillColor()));
         return false;
      }
   } else {
      assert(patternIndex != 0 && "SetFillAreaParameters, pattern index in null");

      *patternIndex = gVirtualX->GetFillStyle() % 1000;
      //ROOT has 26 fixed patterns.
      if (*patternIndex > 25)
         *patternIndex = 2;

      if (!SetFillPattern(ctx, patternIndex)) {
         ::Error("SetFillAreaParameters", "SetFillPattern failed");
         return false;
      }
   }

   return true;
}
   
//______________________________________________________________________________
void DrawBox(CGContextRef ctx, Int_t x1, Int_t y1, Int_t x2, Int_t y2, bool hollow)
{
   // Draw a box
            
   if (x1 > x2)
      std::swap(x1, x2);
   if (y1 > y2)
      std::swap(y1, y2);
   
   if (hollow)
      CGContextStrokeRect(ctx, CGRectMake(x1, y1, x2 - x1, y2 - y1));
   else
      CGContextFillRect(ctx, CGRectMake(x1, y1, x2 - x1, y2 - y1));
}

//______________________________________________________________________________
void DrawFillArea(CGContextRef ctx, Int_t n, TPoint *xy, Bool_t shadow)
{
   // Draw a filled area through all points.
   // n         : number of points
   // xy        : list of points

   assert(ctx != 0 && "DrawFillArea, ctx parameter is null");
   assert(xy != 0 && "DrawFillArea, xy parameter is null");
                  
   CGContextBeginPath(ctx);
      
   CGContextMoveToPoint(ctx, xy[0].fX, xy[0].fY);
   for (Int_t i = 1; i < n; ++i) 
      CGContextAddLineToPoint(ctx, xy[i].fX, xy[i].fY);

   CGContextClosePath(ctx);
      
   const unsigned fillStyle = gVirtualX->GetFillStyle() / 1000;
   
   //2 is hollow, 1 is solid and 3 is a hatch, !solid and !hatch - this is from O.C.'s code.
   if (fillStyle == 2 || (fillStyle != 1 && fillStyle != 3)) {
      CGContextStrokePath(ctx);
   } else if (fillStyle == 1) {
      if (shadow)
         CGContextSetShadow(ctx, shadowOffset, shadowBlur);
      
      CGContextFillPath(ctx);
   } else {
      if (shadow)
         CGContextSetShadow(ctx, shadowOffset, shadowBlur);

      CGContextFillPath(ctx);
   }
}

//______________________________________________________________________________
void DrawPolygonWithGradientFill(CGContextRef ctx, const TColorGradient *extendedColor, const CGSize &sizeOfDrawable,
                                 Int_t nPoints, const TPoint *xy, Bool_t drawShadow)
{
   using ROOT::MacOSX::Util::CFScopeGuard;

   assert(ctx != nullptr && "DrawPolygonWithGradientFill, ctx parameter is null");
   assert(nPoints != 0 && "DrawPolygonWithGradientFill, nPoints parameter is 0");
   assert(xy != nullptr && "DrawPolygonWithGradientFill, xy parameter is null");
   assert(extendedColor != nullptr &&
          "DrawPolygonWithGradientFill, extendedColor parameter is null");

   if (!sizeOfDrawable.width || !sizeOfDrawable.height)
      return;

   const CFScopeGuard<CGMutablePathRef> path(CGPathCreateMutable());
   if (!path.Get()) {
      ::Error("DrawPolygonWithGradientFill", "CGPathCreateMutable failed");
      return;
   }
   
   //Create a gradient.
   //TODO: must be a generic RGB color space???
   const CFScopeGuard<CGColorSpaceRef> baseSpace(CGColorSpaceCreateDeviceRGB());
   if (!baseSpace.Get()) {
      ::Error("DrawPolygonWithGradientFill", "CGColorSpaceCreateDeviceRGB failed");
      return;
   }
   
   const CFScopeGuard<CGGradientRef> gradient(CGGradientCreateWithColorComponents(baseSpace.Get(),
                                              extendedColor->GetColors(),
                                              extendedColor->GetColorPositions(),
                                              extendedColor->GetNumberOfSteps()));

   if (!gradient.Get()) {
      ::Error("DrawPolygonWithGradientFill", "CGGradientCreateWithColorComponents failed");
      return;
   }
   

   CGPathMoveToPoint(path.Get(), nullptr, xy[0].fX, xy[0].fY);
   for (Int_t i = 1; i < nPoints; ++i)
      CGPathAddLineToPoint(path.Get(), nullptr, xy[i].fX, xy[i].fY);
   
   CGPathCloseSubpath(path.Get());
   
   if (drawShadow) {
      //To have shadow and gradient at the same time,
      //I first have to fill polygon, and after that
      //draw gradient (since gradient fills the whole area
      //with clip path and generates no shadow).
      CGContextSetRGBFillColor(ctx, 1., 1., 1., 0.5);
      CGContextBeginPath(ctx);
      CGContextAddPath(ctx, path.Get());
      CGContextSetShadow(ctx, shadowOffset, shadowBlur);
      CGContextFillPath(ctx);
   }

   CGContextBeginPath(ctx);
   CGContextAddPath(ctx, path.Get());
   CGContextClip(ctx);

   GradientParameters params;
   if (!CalculateGradientParameters(extendedColor, sizeOfDrawable, nPoints, xy, params))
      return;

   if (dynamic_cast<const TRadialGradient *>(extendedColor) && params.fStartRadius && params.fEndRadius) {
      CGContextDrawRadialGradient(ctx, gradient.Get(), params.fStartPoint, params.fStartRadius,
                                  params.fEndPoint, params.fEndRadius,
                                  kCGGradientDrawsAfterEndLocation |
                                  kCGGradientDrawsBeforeStartLocation);
   } else {
      CGContextDrawLinearGradient(ctx, gradient.Get(),
                                  params.fStartPoint, params.fEndPoint,
                                  kCGGradientDrawsAfterEndLocation |
                                  kCGGradientDrawsBeforeStartLocation);
   }
}

}//namespace Quartz
}//namespace ROOT
