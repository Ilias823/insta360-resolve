#pragma once

#include <vector>

#include "LensDecoder.h"
#include "StitchKernel.h"

// Motion blur like a long exposure, for hyperlapses and other sped-up footage: finds how the
// picture moves towards the frames before and after this one, then smears the finished frame
// along that movement. The neighbours are stitched small, from the lens files, with the same
// view and each with its own stabilisation; only the movement is taken from them.

// Size to stitch the neighbours at for a frame of p_Width x p_Height.
void MotionBlurSize(int p_Width, int p_Height, int& p_SmallWidth, int& p_SmallHeight);

// How the picture moves from p_From to p_To (both BGRA, p_Width x p_Height, row by row), as
// x, y per pixel of p_Flow in fractions of the picture's size, y counted in the rows' order.
bool OpticalFlow(const unsigned char* p_From, const unsigned char* p_To, int p_Width, int p_Height,
                 std::vector<float>& p_Flow, int& p_FlowWidth, int& p_FlowHeight);

// Frames 0, 1, 2 are the previous, this and the next: p_Params at MotionBlurSize with fullRes and
// trustDecoded set, p_Have false where there is no such frame. p_Input is any host buffer, bound
// but not read; p_Output is the finished frame of p_Width x p_Height, blurred in place.
// p_Amount 1 smears each pixel half way to where it is in the neighbouring frames.
// Waits for the GPU to stitch the neighbours. False leaves p_Output as it was.
bool RunMotionBlur(void* p_CmdQ, int p_Width, int p_Height, bool p_Wrap, float p_Amount, const StitchParams p_Params[3],
                   const LensImages p_Lenses[3], const bool p_Have[3], const float* p_Input, float* p_Output);
