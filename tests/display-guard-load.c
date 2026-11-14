#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>
extern CGError fixture_capture(void) __asm__("_CGCaptureAllDisplays");
extern CGError fixture_capture_options(uint32_t) __asm__("_CGCaptureAllDisplaysWithOptions");
extern CGError fixture_display(CGDirectDisplayID) __asm__("_CGDisplayCapture");
extern CGError fixture_display_options(CGDirectDisplayID,uint32_t) __asm__("_CGDisplayCaptureWithOptions");
extern CGError fixture_release(void) __asm__("_CGReleaseAllDisplays");
extern CGError fixture_display_release(CGDirectDisplayID) __asm__("_CGDisplayRelease");
extern void fixture_restore(void) __asm__("_CGRestorePermanentDisplayConfiguration");
static void bound_to_guard(const void *address) {
    Dl_info image={0};assert(dladdr(address,&image) && image.dli_fname && strstr(image.dli_fname,"libPlaymeltDisplayGuard.dylib"));
}
int main(void) {
    unsigned (*version)(void)=dlsym(RTLD_DEFAULT,"PMDisplayGuardVersion");
    CGError (*blocked)(void)=dlsym(RTLD_DEFAULT,"PMBlockedCaptureAllDisplays");
    assert(version && version()==1 && blocked);
    /* Never invoke a real capture API: prove this import is the guard first. */
    if ((void*)&fixture_capture!=(void*)blocked) {fputs("Capture binding was not interposed; no capture attempted\n",stderr);return 1;}
    const void *bindings[]={&fixture_capture,&fixture_capture_options,&fixture_display,&fixture_display_options,&fixture_release,&fixture_display_release,&fixture_restore,&CGDisplaySetDisplayMode,&CGConfigureDisplayWithDisplayMode};
    for(unsigned i=0;i<sizeof(bindings)/sizeof(bindings[0]);++i)bound_to_guard(bindings[i]);
    assert(fixture_capture()==kCGErrorNotImplemented);
    assert(fixture_capture_options(0)==kCGErrorNotImplemented);
    assert(fixture_display(CGMainDisplayID())==kCGErrorNotImplemented);
    assert(fixture_display_options(CGMainDisplayID(),0)==kCGErrorNotImplemented);
    CGDisplayModeRef before=CGDisplayCopyDisplayMode(CGMainDisplayID());assert(before);
    assert(CGDisplaySetDisplayMode(CGMainDisplayID(),before,NULL)==kCGErrorSuccess);
    assert(CGConfigureDisplayWithDisplayMode(NULL,CGMainDisplayID(),before,NULL)==kCGErrorNotImplemented);
    assert(fixture_release()==kCGErrorSuccess && fixture_display_release(CGMainDisplayID())==kCGErrorSuccess);fixture_restore();
    CGDisplayModeRef after=CGDisplayCopyDisplayMode(CGMainDisplayID());assert(after);
    assert(CGDisplayModeGetWidth(before)==CGDisplayModeGetWidth(after) && CGDisplayModeGetHeight(before)==CGDisplayModeGetHeight(after) && CGDisplayModeGetRefreshRate(before)==CGDisplayModeGetRefreshRate(after));
    CGDisplayModeRelease(before);CGDisplayModeRelease(after);
    puts("Display guard loaded through the launcher shell; actual capture binding denied; no display mutation");return 0;
}
