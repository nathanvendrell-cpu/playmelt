/* Process-local display protection for Playmelt-owned Wine launches.
 * Never capture/release a real screen, change its mode or restore a global mode.
 * Returning an error lets games retain their ordinary desktop/window mode.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <math.h>

unsigned PMDisplayGuardVersion(void) { return 1; }
CGError PMBlockedCaptureAllDisplays(void) { return kCGErrorNotImplemented; }
static CGError capture_options(uint32_t options) { (void)options; return kCGErrorNotImplemented; }
static CGError capture_display(CGDirectDisplayID display) { (void)display; return kCGErrorNotImplemented; }
static CGError capture_display_options(CGDirectDisplayID display,uint32_t options) { (void)display;(void)options;return kCGErrorNotImplemented; }
static CGError release_all(void) { return kCGErrorSuccess; }
static CGError release_display(CGDirectDisplayID display) { (void)display;return kCGErrorSuccess; }
static void restore_modes(void) {}
static CGError set_mode(CGDirectDisplayID display,CGDisplayModeRef mode,CFDictionaryRef options) {
    (void)options;
    if (!mode) return kCGErrorIllegalArgument;
    CGDisplayModeRef current=CGDisplayCopyDisplayMode(display);
    if (!current) return kCGErrorInvalidConnection;
    const int same=CGDisplayModeGetWidth(current)==CGDisplayModeGetWidth(mode) &&
        CGDisplayModeGetHeight(current)==CGDisplayModeGetHeight(mode) &&
        CGDisplayModeGetPixelWidth(current)==CGDisplayModeGetPixelWidth(mode) &&
        CGDisplayModeGetPixelHeight(current)==CGDisplayModeGetPixelHeight(mode) &&
        fabs(CGDisplayModeGetRefreshRate(current)-CGDisplayModeGetRefreshRate(mode))<0.01;
    CGDisplayModeRelease(current);
    return same ? kCGErrorSuccess : kCGErrorNotImplemented;
}
static CGError configure_mode(CGDisplayConfigRef config,CGDirectDisplayID display,CGDisplayModeRef mode,CFDictionaryRef options) {
    (void)config;(void)display;(void)mode;(void)options;return kCGErrorNotImplemented;
}
/* Aliases reference the legacy ABI without invoking SDK-unavailable APIs. */
#define LEGACY(name) extern void original_##name(void) __asm__("_" #name)
LEGACY(CGCaptureAllDisplays);LEGACY(CGCaptureAllDisplaysWithOptions);
LEGACY(CGDisplayCapture);LEGACY(CGDisplayCaptureWithOptions);LEGACY(CGDisplayRelease);
LEGACY(CGReleaseAllDisplays);LEGACY(CGRestorePermanentDisplayConfiguration);
LEGACY(CGDisplaySetDisplayMode);LEGACY(CGConfigureDisplayWithDisplayMode);
#define REPLACE(replacement,name) { (const void *)(replacement),(const void *)original_##name }
__attribute__((used,section("__DATA,__interpose"))) static const struct {const void *replacement,*original;} bindings[]={
    REPLACE(PMBlockedCaptureAllDisplays,CGCaptureAllDisplays),REPLACE(capture_options,CGCaptureAllDisplaysWithOptions),
    REPLACE(capture_display,CGDisplayCapture),REPLACE(capture_display_options,CGDisplayCaptureWithOptions),
    REPLACE(release_all,CGReleaseAllDisplays),REPLACE(release_display,CGDisplayRelease),
    REPLACE(restore_modes,CGRestorePermanentDisplayConfiguration),REPLACE(set_mode,CGDisplaySetDisplayMode),
    REPLACE(configure_mode,CGConfigureDisplayWithDisplayMode)
};
