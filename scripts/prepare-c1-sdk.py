"""Small, auditable compatibility modifications for pinned MIT DepthAI v2.30.0.

No device access. Idempotent. Reject unexpected source rather than broad edits.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def edit(relative, before, after, expected=1):
    path = root / relative
    text = path.read_text()
    if after in text:
        return
    if text.count(before) != expected:
        raise SystemExit(f"Unexpected SDK source in {relative}; refusing patch")
    path.write_text(text.replace(before, after))

# Disable the network transport immediately after SDK initialization, including
# internal reconnect discovery. The C1 is USB only.
edit('src/utility/Initialization.cpp', '#include "XLink/XLinkLog.h"',
     '#include "XLink/XLinkLog.h"\nvoid xlinkSetProtocolInitialized(XLinkProtocol_t, int);')
edit('src/utility/Initialization.cpp',
     '        // Check that USB protocol is available, IFF libusb is enabled',
     '        // C1_BACKEND_USB_ONLY: never discover network cameras.\n'
     '        xlinkSetProtocolInitialized(X_LINK_TCP_IP, 0);\n\n'
     '        // Check that USB protocol is available, IFF libusb is enabled')

# First-generation C1 bootloaders report 0.0.0. Only two RAM handoff requests
# receive an exception; flash commands retain every upstream version check.
edit('src/device/DeviceBootloader.cpp', '#include <fstream>', '#include <fstream>\n#include <type_traits>')
edit('src/device/DeviceBootloader.cpp',
     '    if(getVersion().getSemver() < Version(T::VERSION)) {',
     '    // C1_BACKEND_RAM_HANDOFF: limited to version read and USB ROM boot.\n'
     '    constexpr bool ramOnlyCommand = std::is_same<T, Request::GetBootloaderVersion>::value || std::is_same<T, Request::UsbRomBoot>::value;\n'
     '    const bool legacyZeroVersion = getVersion().getSemver() == Version(0, 0, 0);\n'
     '    if(!(ramOnlyCommand && legacyZeroVersion) && getVersion().getSemver() < Version(T::VERSION)) {', expected=2)

# Hunter's old zlib selects a classic-Mac branch with modern SDK macros. Pin a
# known source archive and prevent that branch from redefining fdopen to NULL.
cfg = root / 'cmake/Hunter/config.cmake'
text = cfg.read_text()
if '# C1_BACKEND_ZLIB' not in text:
    cfg.write_text(text + '''\n# C1_BACKEND_ZLIB
hunter_config(ZLIB VERSION "1.2.13-p0-c1"
  URL "https://github.com/cpp-pm/zlib/archive/v1.2.13-p0.tar.gz"
  SHA1 "219ae8c9e5040fb695f84e2cc364fe055d5a7408"
  CMAKE_ARGS CMAKE_C_FLAGS=-Dfdopen=fdopen)
''')
