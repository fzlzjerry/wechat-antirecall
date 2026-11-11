#pragma once
#include <string>

namespace key_export {

// Scans this process's own heap for WeChat 4.x SQLCipher raw keys (the ASCII
// `x'<64hex key><32hex salt>'` blobs WCDB keeps in memory) and writes them to
// keys.json in the app container, so the CLI can hand them to database readers
// without task_for_pid or re-signing. Scheduled by the component's constructor;
// see KeyExport.mm for the throttle that keeps a warm dump from rescanning.

}  // namespace key_export
