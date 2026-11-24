// VMRunner's framebuffer bootstrap. Independent implementation using standard UEFI interfaces.
// Never edits Windows, generates input or alters Setup checks. See README.md and ADR-0060.
#include <Uefi.h>
#include <Protocol/GraphicsOutput.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/DevicePath.h>

static EFI_GUID GraphicsGuid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
static EFI_GUID ImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
static EFI_GUID PathGuid = EFI_DEVICE_PATH_PROTOCOL_GUID;
static EFI_GUID FilesystemGuid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
static EFI_GUID RecordGuid = {0xd1b4e28a, 0x0641, 0x44dc, {0x8a,0xee,0x65,0x43,0x12,0x99,0x30,0x26}};
static EFI_BOOT_SERVICES *Services;
static EFI_SYSTEM_TABLE *System;
static EFI_GRAPHICS_OUTPUT_PROTOCOL *Hardware;
static UINT32 *Pixels, *Previous;
static UINTN PixelBytes;
static UINT32 Width, Height;
static BOOLEAN DisplayActive;
static struct {
    UINT8 Token[16];
    UINT64 Address;
    UINT32 Width, Height, Stride, Bytes;
    UINT64 Status, Generation;
} Record;
_Static_assert(sizeof(Record) == 56, "host framebuffer record ABI");

typedef struct {
    EFI_GRAPHICS_OUTPUT_PROTOCOL Interface;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE Mode;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION Information;
} OUTPUT;
static OUTPUT Outputs[8];

void *memcpy(void *destination, const void *source, UINTN count) {
    UINT8 *out = destination; const UINT8 *in = source;
    for (UINTN i = 0; i < count; ++i) out[i] = in[i];
    return destination;
}
void *memset(void *destination, int value, UINTN count) {
    UINT8 *out = destination;
    for (UINTN i = 0; i < count; ++i) out[i] = (UINT8)value;
    return destination;
}
static VOID CopyPixels(VOID *destination, const VOID *source, UINTN pixels) {
    UINT8 *out = destination; const UINT8 *in = source; UINTN count = pixels * sizeof(UINT32);
    // EFI BLT pixels have byte alignment; do not dereference a potentially unaligned UINT32 buffer.
    if ((UINTN)out > (UINTN)in && (UINTN)out - (UINTN)in < count) {
        while (count) { --count; out[count] = in[count]; }
    } else for (UINTN i = 0; i < count; ++i) out[i] = in[i];
}
static BOOLEAN Rectangle(UINTN x, UINTN y, UINTN width, UINTN height) {
    return x <= Width && y <= Height && width <= Width - x && height <= Height - y;
}
static VOID Push(UINTN first, UINTN rows) {
    if (DisplayActive && rows) Hardware->Blt(Hardware, (VOID *)Pixels, EfiBltBufferToVideo,
        0, first, 0, first, Width, rows, (UINTN)Width * 4);
}
static VOID EFIAPI Tick(EFI_EVENT event, VOID *context) {
    (void)event; (void)context;
    if (!DisplayActive) return;
    UINTN start = Height;
    for (UINTN row = 0; row < Height; ++row) {
        UINTN offset = row * Width; BOOLEAN changed = FALSE;
        for (UINTN x = 0; x < Width; ++x) if (Pixels[offset+x] != Previous[offset+x]) { changed = TRUE; break; }
        if (changed) {
            CopyPixels(Previous + offset, Pixels + offset, Width);
            if (start == Height) start = row;
        } else if (start != Height) { Push(start, row - start); start = Height; }
    }
    if (start != Height) Push(start, Height - start);
}
static VOID EFIAPI Leaving(EFI_EVENT event, VOID *context) {
    (void)event; (void)context; DisplayActive = FALSE;
}
static EFI_STATUS EFIAPI Query(EFI_GRAPHICS_OUTPUT_PROTOCOL *self, UINT32 mode, UINTN *size,
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **information) {
    if (mode || !size || !information) return EFI_INVALID_PARAMETER;
    EFI_STATUS status = Services->AllocatePool(EfiBootServicesData, sizeof(**information), (VOID **)information);
    if (EFI_ERROR(status)) return status;
    memcpy(*information, self->Mode->Info, sizeof(**information)); *size = sizeof(**information);
    return EFI_SUCCESS;
}
static EFI_STATUS EFIAPI Set(EFI_GRAPHICS_OUTPUT_PROTOCOL *self, UINT32 mode) {
    (void)self; if (mode) return EFI_UNSUPPORTED;
    memset(Pixels, 0, PixelBytes); memset(Previous, 0, PixelBytes); Push(0, Height);
    return EFI_SUCCESS;
}
static EFI_STATUS EFIAPI Blit(EFI_GRAPHICS_OUTPUT_PROTOCOL *self, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *buffer,
    EFI_GRAPHICS_OUTPUT_BLT_OPERATION operation, UINTN sx, UINTN sy, UINTN dx, UINTN dy,
    UINTN width, UINTN height, UINTN delta) {
    (void)self;
    if (!width || !height || width > Width || height > Height || (UINTN)operation >= EfiGraphicsOutputBltOperationMax)
        return EFI_INVALID_PARAMETER;
    if (operation != EfiBltVideoToVideo && !buffer) return EFI_INVALID_PARAMETER;
    if (operation != EfiBltVideoToBltBuffer && !Rectangle(dx, dy, width, height)) return EFI_INVALID_PARAMETER;
    if ((operation == EfiBltVideoToBltBuffer || operation == EfiBltVideoToVideo) && !Rectangle(sx, sy, width, height))
        return EFI_INVALID_PARAMETER;
    if (!delta) delta = width * 4;
    if (delta % 4) return EFI_INVALID_PARAMETER;
    UINTN stride = delta / 4, maximum = (~(UINTN)0 / delta);
    if ((operation == EfiBltBufferToVideo || operation == EfiBltVideoToBltBuffer) && height > maximum)
        return EFI_INVALID_PARAMETER;
    if (operation == EfiBltBufferToVideo && (sx > stride || width > stride - sx || sy > maximum - height))
        return EFI_INVALID_PARAMETER;
    if (operation == EfiBltVideoToBltBuffer && (dx > stride || width > stride - dx || dy > maximum - height))
        return EFI_INVALID_PARAMETER;
    if (operation == EfiBltBufferToVideo && (UINTN)buffer > ~(UINTN)0 - ((sy + height - 1) * delta + (sx + width) * 4))
        return EFI_INVALID_PARAMETER;
    if (operation == EfiBltVideoToBltBuffer && (UINTN)buffer > ~(UINTN)0 - ((dy + height - 1) * delta + (dx + width) * 4))
        return EFI_INVALID_PARAMETER;
    for (UINTN index = 0; index < height; ++index) {
        UINTN row = operation == EfiBltVideoToVideo && dy > sy ? height - 1 - index : index;
        UINT32 *target = operation == EfiBltVideoToBltBuffer ? NULL : Pixels + (dy + row) * Width + dx;
        const UINT32 *source = (operation == EfiBltVideoToBltBuffer || operation == EfiBltVideoToVideo)
            ? Pixels + (sy + row) * Width + sx : NULL;
        if (operation == EfiBltVideoFill) {
            UINT32 color; memcpy(&color, buffer, 4);
            for (UINTN x = 0; x < width; ++x) target[x] = color;
        } else if (operation == EfiBltBufferToVideo) CopyPixels(target, (UINT8 *)buffer + (sy + row) * delta + sx * 4, width);
        else if (operation == EfiBltVideoToBltBuffer) CopyPixels((UINT8 *)buffer + (dy + row) * delta + dx * 4, source, width);
        else CopyPixels(target, source, width);
    }
    if (operation != EfiBltVideoToBltBuffer) Push(dy, height);
    return EFI_SUCCESS;
}
static EFI_DEVICE_PATH_PROTOCOL *AppendFile(EFI_HANDLE volume, const CHAR16 *name, UINTN *total) {
    EFI_DEVICE_PATH_PROTOCOL *path;
    if (EFI_ERROR(Services->HandleProtocol(volume, &PathGuid, (VOID **)&path))) return NULL;
    UINTN base = 0;
    for (UINTN nodes = 0; nodes < 64; ++nodes) {
        if (base > 4096 - sizeof(EFI_DEVICE_PATH_PROTOCOL)) return NULL;
        EFI_DEVICE_PATH_PROTOCOL *node = (VOID *)((UINT8 *)path + base);
        UINTN size = node->Length[0] | ((UINTN)node->Length[1] << 8);
        if (size < sizeof(*node) || size > 4096 - base) return NULL;
        if (node->Type == END_DEVICE_PATH_TYPE) break;
        base += size; if (nodes == 63) return NULL;
    }
    UINTN chars = 0; while (chars < 255 && name[chars]) ++chars;
    if (chars == 255) return NULL;
    UINTN fileSize = 4 + (chars + 1) * 2;
    UINT8 *bytes; *total = base + fileSize + 4;
    if (EFI_ERROR(Services->AllocatePool(EfiBootServicesData, *total, (VOID **)&bytes))) return NULL;
    memcpy(bytes, path, base);
    EFI_DEVICE_PATH_PROTOCOL *file = (VOID *)(bytes + base);
    file->Type = MEDIA_DEVICE_PATH; file->SubType = MEDIA_FILEPATH_DP;
    file->Length[0] = (UINT8)fileSize; file->Length[1] = (UINT8)(fileSize >> 8);
    memcpy(file + 1, name, (chars + 1) * 2);
    EFI_DEVICE_PATH_PROTOCOL *end = (VOID *)(bytes + base + fileSize);
    end->Type = END_DEVICE_PATH_TYPE; end->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
    end->Length[0] = 4; end->Length[1] = 0;
    return (VOID *)bytes;
}
static EFI_STATUS NextBoot(EFI_HANDLE volume) {
    // Keep the framebuffer prerequisite on ordinary guest reboots even when Windows updates BootOrder.
    // These are our VM's firmware variables, not Windows files or requirement checks.
    EFI_GUID global = {0x8be4df61,0x93ca,0x11d2,{0xaa,0x0d,0x00,0xe0,0x98,0x03,0x2b,0x8c}};
    UINTN size; EFI_DEVICE_PATH_PROTOCOL *path = AppendFile(volume, L"\\EFI\\BOOT\\BOOTAA64.EFI", &size);
    if (!path || size > 8192) return EFI_UNSUPPORTED;
    CHAR16 description[] = L"VMRunner Windows";
    UINTN length = 6 + sizeof(description) + size; VOID *option;
    EFI_STATUS status = Services->AllocatePool(EfiBootServicesData, length, &option);
    if (EFI_ERROR(status)) { Services->FreePool(path); return status; }
    UINT32 active = 1; UINT16 pathLength = (UINT16)size, index = 0x7ff0;
    memcpy(option, &active, 4); memcpy((UINT8 *)option + 4, &pathLength, 2);
    memcpy((UINT8 *)option + 6, description, sizeof(description));
    memcpy((UINT8 *)option + 6 + sizeof(description), path, size);
    UINT32 attributes = EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
    status = System->RuntimeServices->SetVariable(L"Boot7FF0", &global, attributes, length, option);
    Services->FreePool(option); Services->FreePool(path);
    if (EFI_ERROR(status)) return status;
    return System->RuntimeServices->SetVariable(L"BootNext", &global, attributes, sizeof(index), &index);
}
static EFI_STATUS Prepare(EFI_HANDLE image) {
    EFI_LOADED_IMAGE_PROTOCOL *loaded;
    EFI_STATUS status = Services->HandleProtocol(image, &ImageGuid, (VOID **)&loaded);
    if (EFI_ERROR(status)) return status;
    EFI_HANDLE ownVolume = loaded->DeviceHandle;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *filesystem; EFI_FILE_PROTOCOL *root, *token;
    status = Services->HandleProtocol(ownVolume, &FilesystemGuid, (VOID **)&filesystem);
    if (EFI_ERROR(status)) return status;
    status = filesystem->OpenVolume(filesystem, &root); if (EFI_ERROR(status)) return status;
    status = root->Open(root, &token, L"\\VMRBOOT.ID", EFI_FILE_MODE_READ, 0); root->Close(root);
    if (EFI_ERROR(status)) return status;
    UINTN tokenSize = sizeof(Record.Token); status = token->Read(token, &tokenSize, Record.Token); token->Close(token);
    if (EFI_ERROR(status) || tokenSize != sizeof(Record.Token)) return EFI_SECURITY_VIOLATION;
    UINT64 generation = 0; UINTN generationSize = sizeof(generation);
    status = System->RuntimeServices->GetVariable(L"VMRBoot-gen", &RecordGuid, NULL, &generationSize, &generation);
    if (EFI_ERROR(status) || generationSize != sizeof(generation)) generation = 0;
    Record.Generation = generation == ~(UINT64)0 ? 1 : generation + 1;
    status = System->RuntimeServices->SetVariable(L"VMRBoot-gen", &RecordGuid,
        EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS, sizeof(Record.Generation), &Record.Generation);
    if (EFI_ERROR(status)) return status;
    status = NextBoot(ownVolume); if (EFI_ERROR(status)) return status;
    EFI_HANDLE *handles = NULL; UINTN count = 0;
    status = Services->LocateHandleBuffer(ByProtocol, &GraphicsGuid, NULL, &count, &handles);
    if (EFI_ERROR(status) || !count || count > 8) return EFI_UNSUPPORTED;
    for (UINTN i = 0; i < count; ++i) {
        EFI_GRAPHICS_OUTPUT_PROTOCOL *candidate; VOID *path;
        if (!EFI_ERROR(Services->HandleProtocol(handles[i], &GraphicsGuid, (VOID **)&candidate)) &&
            !EFI_ERROR(Services->HandleProtocol(handles[i], &PathGuid, &path))) { Hardware = candidate; break; }
    }
    if (!Hardware || !Hardware->Mode || !Hardware->Mode->Info) return EFI_UNSUPPORTED;
    Width = Hardware->Mode->Info->HorizontalResolution; Height = Hardware->Mode->Info->VerticalResolution;
    if (Width != 1920 || Height != 1200) return EFI_UNSUPPORTED;
    PixelBytes = (UINTN)Width * Height * 4;
    EFI_PHYSICAL_ADDRESS address = 0;
    status = Services->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, EFI_SIZE_TO_PAGES(PixelBytes), &address);
    if (EFI_ERROR(status)) return status;
    Pixels = (VOID *)(UINTN)address;
    status = Services->AllocatePool(EfiBootServicesData, PixelBytes, (VOID **)&Previous);
    if (EFI_ERROR(status)) return status;
    memset(Pixels, 0, PixelBytes); memset(Previous, 0, PixelBytes);
    for (UINTN i = 0; i < count; ++i) {
        EFI_GRAPHICS_OUTPUT_PROTOCOL *original;
        if (EFI_ERROR(Services->HandleProtocol(handles[i], &GraphicsGuid, (VOID **)&original))) return EFI_UNSUPPORTED;
        OUTPUT *output = &Outputs[i]; output->Information = *Hardware->Mode->Info;
        output->Information.PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
        memset(&output->Information.PixelInformation, 0, sizeof(output->Information.PixelInformation));
        output->Information.PixelsPerScanLine = Width;
        output->Mode.MaxMode = 1; output->Mode.Info = &output->Information;
        output->Mode.SizeOfInfo = sizeof(output->Information);
        output->Mode.FrameBufferBase = address; output->Mode.FrameBufferSize = PixelBytes;
        output->Interface.QueryMode = Query; output->Interface.SetMode = Set;
        output->Interface.Blt = Blit; output->Interface.Mode = &output->Mode;
        status = Services->ReinstallProtocolInterface(handles[i], &GraphicsGuid, original, &output->Interface);
        if (EFI_ERROR(status)) return status;
    }
    Services->FreePool(handles);
    Record.Address = address; Record.Width = Width; Record.Height = Height;
    Record.Stride = Width * 4; Record.Bytes = (UINT32)PixelBytes;
    status = System->RuntimeServices->SetVariable(L"VMRFrame-v1", &RecordGuid,
        EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS, sizeof(Record), &Record);
    if (EFI_ERROR(status)) return status;
    EFI_EVENT timer, exiting; DisplayActive = TRUE;
    status = Services->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, Tick, NULL, &timer);
    if (EFI_ERROR(status)) return status;
    status = Services->CreateEvent(EVT_SIGNAL_EXIT_BOOT_SERVICES, TPL_NOTIFY, Leaving, NULL, &exiting);
    if (EFI_ERROR(status)) return status;
    status = Services->SetTimer(timer, TimerPeriodic, 1000000); if (EFI_ERROR(status)) return status;
    EFI_HANDLE *volumes = NULL; count = 0;
    status = Services->LocateHandleBuffer(ByProtocol, &FilesystemGuid, NULL, &count, &volumes);
    if (EFI_ERROR(status) || count > 64) return EFI_NOT_FOUND;
    // Installed boot manager first, then the unmodified installer's removable-media entry.
    const CHAR16 *candidates[] = {L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi", L"\\EFI\\BOOT\\BOOTAA64.EFI"};
    for (UINTN path = 0; path < 2; ++path) for (UINTN i = 0; i < count; ++i) {
        if (volumes[i] == ownVolume) continue;
        for (UINTN attempt = 0; attempt < 90; ++attempt) {
            UINTN size; EFI_DEVICE_PATH_PROTOCOL *file = AppendFile(volumes[i], candidates[path], &size);
            if (!file) break;
            EFI_HANDLE next; status = Services->LoadImage(FALSE, image, file, NULL, 0, &next); Services->FreePool(file);
            if (EFI_ERROR(status)) break;
            status = Services->StartImage(next, NULL, NULL); Services->UnloadImage(next);
            if (status != EFI_TIMEOUT) { Services->FreePool(volumes); return status ? status : EFI_ABORTED; }
            Services->Stall(2000000); // Media may ask the owner to press a key. Never synthesize one.
        }
    }
    Services->FreePool(volumes); return EFI_NOT_FOUND;
}
EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system) {
    System = system; Services = system->BootServices;
    Record.Status = Prepare(image);
    System->RuntimeServices->SetVariable(L"VMRFrame-v1", &RecordGuid,
        EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS, sizeof(Record), &Record);
    // Never return to firmware with callbacks/protocols pointing into this image, or fall through to an unsafe stock boot.
    // The host reads Status and stops the VM with an actionable error (or times out if publishing failed).
    for (;;) Services->Stall(1000000);
}
