// Stock C1 controls, independent of DepthAI and the frame/render pipeline.
// Standard UVC only; all entity/interface numbers come from active descriptors.
#include "StockC1Control.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
namespace {
struct Terminal { uint8_t interface, entity; bool absolute, automatic; };
struct Processing { uint8_t interface, entity; bool temperature, automatic, backlight, saturation; };
static uint16_t le16(const uint8_t *p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
static std::vector<Terminal> parse(const uint8_t *bytes, size_t size) {
    std::vector<Terminal> result;
    bool control = false; uint8_t interface = 0;
    for(size_t offset = 0; offset + 2 <= size;) {
        const auto *p = bytes + offset; size_t length = p[0];
        if(length < 2 || length > size - offset) throw std::runtime_error("Malformed USB configuration descriptor");
        if(p[1] == 4 && length >= 9) { interface = p[2]; control = p[5] == 0x0e && p[6] == 1 && p[3] == 0; }
        if(control && p[1] == 0x24 && length >= 15 && p[2] == 2 && le16(p + 4) == 0x0201) {
            size_t n = p[14]; if(n > length - 15) throw std::runtime_error("Truncated camera-terminal controls");
            auto bit = [&](int index) { return size_t(index / 8) < n && (p[15 + index / 8] & (1 << (index % 8))); };
            result.push_back({interface, p[3], bool(bit(5)), bool(bit(17))});
        }
        offset += length;
    }
    return result;
}
static std::vector<Processing> parseProcessing(const uint8_t *bytes, size_t size) {
    std::vector<Processing> result;
    bool control = false; uint8_t interface = 0;
    for(size_t offset = 0; offset + 2 <= size;) {
        const auto *p = bytes + offset; const size_t length = p[0];
        if(length < 2 || length > size - offset) throw std::runtime_error("Malformed USB configuration descriptor");
        if(p[1] == 4 && length >= 9) { interface = p[2]; control = p[5] == 0x0e && p[6] == 1 && p[3] == 0; }
        if(control && p[1] == 0x24 && length >= 9 && p[2] == 5) {
            const size_t n = p[7]; if(n > length - 8) throw std::runtime_error("Truncated processing-unit controls");
            auto bit = [&](int index) { return size_t(index / 8) < n && (p[8 + index / 8] & (1 << (index % 8))); };
            result.push_back({interface, p[3], bool(bit(6)), bool(bit(12)), bool(bit(8)), bool(bit(3))});
        }
        offset += length;
    }
    return result;
}
static std::string property(io_service_t service, CFStringRef key) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if(!raw) return {};
    std::string result; char value[256]{};
    if(CFGetTypeID(raw) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)raw, value, sizeof value, kCFStringEncodingUTF8)) result = value;
    CFRelease(raw); return result;
}
static int number(io_service_t service, CFStringRef key) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int result = -1;
    if(raw) { if(CFGetTypeID(raw) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &result); CFRelease(raw); }
    return result;
}
static void check(IOReturn result, const char *operation) {
    if(result != kIOReturnSuccess) {
        char value[24]; snprintf(value, sizeof value, "0x%08x", unsigned(result));
        throw std::runtime_error(std::string(operation) + " failed: " + value + ". No seizure or reset will be attempted.");
    }
}
class Device {
    IOUSBDeviceInterface182 **usb = nullptr;
    bool opened = false;
public:
    explicit Device(const std::string &serial) {
        io_iterator_t iterator = 0;
        check(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator), "USB registry enumeration");
        io_service_t match = 0, service;
        while((service = IOIteratorNext(iterator))) {
            int product = number(service, CFSTR("idProduct"));
            if(number(service, CFSTR("idVendor")) == 0x03e7 && (product == 0xf63d || product == 0xf63b) &&
               property(service, CFSTR("USB Product Name")) == "Opal C1" && property(service, CFSTR("USB Serial Number")) == serial) {
                if(match) { IOObjectRelease(service); IOObjectRelease(match); IOObjectRelease(iterator); throw std::runtime_error("Ambiguous selected identity"); }
                match = service;
            } else IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
        if(!match) throw std::runtime_error("Selected stock Opal C1 not found");
        IOCFPlugInInterface **plugin = nullptr; SInt32 score = 0;
        IOReturn result = IOCreatePlugInInterfaceForService(match, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(match); check(result, "USB device user client");
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&usb);
        IODestroyPlugInInterface(plugin);
        if(query || !usb) throw std::runtime_error("USB device interface unavailable");
        // USBDeviceOpen is deliberately not USBDeviceOpenSeize. Failure is final.
        result = (*usb)->USBDeviceOpen(usb);
        if(result != kIOReturnSuccess) { (*usb)->Release(usb); usb = nullptr; check(result, "Non-seizing USB open (close camera apps first)"); }
        opened = true;
    }
    ~Device() { if(usb) { if(opened) (*usb)->USBDeviceClose(usb); (*usb)->Release(usb); } }
    Terminal terminal() {
        UInt8 count = 0, active = 0;
        check((*usb)->GetNumberOfConfigurations(usb, &count), "Read configuration count");
        check((*usb)->GetConfiguration(usb, &active), "Read active configuration");
        std::vector<Terminal> found;
        for(UInt8 i = 0; i < count; ++i) {
            IOUSBConfigurationDescriptorPtr descriptor = nullptr;
            check((*usb)->GetConfigurationDescriptorPtr(usb, i, &descriptor), "Read cached configuration descriptor");
            if(!descriptor || descriptor->bConfigurationValue != active) continue;
            const auto *bytes = reinterpret_cast<const uint8_t *>(descriptor);
            size_t size = le16(bytes + 2);
            if(size < 9 || size > 65535) throw std::runtime_error("Invalid configuration size");
            auto terminals = parse(bytes, size); found.insert(found.end(), terminals.begin(), terminals.end());
        }
        if(found.size() != 1) throw std::runtime_error("Expected one unambiguous active camera terminal; refusing guessed entity IDs");
        return found[0];
    }
    Processing processing() {
        UInt8 count = 0, active = 0;
        check((*usb)->GetNumberOfConfigurations(usb, &count), "Read configuration count");
        check((*usb)->GetConfiguration(usb, &active), "Read active configuration");
        std::vector<Processing> found;
        for(UInt8 i = 0; i < count; ++i) {
            IOUSBConfigurationDescriptorPtr descriptor = nullptr;
            check((*usb)->GetConfigurationDescriptorPtr(usb, i, &descriptor), "Read cached configuration descriptor");
            if(!descriptor || descriptor->bConfigurationValue != active) continue;
            const auto *bytes = reinterpret_cast<const uint8_t *>(descriptor);
            const size_t size = le16(bytes + 2);
            if(size < 9) throw std::runtime_error("Invalid configuration size");
            auto units = parseProcessing(bytes, size); found.insert(found.end(), units.begin(), units.end());
        }
        if(found.size() != 1) throw std::runtime_error("Expected one unambiguous processing unit");
        return found[0];
    }
    uint16_t request(Terminal t, uint8_t selector, uint8_t request, size_t length, uint16_t value = 0) {
        uint8_t bytes[2] = {uint8_t(value), uint8_t(value >> 8)};
        if(length != 1 && length != 2) throw std::runtime_error("Invalid UVC transfer length");
        IOUSBDevRequestTO transfer{};
        transfer.noDataTimeout = 700; transfer.completionTimeout = 1000;
        transfer.bmRequestType = request == 1 ? 0x21 : 0xa1;
        transfer.bRequest = request; transfer.wValue = uint16_t(selector) << 8;
        transfer.wIndex = uint16_t(t.entity) << 8 | t.interface; transfer.wLength = UInt16(length); transfer.pData = bytes;
        char operation[128];
        std::snprintf(operation, sizeof operation, "UVC request (entity %u, interface %u, selector 0x%02x, request 0x%02x, length %zu)", t.entity, t.interface, selector, request, length);
        check((*usb)->DeviceRequestTO(usb, &transfer), operation);
        if(transfer.wLenDone != length) throw std::runtime_error("UVC transfer returned unexpected length");
        return length == 1 ? bytes[0] : le16(bytes);
    }
};

void copyText(char *out, size_t capacity, const std::string &text) {
    if(!out || !capacity) return;
    auto count = std::min(capacity - 1, text.size());
    std::memcpy(out, text.data(), count); out[count] = 0;
}
}
struct StockC1Control {
    Device device;
    Terminal terminal;
    StockC1FocusState cached{};
    int32_t requestedWhiteBalance = 0;
    int32_t lastManualWhiteBalance = 0;
    explicit StockC1Control(const std::string &serial) : device(serial), terminal(device.terminal()) {
        if(!terminal.absolute || !terminal.automatic) throw std::runtime_error("C1 focus controls are not advertised");
        const auto absoluteInfo = device.request(terminal, 6, 0x86, 1);
        const auto autoInfo = device.request(terminal, 8, 0x86, 1);
        if((absoluteInfo & 3) != 3 || (absoluteInfo & 4) || !(autoInfo & 1))
            throw std::runtime_error("C1 focus controls are not available");
        cached.minimum = device.request(terminal, 6, 0x82, 2);
        cached.maximum = device.request(terminal, 6, 0x83, 2);
        cached.resolution = device.request(terminal, 6, 0x84, 2);
        if(cached.minimum >= cached.maximum || cached.maximum > 255)
            throw std::runtime_error("Unexpected C1 focus range");
        read();
    }
    void read() {
        cached.position = device.request(terminal, 6, 0x81, 2);
        cached.automatic = device.request(terminal, 8, 0x81, 1);
        if(cached.automatic > 1) throw std::runtime_error("Invalid autofocus readback");
    }
    Terminal whiteBalanceTerminal() {
        const auto unit = device.processing();
        if(!unit.temperature || !unit.automatic) throw std::runtime_error("C1 white balance controls are not advertised");
        return {unit.interface, unit.entity, true, true};
    }
    StockC1WhiteBalanceState readWhiteBalance() {
        const auto target = whiteBalanceTerminal();
        StockC1WhiteBalanceState value{};
        value.temperature_info = device.request(target, 10, 0x86, 1);
        value.automatic_info = device.request(target, 11, 0x86, 1);
        if(!(value.temperature_info & 1) || !(value.automatic_info & 1))
            throw std::runtime_error("C1 white balance controls are not readable");
        // Verified C1 quirk: manual GET_CUR stalls while automatic mode is on.
        // Read the mode first; never turn auto off merely to inspect metadata.
        value.automatic = device.request(target, 11, 0x81, 1);
        if(value.automatic > 1) throw std::runtime_error("Invalid C1 white balance mode");
        value.temperature_valid = !value.automatic;
        if(value.temperature_valid) lastManualWhiteBalance = device.request(target, 10, 0x81, 2);
        value.temperature = lastManualWhiteBalance;
        value.requested_temperature = requestedWhiteBalance;
        value.minimum = device.request(target, 10, 0x82, 2);
        value.maximum = device.request(target, 10, 0x83, 2);
        value.resolution = device.request(target, 10, 0x84, 2);
        if(value.minimum >= value.maximum) throw std::runtime_error("Unexpected C1 white balance range/state");
        return value;
    }
    void automaticWhiteBalance(Terminal target, bool enabled) {
        const auto info = device.request(target, 11, 0x86, 1);
        // Stock C1 f63d reports GET-only, but Composer writes this selector.
        // Verified with auto0 -> 4250K readback -> original5800K -> auto1.
        if(!(info & 1) || (info & 0x24)) throw std::runtime_error("C1 automatic white balance is unavailable");
        device.request(target, 11, 1, 1, enabled ? 1 : 0);
        if(device.request(target, 11, 0x81, 1) != int(enabled)) throw std::runtime_error("C1 white balance mode did not accept the change");
    }
    Terminal exposureTerminal() {
        const auto unit = device.processing();
        if(!unit.backlight) throw std::runtime_error("C1 exposure compensation is not advertised");
        return {unit.interface, unit.entity, true, false};
    }
    StockC1ExposureState readExposure() {
        const auto target = exposureTerminal();
        StockC1ExposureState state{};
        state.info = device.request(target, 1, 0x86, 1);
        if(!(state.info & 1) || (state.info & 0x20)) throw std::runtime_error("C1 exposure compensation is unreadable");
        state.minimum = device.request(target, 1, 0x82, 2);
        state.maximum = device.request(target, 1, 0x83, 2);
        state.resolution = device.request(target, 1, 0x84, 2);
        state.value = device.request(target, 1, 0x81, 2);
        if(state.minimum > state.maximum || state.value < state.minimum || state.value > state.maximum)
            throw std::runtime_error("Unexpected C1 exposure compensation range");
        state.composer_value = state.value > 9 ? 9 - state.value : state.value;
        return state;
    }
    Terminal saturationTerminal() {
        const auto unit = device.processing();
        if(!unit.saturation) throw std::runtime_error("C1 saturation is not advertised");
        return {unit.interface, unit.entity, true, false};
    }
    StockC1SaturationState readSaturation() {
        const auto target = saturationTerminal();
        StockC1SaturationState state{};
        state.info = device.request(target, 7, 0x86, 1);
        if(!(state.info & 1) || (state.info & 0x20)) throw std::runtime_error("C1 saturation is unreadable");
        state.minimum = device.request(target, 7, 0x82, 2);
        state.maximum = device.request(target, 7, 0x83, 2);
        state.resolution = device.request(target, 7, 0x84, 2);
        state.value = device.request(target, 7, 0x81, 2);
        if(state.minimum >= state.maximum || state.value < state.minimum || state.value > state.maximum)
            throw std::runtime_error("Unexpected C1 saturation range");
        state.composer_value = (state.value-state.minimum)*20/(state.maximum-state.minimum)-10;
        return state;
    }
    void automatic(bool enabled) {
        device.request(terminal, 8, 1, 1, enabled ? 1 : 0);
        cached.automatic = device.request(terminal, 8, 0x81, 1);
        if(cached.automatic != int(enabled)) throw std::runtime_error("C1 autofocus did not accept the change");
    }
};
extern "C" {
int32_t stock_c1_list(C1Device *devices, int32_t capacity, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    if(!devices || capacity < 1) { copyText(error, errorSize, "Invalid device list capacity"); return -1; }
    io_iterator_t iterator = 0;
    const auto result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator);
    if(result != KERN_SUCCESS) { copyText(error, errorSize, "Cannot read USB registry"); return -1; }
    int32_t count = 0; io_service_t service;
    while((service = IOIteratorNext(iterator))) {
        const int pid = number(service, CFSTR("idProduct"));
        const auto serial = property(service, CFSTR("USB Serial Number"));
        if(number(service, CFSTR("idVendor")) == 0x03e7 && (pid == 0xf63d || pid == 0xf63b) &&
           property(service, CFSTR("USB Product Name")) == "Opal C1" && !serial.empty() && serial.size() < sizeof(C1Device::identifier) && count < capacity) {
            auto &out = devices[count++]; out = C1Device{};
            copyText(out.identifier, sizeof out.identifier, serial); copyText(out.name, sizeof out.name, "Opal C1");
            out.product_id = uint16_t(pid);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator); return count;
}
StockC1Control *stock_c1_open(const char *serial, StockC1FocusState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!serial || !serial[0] || !state) throw std::runtime_error("Exact C1 serial and output state required");
        std::unique_ptr<StockC1Control> control(new StockC1Control(serial));
        *state = control->cached; return control.release();
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return nullptr; }
}
int32_t stock_c1_read_focus(StockC1Control *control, StockC1FocusState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        control->read(); *state = control->cached; return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_focus(StockC1Control *control, int32_t position, StockC1FocusState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        if(position < control->cached.minimum || position > control->cached.maximum) throw std::runtime_error("Focus is outside C1 range");
        // Do not quantize to GET_RES: firmware reports step3 but its own current
        // value (142) and Composer's successful values are not multiples of3.
        const bool oldAuto = control->cached.automatic != 0;
        // Composer sends AF-off only when its cached state is on. Avoid two
        // extra USB transfers per slider update after manual mode is confirmed.
        if(oldAuto) control->automatic(false);
        try {
            control->device.request(control->terminal, 6, 1, 2, uint16_t(position));
            control->read(); *state = control->cached; return 1;
        } catch(...) {
            // An unsuccessful slider change must not silently leave auto off.
            if(oldAuto) { try { control->automatic(true); } catch(...) {} }
            throw;
        }
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_auto_focus(StockC1Control *control, int32_t enabled, StockC1FocusState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        if(enabled != 0 && enabled != 1) throw std::runtime_error("Autofocus must be on or off");
        control->automatic(enabled != 0); control->read(); *state = control->cached; return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_read_white_balance(StockC1Control *control, StockC1WhiteBalanceState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        *state = control->readWhiteBalance(); return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_white_balance(StockC1Control *control, int32_t kelvin, StockC1WhiteBalanceState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        const auto old = control->readWhiteBalance();
        const auto target = control->whiteBalanceTerminal();
        const auto info = control->device.request(target, 10, 0x86, 1);
        if((info & 3) != 3) throw std::runtime_error("C1 white balance temperature is not writable");
        try {
            if(old.automatic) control->automaticWhiteBalance(target, false);
            if(control->device.request(target, 10, 0x86, 1) & 0x24) throw std::runtime_error("C1 manual white balance remains disabled");
            // Original Composer clamps integer Kelvin directly to device bounds.
            const auto value = std::max(old.minimum, std::min(old.maximum, kelvin));
            control->device.request(target, 10, 1, 2, uint16_t(value));
            *state = control->readWhiteBalance();
            // Firmware may quantize to GET_RES. Publish actual bounded Kelvin
            // rather than treating normal quantization as a failed adjustment.
            if(!state->temperature_valid || state->temperature < state->minimum || state->temperature > state->maximum)
                throw std::runtime_error("C1 white balance returned an invalid temperature");
            control->requestedWhiteBalance = kelvin;
            state->requested_temperature = kelvin;
            return 1;
        } catch(const std::exception &failure) {
            std::string message = failure.what();
            if(old.automatic) {
                try { control->automaticWhiteBalance(target, true); }
                catch(const std::exception &restore) { message += std::string(" Auto white balance restoration failed: ") + restore.what(); }
            }
            throw std::runtime_error(message);
        }
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_auto_white_balance(StockC1Control *control, int32_t enabled, StockC1WhiteBalanceState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        if(enabled != 0 && enabled != 1) throw std::runtime_error("White balance mode must be on or off");
        control->automaticWhiteBalance(control->whiteBalanceTerminal(), enabled != 0);
        *state = control->readWhiteBalance(); return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_read_exposure(StockC1Control *control, StockC1ExposureState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        *state = control->readExposure(); return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_exposure(StockC1Control *control, int32_t composerValue, StockC1ExposureState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        const auto previous = control->readExposure();
        if((previous.info & 3) != 3 || (previous.info & 0x24)) throw std::runtime_error("C1 exposure compensation is not writable");
        // Native Composer mapping, verified on stock C1: -3 -> register12,
        // readback12; restored register0 with readback0 while capture stayed live.
        const int64_t mapped = composerValue < 0 ? -int64_t(composerValue) + 9 : composerValue;
        if(mapped < previous.minimum || mapped > previous.maximum) throw std::runtime_error("Exposure compensation is outside C1 range");
        control->device.request(control->exposureTerminal(), 1, 1, 2, uint16_t(mapped));
        *state = control->readExposure();
        if(state->value != mapped) throw std::runtime_error("C1 exposure compensation did not accept the change");
        state->composer_value = composerValue;
        return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_read_saturation(StockC1Control *control, StockC1SaturationState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        *state = control->readSaturation(); return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
int32_t stock_c1_set_saturation(StockC1Control *control, int32_t composerValue, StockC1SaturationState *state, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    try {
        if(!control || !state) throw std::runtime_error("C1 control is closed");
        if(composerValue < -10 || composerValue > 10) throw std::runtime_error("Composer saturation is outside -10...10");
        const auto previous = control->readSaturation();
        if((previous.info & 3) != 3 || (previous.info & 0x24)) throw std::runtime_error("C1 saturation is not writable");
        // UVCCameraDevice mapValue0x100007444 uses integer division, not a
        // software RGB multiplier. Main truncates the stored value before send.
        const int32_t mapped = (previous.maximum-previous.minimum)*(composerValue+10)/20+previous.minimum;
        control->device.request(control->saturationTerminal(), 7, 1, 2, uint16_t(mapped));
        *state = control->readSaturation();
        if(state->value != mapped) throw std::runtime_error("C1 saturation did not accept the change");
        state->composer_value = composerValue;
        return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}
void stock_c1_close(StockC1Control *control) { delete control; }
}
