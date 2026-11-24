// Native memory-safety regression harness. No EFI firmware, VM, display, network or guest input is executed.
#include <assert.h>
#include <stdlib.h>
#undef NULL // EDK II and the native C library each define their own equivalent null constant.
#include "FramebufferBoot.c"

static UINTN Pushes, Variables;
static UINT8 DevicePath[4096];
static EFI_STATUS EFIAPI Handle(EFI_HANDLE handle, EFI_GUID *guid, VOID **interface) {
    (void)handle; (void)guid; *interface = DevicePath; return EFI_SUCCESS;
}
static EFI_STATUS EFIAPI Allocate(EFI_MEMORY_TYPE type, UINTN count, VOID **bytes) {
    (void)type; *bytes = malloc(count); return *bytes ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
}
static EFI_STATUS EFIAPI Release(VOID *bytes) { free(bytes); return EFI_SUCCESS; }
static EFI_STATUS EFIAPI Variable(CHAR16 *name, EFI_GUID *guid, UINT32 attributes, UINTN size, VOID *value) {
    (void)guid; assert(attributes == 7);
    const UINT8 *bytes = value;
    if (!Variables) {
        assert(name[4] == L'7' && size > 40 && bytes[0] == 1);
        assert(bytes[40] == MEDIA_DEVICE_PATH && bytes[41] == MEDIA_FILEPATH_DP);
    } else { assert(name[4] == L'N' && size == 2 && bytes[0] == 0xf0 && bytes[1] == 0x7f); }
    ++Variables; return EFI_SUCCESS;
}
static EFI_STATUS EFIAPI FakeBlt(EFI_GRAPHICS_OUTPUT_PROTOCOL *self, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *buffer,
    EFI_GRAPHICS_OUTPUT_BLT_OPERATION operation, UINTN sx, UINTN sy, UINTN dx, UINTN dy,
    UINTN width, UINTN height, UINTN delta) {
    (void)self; (void)buffer; (void)sx; (void)sy; (void)dx; (void)dy; (void)width; (void)height; (void)delta;
    assert(operation == EfiBltBufferToVideo); ++Pushes; return EFI_SUCCESS;
}
static VOID ResetPixels(VOID) {
    for (UINTN i = 0; i < Width * Height; ++i) Pixels[i] = (UINT32)i;
}
int main(void) {
    Width = 8; Height = 6; PixelBytes = Width * Height * 4;
    Pixels = calloc(1, PixelBytes); Previous = calloc(1, PixelBytes);
    assert(Pixels && Previous);
    EFI_GRAPHICS_OUTPUT_PROTOCOL hardware = {0}; hardware.Blt = FakeBlt; Hardware = &hardware;
    UINT32 color = 0x11223344, buffer[48] = {0};
    assert(Blit(NULL, (VOID *)&color, EfiBltVideoFill, 0, 0, 0, 0, 8, 6, 0) == EFI_SUCCESS);
    for (UINTN i = 0; i < 48; ++i) assert(Pixels[i] == color);
    ResetPixels();
    assert(Blit(NULL, NULL, EfiBltVideoToVideo, 0, 0, 1, 0, 7, 6, 0) == EFI_SUCCESS);
    for (UINTN row = 0; row < 6; ++row) for (UINTN x = 1; x < 8; ++x) assert(Pixels[row*8+x] == row*8+x-1);
    ResetPixels();
    assert(Blit(NULL, NULL, EfiBltVideoToVideo, 0, 0, 0, 1, 8, 5, 0) == EFI_SUCCESS);
    for (UINTN row = 1; row < 6; ++row) for (UINTN x = 0; x < 8; ++x) assert(Pixels[row*8+x] == (row-1)*8+x);
    ResetPixels();
    assert(Blit(NULL, (VOID *)buffer, EfiBltVideoToBltBuffer, 0, 0, 0, 0, 8, 6, 0) == EFI_SUCCESS);
    for (UINTN i = 0; i < 48; ++i) assert(buffer[i] == i);
    memset(Pixels, 0, PixelBytes);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, 0, 0, 0, 8, 6, 0) == EFI_SUCCESS);
    for (UINTN i = 0; i < 48; ++i) assert(Pixels[i] == i);
    union { UINT32 alignment; UINT8 bytes[193]; } unaligned;
    memcpy(unaligned.bytes + 1, buffer, sizeof(buffer));
    assert(Blit(NULL, (VOID *)(unaligned.bytes + 1), EfiBltBufferToVideo, 0, 0, 0, 0, 8, 6, 0) == EFI_SUCCESS);
    assert(Blit(NULL, (VOID *)(unaligned.bytes + 1), EfiBltVideoToBltBuffer, 0, 0, 0, 0, 8, 6, 0) == EFI_SUCCESS);
    for (UINTN i = 0; i < sizeof(buffer); ++i) assert(unaligned.bytes[i+1] == ((UINT8 *)buffer)[i]);
    assert(Blit(NULL, NULL, EfiBltVideoFill, 0, 0, 0, 0, 1, 1, 0) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, (EFI_GRAPHICS_OUTPUT_BLT_OPERATION)-1, 0, 0, 0, 0, 1, 1, 0) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, 0, 8, 0, 1, 1, 0) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, 0, 0, 0, 9, 1, 0) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, 0, 0, 0, 1, 1, 3) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 8, 0, 0, 0, 1, 1, 32) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, ~(UINTN)0, 0, 0, 1, 1, 4) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltVideoToBltBuffer, 0, 0, 0, ~(UINTN)0, 1, 1, 4) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltBufferToVideo, 0, ~(UINTN)0 / 4 - 1, 0, 0, 1, 1, 4) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, (VOID *)buffer, EfiBltVideoToBltBuffer, 0, 0, 0, ~(UINTN)0 / 4 - 1, 1, 1, 4) == EFI_INVALID_PARAMETER);
    assert(Blit(NULL, NULL, EfiBltVideoToVideo, ~(UINTN)0, 0, 0, 0, 1, 1, 0) == EFI_INVALID_PARAMETER);
    DisplayActive = TRUE; Tick(NULL, NULL); assert(Pushes > 0);
    UINTN before = Pushes; Leaving(NULL, NULL); Tick(NULL, NULL); assert(Pushes == before);
    assert(Set(NULL, 1) == EFI_UNSUPPORTED);
    assert(Set(NULL, 0) == EFI_SUCCESS);
    for (UINTN i = 0; i < 48; ++i) assert(Pixels[i] == 0);
    assert(Query(NULL, 1, NULL, NULL) == EFI_INVALID_PARAMETER);
    free(Pixels); free(Previous);
    EFI_BOOT_SERVICES services = {0}; Services = &services;
    services.HandleProtocol = Handle; services.AllocatePool = Allocate; services.FreePool = Release;
    DevicePath[0] = 1; DevicePath[3] = 16; // A 4096-byte non-end node must not read the next header outside the cap.
    UINTN size = 0;
    assert(AppendFile(NULL, L"\\EFI\\BOOT\\BOOTAA64.EFI", &size) == NULL);
    memset(DevicePath, 0, sizeof(DevicePath));
    DevicePath[0] = END_DEVICE_PATH_TYPE; DevicePath[1] = END_ENTIRE_DEVICE_PATH_SUBTYPE; DevicePath[2] = 4;
    EFI_RUNTIME_SERVICES runtime = {0}; runtime.SetVariable = Variable;
    EFI_SYSTEM_TABLE system = {0}; system.RuntimeServices = &runtime; System = &system;
    assert(NextBoot(NULL) == EFI_SUCCESS && Variables == 2);
    return 0;
}
