#include <AppKit/AppKit.h>
#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <MetalKit/MetalKit.h>
#include <objc/runtime.h>

typedef void *Renderer;
typedef void *Editor;

#define ARENA_ALIGN (alignof(max_align_t))

Renderer renderer_create(id view, id device);
Renderer renderer_draw(Renderer renderer, id view);
void renderer_resize(Renderer renderer, CGSize new_size);
void renderer_handle_keydown(Renderer renderer, NSEvent *event);
void renderer_handle_scroll(Renderer renderer, CGFloat dx, CGFloat dy,
                            NSEventPhase phase);

// debugging functions
void renderer_insert_text(Renderer renderer, const char *text, size_t len);
size_t renderer_get_val(Renderer);
