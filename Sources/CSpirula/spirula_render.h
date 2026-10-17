// C interface of Spirula Studio's 3DGS renderer (libspirula_render.dylib,
// built from src/blender/SplatRenderC.cpp in the spirula-studio fork).
// Conventions: a trained PLY as stored -- means [N,3], quats [N,4] wxyz,
// log scales [N,3], logit opacities [N], SH DC [N,3], higher SH [N,K,3]
// coefficient-major. viewmat: world-to-camera 4x4 row-major, OpenCV axes
// (x right, y down, z forward). Every int return is 0 on success.
#pragma once
#include <stddef.h>
#include <stdint.h>

const char* sr_last_error(void);
int sr_set_splats(int64_t num, int sh_degree, const float* means, const float* quats,
                  const float* scales, const float* opacities, const float* features_dc,
                  const float* features_sh);
int sr_render(const float* viewmat, float fx, float fy, float cx, float cy, int width,
              int height, const char* primitive, float* out_rgb, float* out_alpha,
              float* out_depth);
void sr_set_render_degree(int degree);
void sr_shutdown(void);

// Zero-copy output: `count` GPU frames, each W*H float3 rgb (premultiplied)
// then W*H float transmittance. out_buffers[i] = unretained id<MTLBuffer>,
// out_offsets[i] = byte offset of frame i inside it.
int sr_shared_frames(int width, int height, int count, void** out_buffers,
                     size_t* out_offsets);
// Render into shared frame `frame` and wait for the GPU to finish.
int sr_render_to_frame(int frame, const float* viewmat, float fx, float fy, float cx,
                       float cy, const char* primitive);
// Depth of field inside the render: `count` float4 lens parameters (layout in
// the spirula fork's docs/notes/lens-defocus.md), or NULL for a pinhole.
int sr_set_lens(const float* params, int count);
// Adds `count` shared frames of this size (numbered from *first_index), next
// to any others; each renders at its own size.
int sr_add_shared_frames(int width, int height, int count, void** out_buffers,
                         size_t* out_offsets, int* first_index);
// The splats' SH DC colours [N,3] fp32 on the GPU, to relight in place
// (render with sr_set_render_degree(0)): unretained id<MTLBuffer> + offset.
int sr_color_buffer(void** out_buffer, size_t* out_offset);
// "PINHOLE" (default) or "FISHEYE" (equidistant: radius = f * angle) for later renders.
int sr_set_camera_model(const char* name);
